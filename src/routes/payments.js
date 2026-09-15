import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireTreasurer } from '../middleware/rbac.js';

const router = express.Router();

/**
 * POST /api/payments/submit
 * Submit a payment notification (member)
 */
router.post('/submit', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { amount, payment_reference, evidence_url, proposed_savings, proposed_loans } = req.body;

  // 🔍 Debug: Log what we're receiving
  console.log('📝 Payment submission request:');
  console.log('   member_id:', memberId);
  console.log('   amount:', amount, '(type:', typeof amount, ')');
  console.log('   payment_reference:', payment_reference);
  console.log('   evidence_url:', evidence_url);
  console.log('   proposed_savings:', proposed_savings, '(type:', typeof proposed_savings, ')');
  console.log('   proposed_loans:', JSON.stringify(proposed_loans), '(type:', typeof proposed_loans, ')');

  if (!amount || amount <= 0) {
    return res.status(400).json({ error: 'Valid amount is required' });
  }

  // 🔍 Debug: Log RPC call
  const rpcArgs = {
    p_member_id: memberId,
    p_amount: amount,
    p_payment_reference: payment_reference || null,
    p_evidence_url: evidence_url || null,
    p_proposed_savings: proposed_savings || 0,
    p_proposed_loans: proposed_loans || '[]'
  };
  console.log('🚀 Calling RPC with args:', JSON.stringify(rpcArgs));

  const result = await supabaseAdmin
    .rpc('submit_payment_notification', rpcArgs);

  // 🔍 Debug: Log full result
  console.log('📥 RPC result:', JSON.stringify(result, null, 2));

  if (result.error) {
    console.error('❌ RPC error:', result.error);
    return res.status(400).json({ 
      error: result.error.message || 'Failed to submit payment',
      detail: result.error
    });
  }

  if (!result.data) {
    console.error('❌ RPC returned null data');
    return res.status(400).json({ 
      error: 'Failed to submit payment — no data returned from database',
      hint: 'Check API terminal logs for the actual database error'
    });
  }

  res.json({
    success: true,
    payment_notification_id: result.data,
    message: 'Payment submitted, awaiting Treasurer approval'
  });
}));

/**
 * GET /api/payments/pending
 * Get pending payments (Unified Pending Queue) - Treasurer only
 */
router.get('/pending', requireTreasurer, asyncHandler(async (req, res) => {
  const { data: pending, error } = await supabaseAdmin
    .from('pending_transactions')
    .select('*')
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, pending });
}));

/**
 * POST /api/payments/approve
 * Approve a payment with split allocation - Treasurer only
 */
router.post('/approve', requireTreasurer, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { 
    payment_notification_id, 
    savings_allocation, 
    loan_allocations, 
    match_override_member_id 
  } = req.body;

  if (!payment_notification_id) {
    return res.status(400).json({ error: 'payment_notification_id is required' });
  }

  if (savings_allocation === undefined || savings_allocation < 0) {
    return res.status(400).json({ error: 'Valid savings_allocation is required' });
  }

  const result = await supabaseAdmin
    .rpc('approve_payment_with_split', {
      p_payment_notification_id: payment_notification_id,
      p_savings_allocation: savings_allocation,
      p_loan_allocations: loan_allocations || '[]',
      p_match_override_member_id: match_override_member_id || null
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to approve payment' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Payment approval failed' });
  }

  res.json({ success: true, result: result.data });
}));

/**
 * POST /api/payments/decline
 * Decline a payment - Treasurer only
 */
router.post('/decline', requireTreasurer, asyncHandler(async (req, res) => {
  const { payment_notification_id, reason } = req.body;

  if (!payment_notification_id) {
    return res.status(400).json({ error: 'payment_notification_id is required' });
  }

  if (!reason || reason.trim().length === 0) {
    return res.status(400).json({ error: 'Decline reason is required' });
  }

  const result = await supabaseAdmin
    .rpc('decline_payment', {
      p_payment_notification_id: payment_notification_id,
      p_reason: reason.trim()
    });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }

  res.json({ success: true, message: 'Payment declined' });
}));

/**
 * GET /api/payments/history
 * Get payment history for the member
 */
router.get('/history', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { limit = 50, offset = 0 } = req.query;

  const { data: history, error, count } = await supabaseAdmin
    .from('payment_notifications')
    .select('*', { count: 'exact' })
    .eq('member_id', memberId)
    .order('created_at', { ascending: false })
    .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({
    success: true,
    history,
    pagination: {
      total: count,
      limit: parseInt(limit),
      offset: parseInt(offset)
    }
  });
}));

export default router;