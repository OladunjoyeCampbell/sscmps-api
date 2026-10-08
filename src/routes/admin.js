// src/routes/admin.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import {
  requireAdmissionCommittee,
  requireSystemAdmin,
  requireTreasurer,
} from '../middleware/rbac.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';

const router = express.Router();

// ─────────────────────────────────────────────────────────────────────
// MEMBER APPLICATIONS (voting)
// ─────────────────────────────────────────────────────────────────────

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
 *
 * NEW: when the new status is Terminated or Exited, stamp
 * session_invalidated_at so any open session is rejected on next refresh.
 */
router.post(
  '/members/update-status',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { member_id, status, reason } = req.body;

    if (!member_id || !status) {
      return res.status(400).json({ error: 'member_id and status are required' });
    }
    if (!['Active', 'Suspended'].includes(status)) {
      return res.status(400).json({
        error:
          'Status can only be set to Active or Suspended here. ' +
          'Termination and exit follow the bye-law processes: ' +
          'record-factual-termination, expulsion via general meeting, or member-initiated Final Exit.',
      });
    }

    const updates = { status, updated_at: new Date().toISOString() };

    if (status === 'Terminated' || status === 'Exited') {
      updates.termination_date = new Date().toISOString().split('T')[0];
      updates.termination_reason = reason || null;
      // NEW: force existing sessions to be rejected on next refresh
      updates.session_invalidated_at = new Date().toISOString();
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
 * POST /api/admin/members/:id/record-factual-termination
 * Records a factual termination (death, insanity, employment ended).
 * Creates a TERMINATION payout request and sets the member to Terminated.
 */
router.post(
  '/members/:id/record-factual-termination',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;
    const { event_type, event_date, reference } = req.body;
    const recordedBy = getMemberId(req);

    if (!event_type || !event_date || !reference) {
      return res.status(400).json({
        error: 'event_type, event_date, and reference are required',
      });
    }

    const result = await supabaseAdmin.rpc('record_factual_termination', {
      p_member_id: id,
      p_event_type: event_type,
      p_event_date: event_date,
      p_reference: reference,
      p_recorded_by: recordedBy,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }

    res.json({ success: true, result: result.data });
  })
);

/**
 * POST /api/admin/members/:id/recommend-expulsion
 * Management Committee recommendation to expel a member under §12.
 * Does NOT terminate — waits for the general meeting vote.
 */
router.post(
  '/members/:id/recommend-expulsion',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;
    const { ground, evidence } = req.body;
    const recommendedBy = getMemberId(req);

    if (!ground || !evidence) {
      return res.status(400).json({ error: 'ground and evidence are required' });
    }

    const result = await supabaseAdmin.rpc('recommend_member_expulsion', {
      p_member_id: id,
      p_ground: ground,
      p_evidence: evidence,
      p_recommended_by: recommendedBy,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }

    res.json({ success: true, recommendation_id: result.data });
  })
);

/**
 * POST /api/admin/expulsion-recommendations/:id/record-vote
 * Records the general meeting's decision on an expulsion recommendation.
 * 2/3 majority for → member becomes Terminated and payout is queued.
 */
router.post(
  '/expulsion-recommendations/:id/record-vote',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;
    const {
      meeting_date,
      votes_for,
      votes_against,
      votes_abstained = 0,
      resolution_reference,
      notes,
    } = req.body;
    const recordedBy = getMemberId(req);

    if (
      !meeting_date ||
      votes_for === undefined ||
      votes_against === undefined ||
      !resolution_reference
    ) {
      return res.status(400).json({
        error:
          'meeting_date, votes_for, votes_against, and resolution_reference are required',
      });
    }

    const result = await supabaseAdmin.rpc('record_expulsion_vote', {
      p_recommendation_id: id,
      p_meeting_date: meeting_date,
      p_votes_for: parseInt(votes_for, 10),
      p_votes_against: parseInt(votes_against, 10),
      p_votes_abstained: parseInt(votes_abstained, 10) || 0,
      p_resolution_reference: resolution_reference,
      p_recorded_by: recordedBy,
      p_notes: notes || null,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }

    res.json({ success: true, result: result.data });
  })
);

/**
 * GET /api/admin/members/:id/expulsion-recommendations
 * List expulsion recommendations for a member.
 */
router.get(
  '/members/:id/expulsion-recommendations',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;

    const { data, error } = await supabaseAdmin
      .from('member_expulsion_recommendations')
      .select(
        `id, member_id, ground, evidence, status, meeting_date,
         votes_for, votes_against, votes_abstained,
         resolution_reference, decided_at, notes, created_at,
         recommended_by:members!recommended_by(first_name, last_name, staff_id)`
      )
      .eq('member_id', id)
      .order('created_at', { ascending: false });

    if (error) return res.status(400).json({ error: error.message });

    res.json({ success: true, recommendations: data || [] });
  })
);

// ─────────────────────────────────────────────────────────────────────
// MEMBER ADMINISTRATION (search, view, edit existing members)
// ─────────────────────────────────────────────────────────────────────

/**
 * GET /api/admin/members
 * Searchable, paginated list of existing members.
 * Access: Secretary, Treasurer, Chairman, ManagementCommittee, SystemAdmin
 */
router.get(
  '/members',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const {
      search = '',
      status,
      role,
      limit = 50,
      offset = 0,
    } = req.query;

    let query = supabaseAdmin
      .from('members')
      .select(
        `id, staff_id, registration_number, first_name, middle_name, last_name,
         email, phone, department, position, status, role,
         admission_date, first_contribution_date, created_at`,
        { count: 'exact' }
      )
      .order('staff_id', { ascending: true });

    if (status) query = query.eq('status', status);
    if (role) query = query.eq('role', role);

    if (search && search.trim()) {
      const q = `%${search.trim()}%`;
      query = query.or(
        `staff_id.ilike.${q},registration_number.ilike.${q},first_name.ilike.${q},last_name.ilike.${q},email.ilike.${q},phone.ilike.${q},department.ilike.${q}`
      );
    }

    const limitN = Math.min(parseInt(limit, 10) || 50, 200);
    const offsetN = parseInt(offset, 10) || 0;

    const { data, error, count } = await query.range(
      offsetN,
      offsetN + limitN - 1
    );

    if (error) return res.status(400).json({ error: error.message });

    res.json({
      success: true,
      members: data || [],
      pagination: {
        total: count,
        limit: limitN,
        offset: offsetN,
      },
    });
  })
);

/**
 * GET /api/admin/members/:id
 * Full detail for a single member, including recent loans and payments.
 */
router.get(
  '/members/:id',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;

    const { data: member, error: memberError } = await supabaseAdmin
      .from('members')
      .select(
        `id, staff_id, registration_number, first_name, middle_name, last_name,
         email, phone, department, position, home_address,
         next_of_kin_name, next_of_kin_phone, next_of_kin_relationship,
         outside_indebtedness_declaration,
         status, role, admission_date, first_contribution_date,
         standing_contribution_amount, contribution_authority_reviewed,
         contribution_authority_form_date,
         termination_date, termination_reason,
         admission_decision_at, admission_decision_by,
         session_invalidated_at,
         auth_user_id, created_at, updated_at`
      )
      .eq('id', id)
      .maybeSingle();

    if (memberError || !member) {
      return res.status(404).json({ error: 'Member not found' });
    }

    const { data: loans } = await supabaseAdmin
      .from('loans')
      .select(
        `id, loan_reference, principal_amount, total_repayable, total_repaid,
         status, application_date, disbursed_at, term_months`
      )
      .eq('member_id', id)
      .order('created_at', { ascending: false })
      .limit(10);

    const { data: payments } = await supabaseAdmin
      .from('payment_notifications')
      .select(
        `id, amount, payment_reference, transaction_date, status, source, created_at`
      )
      .eq('member_id', id)
      .order('created_at', { ascending: false })
      .limit(10);

    const { data: suretiesGiven } = await supabaseAdmin
      .from('sureties')
      .select(
        `id, loan_id, status, consent_given_at,
         loans(loan_reference, principal_amount, status,
                members!loans_member_id_fkey(first_name, last_name, staff_id))`
      )
      .eq('surety_member_id', id)
      .order('created_at', { ascending: false })
      .limit(10);

    const { data: savingsBalance } = await supabaseAdmin.rpc(
      'get_member_savings_balance',
      { p_member_id: id }
    );

    const { data: outstandingLoans } = await supabaseAdmin.rpc(
      'get_member_total_outstanding_loans',
      { p_member_id: id }
    );

    res.json({
      success: true,
      member,
      savings_balance: savingsBalance || 0,
      loans_outstanding: outstandingLoans || 0,
      recent_loans: loans || [],
      recent_payments: payments || [],
      sureties_given: suretiesGiven || [],
    });
  })
);

/**
 * PUT /api/admin/members/:id/email
 * Change a member's email address. Audited separately because email
 * is a security credential.
 */
router.put(
  '/members/:id/email',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;
    const { email } = req.body;

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return res.status(400).json({ error: 'A valid email address is required' });
    }

    const normalized = email.trim().toLowerCase();

    const { data: existing } = await supabaseAdmin
      .from('members')
      .select('id')
      .eq('email', normalized)
      .neq('id', id)
      .maybeSingle();

    if (existing) {
      return res
        .status(409)
        .json({ error: 'Another member already uses that email address' });
    }

    const { data: member, error } = await supabaseAdmin
      .from('members')
      .select('id, email, auth_user_id')
      .eq('id', id)
      .maybeSingle();

    if (error || !member) {
      return res.status(404).json({ error: 'Member not found' });
    }

    const oldEmail = member.email;

    const { error: updateError } = await supabaseAdmin
      .from('members')
      .update({ email: normalized })
      .eq('id', id);

    if (updateError) {
      return res.status(400).json({ error: updateError.message });
    }

    if (member.auth_user_id) {
      const { error: authErr } = await supabaseAdmin.auth.admin.updateUserById(
        member.auth_user_id,
        { email: normalized, email_confirm: true }
      );
      if (authErr) {
        console.warn('[admin] auth email update failed:', authErr.message);
      }
    }

    await supabaseAdmin.rpc('write_audit', {
      p_action: 'ADMIN_CHANGE_EMAIL',
      p_resource_type: 'member',
      p_resource_id: id,
      p_details: { old_email: oldEmail, new_email: normalized },
    });

    res.json({
      success: true,
      message: 'Email updated. Ask the member to use Forgot password if needed.',
    });
  })
);

/**
 * PUT /api/admin/members/:id
 * Update editable fields (phone, department, position, home_address,
 * next of kin). Does NOT allow email, name, staff_id, or role changes.
 */
router.put(
  '/members/:id',
  requireAdmissionCommittee,
  asyncHandler(async (req, res) => {
    const { id } = req.params;

    const allowed = [
      'phone',
      'department',
      'position',
      'home_address',
      'next_of_kin_name',
      'next_of_kin_phone',
      'next_of_kin_relationship',
    ];

    const updates = {};
    for (const key of allowed) {
      if (req.body[key] !== undefined) updates[key] = req.body[key];
    }

    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ error: 'No valid fields to update' });
    }

    const { error } = await supabaseAdmin
      .from('members')
      .update(updates)
      .eq('id', id);

    if (error) return res.status(400).json({ error: error.message });

    await supabaseAdmin.rpc('write_audit', {
      p_action: 'ADMIN_UPDATE_MEMBER',
      p_resource_type: 'member',
      p_resource_id: id,
      p_details: updates,
    });

    res.json({ success: true });
  })
);

// ─────────────────────────────────────────────────────────────────────
// AUDIT LOG
// ─────────────────────────────────────────────────────────────────────

/**
 * GET /api/admin/audit-log
 * Full audit trail with member names resolved.
 * Access: Chairman, Secretary, Treasurer, SystemAdmin
 */
router.get(
  '/audit-log',
  asyncHandler(async (req, res) => {
    const callerRole = getMemberRole(req);
    if (!['Chairman', 'Secretary', 'Treasurer', 'SystemAdmin'].includes(callerRole)) {
      return res.status(403).json({ error: 'Access denied' });
    }

    const { limit = 100, offset = 0, action, from, to } = req.query;

    let query = supabaseAdmin.from('audit_log').select('*', { count: 'exact' });
    if (action) query = query.eq('action', action);
    if (from)   query = query.gte('created_at', from);
    if (to)     query = query.lte('created_at', to);

    const { data: logs, error, count } = await query
      .order('created_at', { ascending: false })
      .range(parseInt(offset), parseInt(offset) + parseInt(limit) - 1);

    if (error) return res.status(400).json({ error: error.message });

    // Enrichment: resolve member IDs to names
    const UUID_RE =
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    const collectIds = (val, acc) => {
      if (val == null) return;
      if (typeof val === 'string' && UUID_RE.test(val)) {
        acc.add(val);
        return;
      }
      if (Array.isArray(val)) {
        val.forEach((v) => collectIds(v, acc));
        return;
      }
      if (typeof val === 'object') {
        Object.values(val).forEach((v) => collectIds(v, acc));
      }
    };

    const ids = new Set();
    for (const log of logs || []) {
      if (log.actor_id) ids.add(log.actor_id);
      if (log.resource_type === 'member' && log.resource_id) {
        ids.add(log.resource_id);
      }
      if (log.details) collectIds(log.details, ids);
    }

    const memberLookup = {};
    if (ids.size > 0) {
      const { data: members } = await supabaseAdmin
        .from('members')
        .select('id, staff_id, first_name, last_name, role')
        .in('id', [...ids]);

      for (const m of members || []) {
        memberLookup[m.id] = {
          staff_id: m.staff_id,
          first_name: m.first_name,
          last_name: m.last_name,
          role: m.role,
          full_name: `${m.first_name} ${m.last_name}`,
        };
      }
    }

    res.json({
      success: true,
      logs,
      member_lookup: memberLookup,
      pagination: {
        total: count,
        limit: parseInt(limit),
        offset: parseInt(offset),
      },
    });
  })
);

// ─────────────────────────────────────────────────────────────────────
// FEES
// ─────────────────────────────────────────────────────────────────────

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