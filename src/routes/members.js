// src/routes/members.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId } from '../middleware/auth.js';

const router = express.Router();

/**
 * GET /api/members/profile
 * Get own member profile
 */
router.get(
  '/profile',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    const { data: profile, error } = await supabaseAdmin
      .from('members')
      .select(`
        id, staff_id, first_name, last_name, middle_name, email, phone,
        department, position, home_address,
        next_of_kin_name, next_of_kin_phone, next_of_kin_relationship,
        status, role, admission_date, first_contribution_date,
        standing_contribution_amount, contribution_authority_reviewed
      `)
      .eq('id', memberId)
      .single();

    if (error) {
      return res.status(404).json({ error: 'Member not found' });
    }

    res.json({ success: true, profile });
  })
);

/**
 * PUT /api/members/profile
 * Update own member profile (non-critical fields only)
 */
router.put(
  '/profile',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const allowedFields = [
      'phone', 'department', 'position', 'home_address',
      'next_of_kin_name', 'next_of_kin_phone', 'next_of_kin_relationship',
    ];

    const updates = {};
    for (const field of allowedFields) {
      if (req.body[field] !== undefined) {
        updates[field] = req.body[field];
      }
    }

    if (Object.keys(updates).length === 0) {
      return res.status(400).json({ error: 'No valid fields to update' });
    }

    const { data, error } = await supabaseAdmin
      .from('members')
      .update(updates)
      .eq('id', memberId)
      .select()
      .single();

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, profile: data });
  })
);

/**
 * GET /api/members/dashboard
 * Member dashboard: savings, loans, and contribution defaults.
 */
router.get(
  '/dashboard',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);

    // Base dashboard from the view
    const { data: dashboard, error } = await supabaseAdmin
      .from('member_dashboard')
      .select('*')
      .eq('member_id', memberId)
      .single();

    if (error) {
      return res.status(404).json({ error: 'Dashboard not found' });
    }

    // Defaulting contribution months (unpaid, past due)
    const today = new Date().toISOString().split('T')[0];
    const { data: defaults } = await supabaseAdmin
      .from('member_contribution_defaults')
      .select('contribution_month, due_date, flagged')
      .eq('member_id', memberId)
      .eq('paid', false)
      .lt('due_date', today)
      .order('contribution_month', { ascending: true });

    const defaultingMonths = (defaults || []).map((r) =>
      new Date(r.contribution_month).toLocaleDateString('en-NG', {
        month: 'long',
        year: 'numeric',
      })
    );

    res.json({
      success: true,
      dashboard: {
        ...dashboard,
        defaulting_months: defaultingMonths,
      },
    });
  })
);

/**
 * GET /api/members/eligible-sureties
 * Get list of members eligible to be sureties
 * Excludes: self, inactive members, and members already surety for this loan
 */
router.get(
  '/eligible-sureties',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { exclude_loan_id } = req.query;

    const { data: members, error } = await supabaseAdmin
      .from('members')
      .select('id, staff_id, first_name, last_name, email, department, position')
      .eq('status', 'Active')
      .neq('id', memberId)
      .order('first_name');

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    let eligible = members || [];

    // Exclude members already sureties on the given loan
    if (exclude_loan_id) {
      const { data: existingSureties } = await supabaseAdmin
        .from('sureties')
        .select('surety_member_id')
        .eq('loan_id', exclude_loan_id);

      const existingIds = (existingSureties || []).map((s) => s.surety_member_id);
      eligible = eligible.filter((m) => !existingIds.includes(m.id));
    }

    // Exclude members already at their 2-guarantee limit.
    // Statuses match accept_surety's capacity check: any non-Closed loan
    // whose surety commitment is still live consumes capacity.
    const { data: activeLoans } = await supabaseAdmin
      .from('loans')
      .select('id')
      .in('status', ['Pending', 'Approved', 'Disbursed', 'Active', 'Defaulted']);

    const activeLoanIds = (activeLoans || []).map((l) => l.id);
    const membersWithMaxGuarantees = [];

    if (activeLoanIds.length > 0) {
      for (const member of eligible) {
        const { count } = await supabaseAdmin
          .from('sureties')
          .select('*', { count: 'exact', head: true })
          .eq('surety_member_id', member.id)
          .eq('status', 'Accepted')
          .in('loan_id', activeLoanIds);

        if (count >= 2) {
          membersWithMaxGuarantees.push(member.id);
        }
      }
    }

    eligible = eligible.filter((m) => !membersWithMaxGuarantees.includes(m.id));

    res.json({ success: true, members: eligible });
  })
);

/**
 * GET /api/members/statement
 * Generate member statement (PDF data)
 */
router.get(
  '/statement',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { from, to } = req.query;

    if (!from || !to) {
      return res.status(400).json({ error: 'from and to dates are required' });
    }

    const { data: member, error: memberError } = await supabaseAdmin
      .from('members')
      .select('id, first_name, last_name, staff_id, email')
      .eq('id', memberId)
      .single();

    if (memberError) {
      return res.status(404).json({ error: 'Member not found' });
    }

    const { data: transactions, error: txError } = await supabaseAdmin
      .from('member_statement_lines')
      .select('*')
      .eq('member_id', memberId)
      .gte('transaction_date', from)
      .lte('transaction_date', to)
      .order('transaction_date', { ascending: true });

    if (txError) {
      return res.status(400).json({ error: txError.message });
    }

    const { data: loans } = await supabaseAdmin
      .from('loans')
      .select(`
        id, loan_reference, principal_amount, total_repayable, monthly_instalment,
        term_months, total_repaid, status, application_date, disbursed_at
      `)
      .eq('member_id', memberId)
      .order('created_at', { ascending: false });

    const { data: balanceData } = await supabaseAdmin
      .rpc('get_member_savings_balance', { p_member_id: memberId });

    const { data: schedule } = await supabaseAdmin
      .from('loan_schedule_report')
      .select('*')
      .eq('member_id', memberId);

    res.json({
      success: true,
      statement: {
        member,
        period: { from, to },
        current_savings_balance: balanceData || 0,
        transactions,
        loans,
        repayment_schedule: schedule || [],
      },
    });
  })
);

/**
 * POST /api/members/contribution-authority
 * Request contribution authority revision (Jan or Jul only)
 */
router.post(
  '/contribution-authority',
  asyncHandler(async (req, res) => {
    const memberId = getMemberId(req);
    const { new_amount } = req.body;

    if (!new_amount || isNaN(new_amount) || new_amount < 10000) {
      return res.status(400).json({ error: 'Invalid amount (minimum N10,000)' });
    }

    const result = await supabaseAdmin.rpc('request_contribution_revision', {
      p_member_id: memberId,
      p_new_amount: new_amount,
    });

    if (!result.data) {
      return res.status(400).json({ error: 'Failed to process revision' });
    }

    res.json({ success: true, result: result.data });
  })
);

export default router;