import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { requireManagementCommittee, requireSystemAdmin, requireTreasurer} from '../middleware/rbac.js';

const router = express.Router();

/**
 * GET /api/admin/members/pending
 * Get pending member applications (Management Committee)
 */
router.get('/members/pending', requireManagementCommittee, asyncHandler(async (req, res) => {
  const { data: applicants, error } = await supabaseAdmin
    .from('members')
    .select('*')
    .eq('status', 'Applicant')
    .is('admission_decision_at', null)   // ⬅️ FIXED: use .is() for null
    .order('created_at', { ascending: true });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, applicants: applicants || [] });
}));
/**
 * POST /api/admin/members/decide
 * Decide on member application (Management Committee)
 */
router.post('/members/decide', requireManagementCommittee, asyncHandler(async (req, res) => {
  const { member_id, approve, rejection_reason } = req.body;

  if (!member_id) {
    return res.status(400).json({ error: 'member_id is required' });
  }

  if (approve === undefined) {
    return res.status(400).json({ error: 'approve is required' });
  }

  if (!approve && (!rejection_reason || rejection_reason.trim().length === 0)) {
    return res.status(400).json({ error: 'rejection_reason is required for rejections' });
  }

  const result = await supabaseAdmin
    .rpc('decide_member_application', {
      p_member_id: member_id,
      p_approve: approve,
      p_rejection_reason: approve ? null : rejection_reason
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to process application' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Decision failed' });
  }

  res.json({ 
    success: true, 
    approved: approve,
    message: approve ? 'Membership approved' : 'Membership rejected'
  });
}));

/**
 * POST /api/admin/members/update-status
 * Update member status (Treasurer/Secretary)
 */
router.post('/members/update-status', requireManagementCommittee, asyncHandler(async (req, res) => {
  const { member_id, status, reason } = req.body;

  if (!member_id || !status) {
    return res.status(400).json({ error: 'member_id and status are required' });
  }

  if (!['Active', 'Suspended', 'Terminated', 'Exited'].includes(status)) {
    return res.status(400).json({ error: 'Invalid status' });
  }

  const updates = {
    status,
    updated_at: new Date().toISOString()
  };

  if (status === 'Terminated' || status === 'Exited') {
    updates.termination_date = new Date().toISOString().split('T')[0];
    updates.termination_reason = reason || null;
  }

  const { data, error } = await supabaseAdmin
    .from('members')
    .update(updates)
    .eq('id', member_id)
    .select()
    .single();

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  // Log audit
  await supabaseAdmin
    .rpc('write_audit', {
      p_action: 'UPDATE_MEMBER_STATUS',
      p_resource_type: 'member',
      p_resource_id: member_id,
      p_details: { status, reason }
    });

  res.json({ success: true, member: data });
}));

/**
 * GET /api/admin/audit-log
 * Get audit log (Chairman/Treasurer)
 */
router.get('/audit-log', requireSystemAdmin, asyncHandler(async (req, res) => {
  const { limit = 100, offset = 0, action, from, to } = req.query;

  let query = supabaseAdmin
    .from('audit_log')
    .select('*', { count: 'exact' });

  if (action) {
    query = query.eq('action', action);
  }

  if (from) {
    query = query.gte('created_at', from);
  }

  if (to) {
    query = query.lte('created_at', to);
  }

  const { data: logs, error, count } = await query
    .order('created_at', { ascending: false })
    .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({
    success: true,
    logs,
    pagination: {
      total: count,
      limit: parseInt(limit),
      offset: parseInt(offset)
    }
  });
}));

/**
 * POST /api/admin/fees
 * Post non-loan fees (entrance fee, loan form fee)
 */
router.post('/fees', requireTreasurer, asyncHandler(async (req, res) => {
  const { member_id, transaction_type, amount, reference, notes } = req.body;

  if (!member_id || !transaction_type || !amount) {
    return res.status(400).json({ error: 'member_id, transaction_type, amount are required' });
  }

  if (!['ENTRANCE_FEE', 'LOAN_FORM_SALE'].includes(transaction_type)) {
    return res.status(400).json({ error: 'Invalid transaction_type' });
  }

  if (amount <= 0) {
    return res.status(400).json({ error: 'amount must be greater than zero' });
  }

  const result = await supabaseAdmin
    .rpc('post_non_loan_fee', {
      p_member_id: member_id,
      p_transaction_type: transaction_type,
      p_amount: amount,
      p_reference: reference || null,
      p_notes: notes || null
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to post fee' });
  }

  res.json({
    success: true,
    ledger_entry_id: result.data,
    message: 'Fee posted successfully'
  });
}));

export default router;