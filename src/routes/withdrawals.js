// src/routes/withdrawals.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireTreasurer, requireTrustee } from '../middleware/rbac.js';

const router = express.Router();

// Roles allowed to view the pending withdrawal queue.
const QUEUE_VIEWER_ROLES = ['Chairman', 'Secretary', 'Treasurer', 'SystemAdmin'];

// Human-readable labels for notification / error messages.
const TYPE_LABELS = {
  RETIREMENT: 'retirement',
  TERMINATION: 'termination',
  FINAL_EXIT: 'final exit',
  ANNUAL_10_PERCENT: 'annual 10%',
};

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

/**
 * Returns the member's current savings balance and outstanding loan total.
 * FIX: `req` must be passed in; previously `req` was referenced inside
 * the helper but only `memberId` was declared, causing ReferenceError
 * on every /request call.
 */
async function getMemberFinancials(req, memberId) {
  const [{ data: balance }, { data: loans }] = await Promise.all([
    req.supabase.rpc('get_member_savings_balance', { p_member_id: memberId }),
    req.supabase.rpc('get_member_total_outstanding_loans', { p_member_id: memberId }),
  ]);
  return {
    savings: Number(balance || 0),
    outstandingLoans: Number(loans || 0),
  };
}

/**
 * Maximum gross amount for the legacy (non-annual) types.
 * Loans are cleared first at process time; the type-specific cap then
 * applies to whatever remains.
 * Not used for ANNUAL_10_PERCENT — that type has its own rules
 * (exactly 10% of savings, cash in full, no liquidation).
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
// GET /api/withdrawals/eligibility
// Returns the caller's annual 10% eligibility snapshot.
// The view itself is scoped: it only returns rows where
// members.id = app_member_id(), so no cross-member leakage.
// ---------------------------------------------------------------------
router.get(
  '/eligibility',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    const { data, error } = await req.supabase
      .from('v_annual_withdrawal_eligibility')
      .select('*')
      .eq('member_id', memberId)
      .maybeSingle();

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, eligibility: data || null });
  })
);

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
    if (
      !['RETIREMENT', 'TERMINATION', 'FINAL_EXIT', 'ANNUAL_10_PERCENT'].includes(
        withdrawal_type
      )
    ) {
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

    // ── Once-ever retirement ────────────────────────────────
    if (withdrawal_type === 'RETIREMENT') {
      const { data: priorRows } = await supabaseAdmin
        .from('withdrawal_requests')
        .select('id, status')
        .eq('member_id', memberId)
        .eq('withdrawal_type', 'RETIREMENT')
        .in('status', ['Pending', 'Approved', 'Processed'])
        .limit(1);

      if (priorRows?.[0]) {
        return res.status(400).json({
          error:
            'You have already taken a retirement withdrawal. A member may only ' +
            'take the 50% retirement withdrawal once. If you wish to leave the ' +
            'cooperative entirely, submit a Final Exit request.',
        });
      }
    }

    // ── Termination is management-initiated ─────────────────
    if (withdrawal_type === 'TERMINATION') {
      return res.status(400).json({
        error:
          'Termination is initiated by the management, not by the member. ' +
          'Contact the Secretary if you have questions about your membership.',
      });
    }

    // ── Annual 10% pre-check: window ────────────────────────
    if (withdrawal_type === 'ANNUAL_10_PERCENT') {
      const month = new Date().getUTCMonth() + 1; // 1-12
      if (month < 1 || month > 7) {
        return res.status(400).json({
          error:
            'Annual 10% withdrawal requests are only accepted January through July. ' +
            'The next window opens January 1, ' +
            (new Date().getUTCFullYear() + (month >= 8 ? 1 : 0)) +
            '.',
        });
      }
    }

    // ── Financial position ──────────────────────────────────
    const { savings, outstandingLoans } = await getMemberFinancials(req, memberId);

    if (withdrawal_type === 'ANNUAL_10_PERCENT') {
      // Annual 10%: exactly 10% of current savings, no liquidation cap.
      const tenPct = Math.round(savings * 0.10 * 100) / 100;
      if (tenPct <= 0) {
        return res.status(400).json({
          error:
            'Your savings balance is too low for an annual withdrawal. ' +
            `Current savings: ${fmtNaira(savings)}.`,
        });
      }
      if (Math.abs(amount - tenPct) > 0.01) {
        return res.status(400).json({
          error:
            `Annual withdrawal must be exactly 10% of your savings. ` +
            `Your savings are ${fmtNaira(savings)}, so the annual withdrawal is ` +
            `${fmtNaira(tenPct)}.`,
          expected_amount: tenPct,
        });
      }
    } else {
      // Legacy types: amount ≤ savings, then type-specific cap.
      if (amount > savings) {
        return res.status(400).json({
          error: `Withdrawal exceeds your available balance of ${fmtNaira(savings)}`,
        });
      }

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
    }

    // ── Duplicate check: only one Pending request at a time ─
    const { data: existingRows } = await supabaseAdmin
      .from('withdrawal_requests')
      .select('id, status')
      .eq('member_id', memberId)
      .eq('status', 'Pending')
      .limit(1);

    if (existingRows?.[0]) {
      return res.status(409).json({
        error: 'You already have a pending withdrawal request',
        existing_id: existingRows[0].id,
      });
    }

    // ── Block if an approved loan awaits disbursement ───────
    const { data: approvedLoanRows } = await supabaseAdmin
      .from('loans')
      .select('id, loan_reference')
      .eq('member_id', memberId)
      .eq('status', 'Approved')
      .limit(1);

    if (approvedLoanRows?.[0]) {
      return res.status(400).json({
        error:
          `You have an approved loan (${approvedLoanRows[0].loan_reference}) ` +
          `awaiting disbursement. The loan must be disbursed or cancelled ` +
          `before you can submit a withdrawal.`,
      });
    }

    // ── Delegate to the RPC (source of truth) ───────────────
    // The RPC re-enforces all rules server-side (window, exactly-10%,
    // FY frequency, Active-only for RETIREMENT/ANNUAL) and writes the
    // audit entry with the caller's identity.
    const rpcResult = await req.supabase.rpc('submit_withdrawal_request', {
      p_withdrawal_type: withdrawal_type,
      p_requested_amount: amount,
      p_reason: reason || null,
    });

    if (rpcResult.error) {
      console.error('[withdrawals.request] RPC error:', rpcResult.error);
      return res.status(400).json({ error: rpcResult.error.message });
    }

    const withdrawalId = rpcResult.data;

    // ── Notify Treasurer (RPC already audited) ──────────────
    try {
      const { data: treasurers } = await supabaseAdmin
        .from('members')
        .select('id')
        .eq('role', 'Treasurer')
        .eq('status', 'Active');

      const typeLabel = TYPE_LABELS[withdrawal_type] || withdrawal_type.toLowerCase();

      for (const t of treasurers || []) {
        await supabaseAdmin.rpc('queue_notification', {
          p_member_id: t.id,
          p_category: 'PENDING_QUEUE',
          p_subject: 'New withdrawal request',
          p_body:
            `${member.first_name} ${member.last_name} has submitted a ` +
            `${typeLabel} withdrawal request for ${fmtNaira(amount)}.`,
          p_payload: { withdrawal_id: withdrawalId },
        });
      }
    } catch (err) {
      console.warn('[withdrawals.request] notify failed:', err.message);
    }

    res.json({
      success: true,
      withdrawal_id: withdrawalId,
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
// Treasurer / Trustee queue.
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

    const result = await req.supabase.rpc('record_withdrawal_signoff', {
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
// The RPC handles the differences per type:
//   - RETIREMENT / TERMINATION / FINAL_EXIT: liquidate loans, 50% cap
//     on retirement, 2% charge.
//   - ANNUAL_10_PERCENT: cash in full, no liquidation, no charge.
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

    const result = await req.supabase.rpc(
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
        .select('member_id, withdrawal_type')
        .eq('id', request_id)
        .single();

      if (w?.member_id) {
        const isAnnual = w.withdrawal_type === 'ANNUAL_10_PERCENT';
        const charge = Number(result.data.charge || 0);
        const loansCleared = Number(result.data.loan_repaid_total || 0);

        let body = 'Your withdrawal has been processed. ';
        if (loansCleared > 0) {
          body += `Loans cleared: ${fmtNaira(loansCleared)}. `;
        }
        body += `Gross payout: ${fmtNaira(result.data.gross_payout)}. `;
        if (charge > 0) {
          body += `Less 2% charge: ${fmtNaira(charge)}. `;
        }
        body += `Net paid to you: ${fmtNaira(result.data.net_to_member)}. `;
        body += isAnnual
          ? 'Contact the Treasurer to arrange the bank transfer.'
          : 'Contact the Treasurer to arrange the bank transfer.';

        await supabaseAdmin.rpc('queue_notification', {
          p_member_id: w.member_id,
          p_category: 'SYSTEM',
          p_subject: 'Withdrawal processed',
          p_body: body,
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