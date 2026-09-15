import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireTreasurer, requireTrustee } from '../middleware/rbac.js';

const router = express.Router();

/**
 * POST /api/withdrawals/request
 * Request a withdrawal (member)
 */
router.post('/request', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { withdrawal_type, requested_amount, reason } = req.body;

  if (!withdrawal_type || !requested_amount) {
    return res.status(400).json({ error: 'withdrawal_type and requested_amount are required' });
  }

  if (!['RETIREMENT', 'TERMINATION', 'FINAL_EXIT'].includes(withdrawal_type)) {
    return res.status(400).json({ error: 'Invalid withdrawal_type' });
  }

  if (requested_amount <= 0) {
    return res.status(400).json({ error: 'requested_amount must be greater than zero' });
  }

  const result = await supabaseAdmin
    .rpc('submit_withdrawal_request', {
      p_withdrawal_type: withdrawal_type,
      p_requested_amount: requested_amount,
      p_reason: reason || null
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to submit withdrawal request' });
  }

  res.json({
    success: true,
    withdrawal_id: result.data,
    message: 'Withdrawal request submitted for approval'
  });
}));

/**
 * GET /api/withdrawals/my
 * Get withdrawal requests for the current member
 */
router.get('/my', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);

  const { data: withdrawals, error } = await supabaseAdmin
    .from('withdrawal_requests')
    .select('*')
    .eq('member_id', memberId)
    .order('created_at', { ascending: false });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, withdrawals });
}));

/**
 * GET /api/withdrawals/pending
 * Get pending withdrawals (Treasurer/Management)
 */
router.get('/pending', requireTreasurer, asyncHandler(async (req, res) => {
  const { data: withdrawals, error } = await supabaseAdmin
    .from('withdrawal_requests')
    .select(`
      *,
      members(first_name, last_name, staff_id, email)
    `)
    .eq('status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, withdrawals });
}));

/**
 * POST /api/withdrawals/approve
 * Approve a withdrawal (Trustee)
 */
router.post('/approve', requireTrustee, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { request_id, trustee_1, trustee_2, recorder_id } = req.body;

  if (!request_id || !trustee_1 || !trustee_2 || !recorder_id) {
    return res.status(400).json({ 
      error: 'request_id, trustee_1, trustee_2, and recorder_id are required' 
    });
  }

  const result = await supabaseAdmin
    .rpc('approve_withdrawal', {
      p_request_id: request_id,
      p_trustee_1: trustee_1,
      p_trustee_2: trustee_2,
      p_recorder_id: recorder_id
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to approve withdrawal' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Approval failed' });
  }

  res.json({ success: true, result: result.data });
}));

/**
 * POST /api/withdrawals/process
 * Process an approved withdrawal (Treasurer)
 */
router.post('/process', requireTreasurer, asyncHandler(async (req, res) => {
  const { request_id } = req.body;

  if (!request_id) {
    return res.status(400).json({ error: 'request_id is required' });
  }

  const result = await supabaseAdmin
    .rpc('process_withdrawal', {
      p_request_id: request_id
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to process withdrawal' });
  }

  res.json({
    success: true,
    ledger_entry_id: result.data,
    message: 'Withdrawal processed successfully'
  });
}));

export default router;