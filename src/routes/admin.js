// src/routes/admin.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import {
  requireAdmissionCommittee,
  requireSystemAdmin,
  requireTreasurer,
} from '../middleware/rbac.js';
import { getMemberId } from '../middleware/auth.js';

const router = express.Router();

/**
 * GET /api/admin/members/pending
 * Pending applications plus current vote tallies.
 * Access: Chairman, Secretary, Treasurer, ManagementCommittee, SystemAdmin
 */
router.get(
  '/members/pending',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { data: applicants, error } = await supabaseAdmin
      .from('members')
      .select(`
        id, staff_id, first_name, last_name, middle_name, email, phone,
        department, position, home_address,
        next_of_kin_name, next_of_kin_phone, next_of_kin_relationship,
        outside_indebtedness_declaration,
        status, admission_decision_at, admission_rejection_reason,
        application_submitted_at, created_at
      `)
      .eq('status', 'Applicant')
      .is('admission_decision_at', null)
      .order('created_at', { ascending: true });

    if (error) return res.status(400).json({ error: error.message });

    const ids = (applicants || []).map((a) => a.id);
    let votes = [];
    if (ids.length) {
      const { data: rows, error: votesError } = await supabaseAdmin
        .from('admission_votes')
        .select(`
          id, member_id, voter_id, vote, vote_reason, voted_at,
          voter:members!admission_votes_voter_id_fkey(id, first_name, last_name, role)
        `)
        .in('member_id', ids);

      if (votesError) {
        return res.status(400).json({ error: votesError.message });
      }
      votes = rows || [];
    }

    const enriched = (applicants || []).map((a) => {
      const votesFor = votes.filter((v) => v.member_id === a.id);
      return {
        ...a,
        votes: votesFor,
        approve_count: votesFor.filter((v) => v.vote === 'Approve').length,
        reject_count:  votesFor.filter((v) => v.vote === 'Reject').length,
      };
    });

    res.json({ success: true, applicants: enriched });
  })
);

/**
 * POST /api/admin/members/vote
 * Record this committee member's vote on an applicant.
 * Decision finalises when the threshold is reached (2 of 3).
 */
router.post(
  '/members/vote',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const voterId = getMemberId(req);
    const { member_id, vote, reason } = req.body;

    if (!member_id) {
      return res.status(400).json({ error: 'member_id is required' });
    }
    if (!['Approve', 'Reject'].includes(vote)) {
      return res.status(400).json({ error: 'vote must be Approve or Reject' });
    }
    if (vote === 'Reject' && (!reason || !reason.trim())) {
      return res.status(400).json({
        error: 'Reason is required for rejection (Bye-law Section 10)',
      });
    }

    const result = await supabaseAdmin.rpc('record_admission_vote', {
      p_member_id: member_id,
      p_voter_id: voterId,
      p_vote: vote,
      p_reason: reason || null,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data?.success) {
      return res.status(400).json({ error: result.data?.error || 'Vote failed' });
    }

    // Audit
    await supabaseAdmin.rpc('write_audit', {
      p_action: 'ADMISSION_VOTE',
      p_resource_type: 'member',
      p_resource_id: member_id,
      p_details: {
        vote,
        reason: reason || null,
        approve_count: result.data.approve_count,
        reject_count: result.data.reject_count,
        finalised: result.data.finalised,
      },
    });

    res.json({ success: true, result: result.data });
  })
);

/**
 * POST /api/admin/members/update-status
 * Change a member's lifecycle status (Active / Suspended / Terminated / Exited).
 * Access: Chairman, Secretary, Treasurer, ManagementCommittee, SystemAdmin
 */
router.post(
  '/members/update-status',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { member_id, status, reason } = req.body;

    if (!member_id || !status) {
      return res.status(400).json({ error: 'member_id and status are required' });
    }
    if (!['Active', 'Suspended', 'Terminated', 'Exited'].includes(status)) {
      return res.status(400).json({ error: 'Invalid status' });
    }

    const updates = { status, updated_at: new Date().toISOString() };

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

    if (error) return res.status(400).json({ error: error.message });

    await supabaseAdmin.rpc('write_audit', {
      p_action: 'UPDATE_MEMBER_STATUS',
      p_resource_type: 'member',
      p_resource_id: member_id,
      p_details: { status, reason },
    });

    res.json({ success: true, member: data });
  })
);

/**
 * GET /api/admin/audit-log
 * Full audit trail. SystemAdmin only.
 */
router.get(
  '/audit-log',
  requireSystemAdmin,
  asyncHandler(async (req, res) => {
    const { limit = 100, offset = 0, action, from, to } = req.query;

    let query = supabaseAdmin.from('audit_log').select('*', { count: 'exact' });
    if (action) query = query.eq('action', action);
    if (from)   query = query.gte('created_at', from);
    if (to)     query = query.lte('created_at', to);

    const { data: logs, error, count } = await query
      .order('created_at', { ascending: false })
      .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);

    if (error) return res.status(400).json({ error: error.message });

    res.json({
      success: true,
      logs,
      pagination: {
        total: count,
        limit: parseInt(limit),
        offset: parseInt(offset),
      },
    });
  })
);

/**
 * POST /api/admin/fees
 * Post non-loan fees (entrance fee, loan form fee).
 */
router.post(
  '/fees',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { member_id, transaction_type, amount, reference, notes } = req.body;

    if (!member_id || !transaction_type || !amount) {
      return res.status(400).json({
        error: 'member_id, transaction_type, amount are required',
      });
    }
    if (!['ENTRANCE_FEE', 'LOAN_FORM_SALE'].includes(transaction_type)) {
      return res.status(400).json({ error: 'Invalid transaction_type' });
    }
    if (amount <= 0) {
      return res.status(400).json({ error: 'amount must be greater than zero' });
    }

    const result = await supabaseAdmin.rpc('post_non_loan_fee', {
      p_member_id: member_id,
      p_transaction_type: transaction_type,
      p_amount: amount,
      p_reference: reference || null,
      p_notes: notes || null,
    });

    if (!result.data) {
      return res.status(400).json({ error: 'Failed to post fee' });
    }

    res.json({
      success: true,
      ledger_entry_id: result.data,
      message: 'Fee posted successfully',
    });
  })
);

export default router;