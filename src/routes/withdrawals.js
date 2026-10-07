// src/routes/withdrawals.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireTreasurer, requireTrustee } from '../middleware/rbac.js';

const router = express.Router();

// Roles allowed to view the pending withdrawal queue.
const QUEUE_VIEWER_ROLES = ['Chairman', 'Secretary', 'Treasurer', 'SystemAdmin'];

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/**
 * Returns the member's current savings balance and outstanding loan total.
 */
async function getMemberFinancials(memberId) {
  const [{ data: balance }, { data: loans }] = await Promise.all([
    supabaseAdmin.rpc('get_member_savings_balance', { p_member_id: memberId }),
    supabaseAdmin.rpc('get_member_total_outstanding_loans', { p_member_id: memberId }),
  ]);
  return {
    savings: Number(balance || 0),
    outstandingLoans: Number(loans || 0),
  };
}

/**
 * Maximum gross amount a member may request, given their type and position.
 * Loans are cleared first at process time; the type-specific cap then
 * applies to whatever remains.
 */
function maxWithdrawable(savings, outstandingLoans, withdrawalType) {
  const afterLiquidation = Math.max(0, savings - outstandingLoans);
  return withdrawalType === 'RETIREMENT'
    ? afterLiquidation * 0.5
    : afterLiquidation;
}

const fmtNaira = (v) =>
  `₦${Number(v || 0).toLocaleString('en-NG', { minimumFractionDigits: 0 })}`;

// ---------------------------------------------------------------------
// POST /api/withdrawals/request
// Member submits a withdrawal request.
// ---------------------------------------------------------------------
router.post(
  '/request',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { withdrawal_type, requested_amount, reason } = req.body;

    // ── Validation ──────────────────────────────────────────
    if (!withdrawal_type || !requested_amount) {
      return res.status(400).json({
        error: 'withdrawal_type and requested_amount are required',
      });
    }
    if (!['RETIREMENT', 'TERMINATION', 'FINAL_EXIT'].includes(withdrawal_type)) {
      return res.status(400).json({ error: 'Invalid withdrawal_type' });
    }
    const amount = Number(requested_amount);
    if (!Number.isFinite(amount) || amount <= 0) {
      return res.status(400).json({
        error: 'requested_amount must be greater than zero',
      });
    }

    // ── Member lookup ───────────────────────────────────────
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
    // Once-ever retirement
    if (withdrawal_type === 'RETIREMENT') {
      const { data: prior } = await supabaseAdmin
        .from('withdrawal_requests')
        .select('id, status')
        .eq('member_id', memberId)
        .eq('withdrawal_type', 'RETIREMENT')
        .in('status', ['Pending', 'Approved', 'Processed'])
        .maybeSingle();

      if (prior) {
        return res.status(400).json({
          error:
            'You have already taken a retirement withdrawal. A member may only ' +
            'take the 50% retirement withdrawal once. If you wish to leave the ' +
            'cooperative entirely, submit a Final Exit request.',
        });
      }
    }

    // Termination is management-initiated
    if (withdrawal_type === 'TERMINATION') {
      return res.status(400).json({
        error:
          'Termination is initiated by the management, not by the member. ' +
          'Contact the Secretary if you have questions about your membership.',
      });
    }
	
    // ── Financial position ──────────────────────────────────
    const { savings, outstandingLoans } = await getMemberFinancials(memberId);

    if (amount > savings) {
      return res.status(400).json({
        error: `Withdrawal exceeds your available balance of ${fmtNaira(savings)}`,
      });
    }

    // ── Estimated type-specific cap (loans cleared first) ───
    const cap = maxWithdrawable(savings, outstandingLoans, withdrawal_type);
    if (amount > cap) {
      const afterLiquidation = Math.max(0, savings - outstandingLoans);
      const estimatedNet = cap * 0.98;
      return res.status(400).json({
        error:
          `Your outstanding loans (${fmtNaira(outstandingLoans)}) will be cleared ` +
          `from your savings first, leaving ${fmtNaira(afterLiquidation)}. ` +
          (withdrawal_type === 'RETIREMENT'
            ? `For a retirement withdrawal, the maximum is 50% of that remainder — `
            : `The maximum is `) +
          `${fmtNaira(cap)} (net ≈ ${fmtNaira(estimatedNet)} after the 2% charge). ` +
          `Please reduce your request and resubmit.`,
        max_allowed: cap,
        outstanding_loans: outstandingLoans,
        savings_after_liquidation: afterLiquidation,
      });
    }

    // ── Duplicate check ─────────────────────────────────────
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

    // ── Insert ──────────────────────────────────────────────
    // charge_amount and net_amount are provisional at submission.
    // The process step recalculates both after liquidation.
    const { data: inserted, error: insertErr } = await supabaseAdmin
      .from('withdrawal_requests')
      .insert({
        member_id: memberId,
        withdrawal_type,
        requested_amount: amount,
        charge_amount: 0,
        net_amount: amount,
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

    // ── Audit ───────────────────────────────────────────────
    try {
      await supabaseAdmin.rpc('write_audit', {
        p_action: 'SUBMIT_WITHDRAWAL_REQUEST',
        p_resource_type: 'withdrawal_request',
        p_resource_id: inserted.id,
        p_details: {
          amount,
          type: withdrawal_type,
          reason: reason || null,
        },
      });
    } catch (err) {
      console.warn('[withdrawals.request] audit failed:', err.message);
    }

    // ── Notify Treasurer ────────────────────────────────────
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
          p_body:
            `${member.first_name} ${member.last_name} has submitted a ` +
            `${withdrawal_type.toLowerCase()} withdrawal request for ${fmtNaira(amount)}.`,
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

// ---------------------------------------------------------------------
// GET /api/withdrawals/my
// A member's own withdrawal history.
// ---------------------------------------------------------------------
router.get(
  '/my',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    const { data: withdrawals, error } = await supabaseAdmin
      .from('withdrawal_requests')
      .select('*')
      .eq('member_id', memberId)
      .order('created_at', { ascending: false });

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, withdrawals: withdrawals || [] });
  })
);

// ---------------------------------------------------------------------
// GET /api/withdrawals/pending
// Treasurer / Trustee queue. Shows Pending and Approved requests.
// Includes signature progress so trustees can see who has signed.
// ---------------------------------------------------------------------
router.get(
  '/pending',
  asyncHandler(async (req, res) => {
    const role = getMemberRole(req);
    if (!QUEUE_VIEWER_ROLES.includes(role)) {
      return res.status(403).json({ error: 'Access denied' });
    }

    const { data: withdrawals, error } = await supabaseAdmin
      .from('withdrawal_requests')
      .select(
        '*, members!member_id(first_name, last_name, staff_id, email), withdrawal_signoffs(trustee_id, signed_at, trustee:members!trustee_id(first_name, last_name, role))'
      )
      .in('status', ['Pending', 'Approved', 'Processed'])
      .order('created_at', { ascending: true });

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, withdrawals: withdrawals || [] });
  })
);

// ---------------------------------------------------------------------
// POST /api/withdrawals/signoff
// A trustee signs a pending request. Two distinct signatures auto-approve.
// ---------------------------------------------------------------------
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

// ---------------------------------------------------------------------
// POST /api/withdrawals/process
// Treasurer processes an approved withdrawal.
// Order of operations (atomic via RPC):
//   1. Liquidate all outstanding loans from savings
//   2. Apply the type-specific cap to the remaining balance
//   3. Gross payout = min(requested, cap)
//   4. Charge = 2% of gross
//   5. Net to member = gross - charge
// ---------------------------------------------------------------------
router.post(
  '/process',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { request_id } = req.body;

    if (!request_id) {
      return res.status(400).json({ error: 'request_id is required' });
    }

    const result = await supabaseAdmin.rpc(
      'process_withdrawal_with_liquidation',
      { p_request_id: request_id, p_processed_by: memberId }
    );

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data?.success) {
      return res.status(400).json({
        error: result.data?.error || 'Processing failed',
      });
    }

    // ── Notify the member ───────────────────────────────────
    try {
      const { data: w } = await supabaseAdmin
        .from('withdrawal_requests')
        .select('member_id')
        .eq('id', request_id)
        .single();

      if (w?.member_id) {
        await supabaseAdmin.rpc('queue_notification', {
          p_member_id: w.member_id,
          p_category: 'SYSTEM',
          p_subject: 'Withdrawal processed',
          p_body:
            `Your withdrawal has been processed. ` +
            (Number(result.data.loan_repaid_total) > 0
              ? `Loans cleared: ${fmtNaira(result.data.loan_repaid_total)}. `
              : '') +
            `Gross payout: ${fmtNaira(result.data.gross_payout)}. ` +
            `Less 2% charge: ${fmtNaira(result.data.charge)}. ` +
            `Net paid to you: ${fmtNaira(result.data.net_to_member)}. ` +
            `Contact the Treasurer to arrange the bank transfer.`,
          p_payload: { withdrawal_id: request_id },
        });
      }
    } catch (err) {
      console.warn('[withdrawals.process] notify failed:', err.message);
    }

    res.json({ success: true, result: result.data });
  })
);

export default router;