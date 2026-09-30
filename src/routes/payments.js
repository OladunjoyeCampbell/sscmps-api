// src/routes/payments.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId } from '../middleware/auth.js';
import { requireTreasurer } from '../middleware/rbac.js';

const router = express.Router();

/**
 * POST /api/payments/submit
 * Submit a payment notification (member).
 * The payment_reference is generated server-side; callers may
 * pass a value but normally leave it null.
 */
router.post(
  '/submit',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const {
      amount,
      payment_reference,
      evidence_url,
      proposed_savings,
      proposed_loans,
    } = req.body;

    if (!amount || amount <= 0) {
      return res.status(400).json({ error: 'Valid amount is required' });
    }

    const result = await supabaseAdmin.rpc('submit_payment_notification', {
      p_member_id: memberId,
      p_amount: amount,
      p_payment_reference: payment_reference || null,
      p_evidence_url: evidence_url || null,
      p_proposed_savings: proposed_savings || 0,
      p_proposed_loans: proposed_loans || '[]',
    });

    if (result.error) {
      console.error('[payments.submit] RPC error:', result.error);
      return res.status(400).json({
        error: result.error.message || 'Failed to submit payment',
        details: result.error.details || null,
        hint: result.error.hint || null,
        code: result.error.code || null,
      });
    }
    if (!result.data) {
      return res.status(400).json({ error: 'Failed to submit payment' });
    }

    const { data: notification } = await supabaseAdmin
      .from('payment_notifications')
      .select('payment_reference')
      .eq('id', result.data)
      .single();

    res.json({
      success: true,
      payment_notification_id: result.data,
      payment_reference: notification?.payment_reference || null,
      message: 'Payment submitted, awaiting Treasurer approval',
    });
  })
);

/**
 * GET /api/payments/pending
 * Unified pending queue — Treasurer only.
 */
router.get(
  '/pending',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { data: pending, error } = await supabaseAdmin
      .from('pending_transactions')
      .select('*')
      .order('priority', { ascending: true })
      .order('created_at', { ascending: true });

    if (error) return res.status(400).json({ error: error.message });
    res.json({ success: true, pending });
  })
);

/**
 * POST /api/payments/approve
 * Approve a payment with split allocation — Treasurer only.
 *
 * Two layers of validation:
 *   1. Pre-flight check: all referenced loans must exist and be
 *      Active/Disbursed, and belong to the matched member. Rejects
 *      with a clear error before the RPC runs.
 *   2. The RPC itself re-validates. If it fails, the actual error
 *      is surfaced (not the previous generic message).
 */
router.post(
  '/approve',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const {
      payment_notification_id,
      savings_allocation,
      loan_allocations,
      match_override_member_id,
    } = req.body;

    if (!payment_notification_id) {
      return res
        .status(400)
        .json({ error: 'payment_notification_id is required' });
    }
    if (savings_allocation === undefined || savings_allocation < 0) {
      return res
        .status(400)
        .json({ error: 'Valid savings_allocation is required' });
    }

    // ---------------------------------------------------------------
    // Pre-flight: fetch the payment to know which member it belongs to
    // ---------------------------------------------------------------
    const { data: payment, error: paymentError } = await supabaseAdmin
      .from('payment_notifications')
      .select('id, member_id, amount, status')
      .eq('id', payment_notification_id)
      .maybeSingle();

    if (paymentError || !payment) {
      return res.status(404).json({ error: 'Payment notification not found' });
    }

    if (payment.status !== 'Pending') {
      return res.status(400).json({
        error: `Payment is ${payment.status}; only Pending payments can be approved`,
        code: 'PAYMENT_NOT_PENDING',
      });
    }

    // Determine the effective member (respecting treasurer override)
    const effectiveMemberId = match_override_member_id || payment.member_id;

    // ---------------------------------------------------------------
    // Pre-flight: validate every loan allocation
    // ---------------------------------------------------------------
    const loanAllocs = Array.isArray(loan_allocations) ? loan_allocations : [];

    if (loanAllocs.length > 0) {
      const loanIds = loanAllocs.map((a) => a.loan_id).filter(Boolean);

      if (loanIds.length !== loanAllocs.length) {
        return res.status(400).json({
          error: 'Every loan allocation must include a loan_id',
          code: 'MISSING_LOAN_ID',
        });
      }

      const { data: existingLoans, error: loansError } = await supabaseAdmin
        .from('loans')
        .select('id, loan_reference, status, member_id')
        .in('id', loanIds);

      if (loansError) {
        return res.status(400).json({ error: loansError.message });
      }

      const foundById = Object.fromEntries(
        (existingLoans || []).map((l) => [l.id, l])
      );

      for (const alloc of loanAllocs) {
        const loan = foundById[alloc.loan_id];

        // Missing loan — this is the case that produced the earlier
        // cryptic "Loan X is not an active loan of the matched member"
        if (!loan) {
          return res.status(400).json({
            error:
              'One or more loan allocations reference a loan that no longer exists. ' +
              'Reallocate the affected amount to savings, or decline the payment and ask the member to resubmit.',
            code: 'STALE_LOAN_ALLOCATION',
            offending_loan_id: alloc.loan_id,
          });
        }

        // Inactive loan
        if (loan.status !== 'Active' && loan.status !== 'Disbursed') {
          return res.status(400).json({
            error: `Loan ${loan.loan_reference || alloc.loan_id} is ${loan.status} and cannot receive repayment. Reallocate to savings or decline.`,
            code: 'INACTIVE_LOAN_ALLOCATION',
            offending_loan_id: loan.id,
            loan_status: loan.status,
          });
        }

        // Loan belongs to a different member
        if (effectiveMemberId && loan.member_id !== effectiveMemberId) {
          return res.status(400).json({
            error: `Loan ${loan.loan_reference || alloc.loan_id} does not belong to the matched member. Reallocate to savings or verify the member match.`,
            code: 'LOAN_OWNER_MISMATCH',
            offending_loan_id: loan.id,
          });
        }
      }
    }

    // ---------------------------------------------------------------
    // Pre-flight checks passed — call the RPC
    // ---------------------------------------------------------------
    const result = await supabaseAdmin.rpc('approve_payment_with_split', {
      p_payment_notification_id: payment_notification_id,
      p_savings_allocation: savings_allocation,
      p_loan_allocations: loan_allocations || '[]',
      p_match_override_member_id: match_override_member_id || null,
    });

    if (result.error) {
      console.error('[payments.approve] RPC error:', result.error);
      return res.status(400).json({
        error: result.error.message || 'Payment approval failed',
        details: result.error.details || null,
        hint: result.error.hint || null,
        code: result.error.code || null,
      });
    }

    if (!result.data) {
      return res.status(400).json({
        error: 'RPC returned no data',
      });
    }

    if (!result.data.success) {
      return res.status(400).json({
        error: result.data.error || 'Payment approval failed',
        result: result.data,
      });
    }

    res.json({ success: true, result: result.data });
  })
);

/**
 * POST /api/payments/decline
 * Decline a payment — Treasurer only.
 */
router.post(
  '/decline',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { payment_notification_id, reason } = req.body;

    if (!payment_notification_id) {
      return res
        .status(400)
        .json({ error: 'payment_notification_id is required' });
    }
    if (!reason || reason.trim().length === 0) {
      return res.status(400).json({ error: 'Decline reason is required' });
    }

    const result = await supabaseAdmin.rpc('decline_payment', {
      p_payment_notification_id: payment_notification_id,
      p_reason: reason.trim(),
    });

    if (result.error) {
      console.error('[payments.decline] RPC error:', result.error);
      return res.status(400).json({
        error: result.error.message || 'Payment decline failed',
        details: result.error.details || null,
        hint: result.error.hint || null,
        code: result.error.code || null,
      });
    }

    res.json({ success: true, message: 'Payment declined' });
  })
);

/**
 * GET /api/payments/history
 * Payment history for the current member.
 */
router.get(
  '/history',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { limit = 50, offset = 0 } = req.query;

    const { data: history, error, count } = await supabaseAdmin
      .from('payment_notifications')
      .select('*', { count: 'exact' })
      .eq('member_id', memberId)
      .order('created_at', { ascending: false })
      .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);

    if (error) return res.status(400).json({ error: error.message });

    res.json({
      success: true,
      history,
      pagination: {
        total: count,
        limit: parseInt(limit),
        offset: parseInt(offset),
      },
    });
  })
);

export default router;