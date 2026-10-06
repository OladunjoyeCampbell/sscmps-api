import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireTreasurer, requireTrustee } from '../middleware/rbac.js';

const router = express.Router();

router.post(
  '/request',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { withdrawal_type, requested_amount, reason } = req.body;

    // ── Validation ─────────────────────────────────────────────
    if (!withdrawal_type || !requested_amount) {
      return res.status(400).json({
        error: 'withdrawal_type and requested_amount are required',
      });
    }
    if (!['RETIREMENT', 'TERMINATION', 'FINAL_EXIT'].includes(withdrawal_type)) {
      return res.status(400).json({ error: 'Invalid withdrawal_type' });
    }
    if (requested_amount <= 0) {
      return res.status(400).json({
        error: 'requested_amount must be greater than zero',
      });
    }

    // ── Member lookup ─────────────────────────────────────────
    const { data: member, error: memberErr } = await supabaseAdmin
      .from('members')
      .select('id, status, first_name, last_name')
      .eq('id', memberId)
      .maybeSingle();

    if (memberErr || !member) {
      return res.status(404).json({ error: 'Member not found' });
    }
    if (member.status === 'Applicant') {
      return res.status(400).json({
        error: 'Only active members can request withdrawals',
      });
    }
    if (member.status === 'Suspended') {
      return res.status(400).json({
        error: 'Suspended members cannot request withdrawals',
      });
    }

    // ── Balance check ─────────────────────────────────────────
    const { data: balanceData } = await supabaseAdmin.rpc(
      'get_member_savings_balance',
      { p_member_id: memberId }
    );
    const available = Number(balanceData || 0);

    if (requested_amount > available) {
      return res.status(400).json({
        error: `Withdrawal exceeds your available balance of ₦${available.toLocaleString()}`,
      });
    }

    if (withdrawal_type === 'RETIREMENT' && requested_amount > available * 0.5) {
      return res.status(400).json({
        error: 'Retirement withdrawal may not exceed 50% of your savings',
      });
    }

    // ── Duplicate check ───────────────────────────────────────
    const { data: existing } = await supabaseAdmin
      .from('withdrawal_requests')
      .select('id, status')
      .eq('member_id', memberId)
      .eq('status', 'Pending')
      .maybeSingle();

    if (existing) {
      return res.status(409).json({
        error: 'You already have a pending withdrawal request',
        existing_id: existing.id,
      });
    }

    // ── Insert ────────────────────────────────────────────────
    // Charge and net_amount are provisional at submission. The approval
    // step (approve_withdrawal) recalculates them — the 2% charge applies
    // to RETIREMENT only.
    const { data: inserted, error: insertErr } = await supabaseAdmin
      .from('withdrawal_requests')
      .insert({
        member_id: memberId,
        withdrawal_type,
        requested_amount: Number(requested_amount),
        charge_amount: 0,
        net_amount: Number(requested_amount),
        reason: reason || null,
        status: 'Pending',
        created_by: memberId,
      })
      .select('id')
      .single();

    if (insertErr) {
      console.error('[withdrawals.request]', insertErr);
      return res.status(400).json({ error: insertErr.message });
    }

    // ── Audit ─────────────────────────────────────────────────
    try {
      await supabaseAdmin.rpc('write_audit', {
        p_action: 'SUBMIT_WITHDRAWAL_REQUEST',
        p_resource_type: 'withdrawal_request',
        p_resource_id: inserted.id,
        p_details: {
          amount: Number(requested_amount),
          type: withdrawal_type,
          reason: reason || null,
        },
      });
    } catch (err) {
      console.warn('[withdrawals.request] audit failed:', err.message);
    }

    // ── Notify Treasurer ──────────────────────────────────────
    try {
      const { data: treasurers } = await supabaseAdmin
        .from('members')
        .select('id')
        .eq('role', 'Treasurer')
        .eq('status', 'Active');

      for (const t of treasurers || []) {
        await supabaseAdmin.rpc('queue_notification', {
          p_member_id: t.id,
          p_category: 'PENDING_QUEUE',
          p_subject: 'New withdrawal request',
          p_body: `${member.first_name} ${member.last_name} has submitted a ${withdrawal_type.toLowerCase()} withdrawal request for ₦${Number(requested_amount).toLocaleString()}.`,
          p_payload: { withdrawal_id: inserted.id },
        });
      }
    } catch (err) {
      console.warn('[withdrawals.request] notify failed:', err.message);
    }

    res.json({
      success: true,
      withdrawal_id: inserted.id,
      message: 'Withdrawal request submitted for approval',
    });
  })
);
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
router.get('/pending', asyncHandler(async (req, res) => {
  const role = getMemberRole(req);
  if (!['Treasurer', 'Chairman', 'Secretary', 'SystemAdmin'].includes(role)) {
    return res.status(403).json({ error: 'Access denied' });
  }
  const { data: withdrawals, error } = await supabaseAdmin
    .from('withdrawal_requests')
    .select(`
      *,
      members!member_id(first_name, last_name, staff_id, email)
    `),
      withdrawal_signoffs(trustee_id, signed_at, trustee:members!trustee_id(first_name, last_name, role))	
    .in('status', 'Pending')
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

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data) {
      return res.status(400).json({ error: 'RPC returned no data' });
    }
    if (!result.data.success) {
      return res.status(400).json({ error: result.data.error || 'Approval failed' });
    }

  res.json({ success: true, result: result.data });
}));

/**
 * POST /api/withdrawals/signoff
 * Records one trustee's signature on a pending withdrawal.
 * Two distinct signatures auto-approve the request.
 */
router.post(
  '/signoff',
  requireTrustee,
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { request_id } = req.body;

    if (!request_id) {
      return res.status(400).json({ error: 'request_id is required' });
    }

    const result = await supabaseAdmin.rpc('record_withdrawal_signoff', {
      p_request_id: request_id,
      p_trustee_id: memberId,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data?.success) {
      return res.status(400).json({ error: result.data?.error || 'Sign-off failed' });
    }

    res.json({ success: true, result: result.data });
  })
);


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