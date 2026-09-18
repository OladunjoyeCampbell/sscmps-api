import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import {
  requireLoanCommittee,
  requireLoanCommitteeChairman,
  requireTrustee,
  requireTreasurer,
} from '../middleware/rbac.js';

const router = express.Router();

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

const MANAGEMENT_ROLES = [
  'Treasurer',
  'Chairman',
  'Secretary',
  'LoanCommittee',
  'LoanCommitteeChairman',
  'ManagementCommittee',
  'SystemAdmin',
];

async function audit(action, resourceType, resourceId, details, req) {
  try {
    await supabaseAdmin.rpc('write_audit', {
      p_action: action,
      p_resource_type: resourceType,
      p_resource_id: resourceId,
      p_details: details,
      p_ip: req.ip || null,
      p_user_agent: req.headers['user-agent'] || null,
    });
  } catch (err) {
    console.warn('[audit] failed:', err.message);
  }
}

async function notify(memberId, category, subject, body, payload) {
  try {
    await supabaseAdmin.rpc('queue_notification', {
      p_member_id: memberId,
      p_category: category,
      p_subject: subject,
      p_body: body,
      p_payload: payload || {},
    });
  } catch (err) {
    console.warn('[notify] failed:', err.message);
  }
}

// ---------------------------------------------------------------------
// GET /api/loans/products
// ---------------------------------------------------------------------
router.get('/products', asyncHandler(async (req, res) => {
  const { data: products, error } = await supabaseAdmin
    .from('loan_products')
    .select('*')
    .eq('is_active', true)
    .order('name');

  if (error) return res.status(400).json({ error: error.message });
  res.json({ success: true, products });
}));

// ---------------------------------------------------------------------
// GET /api/loans/calculate
// ---------------------------------------------------------------------
router.get('/calculate', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { product_id, principal, term_months } = req.query;

  if (!product_id || !principal || !term_months) {
    return res.status(400).json({
      error: 'product_id, principal, term_months are required',
    });
  }

  const result = await supabaseAdmin.rpc('calculate_loan_terms', {
    p_member_id: memberId,
    p_loan_product_id: product_id,
    p_principal: parseFloat(principal),
    p_term_months: parseInt(term_months),
  });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to calculate loan terms' });
  }

  res.json({ success: true, terms: result.data });
}));

// ---------------------------------------------------------------------
// POST /api/loans/apply
// ---------------------------------------------------------------------
router.post('/apply', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const {
    loan_product_id, principal, term_months, purpose, application_notes,
  } = req.body;

  if (!loan_product_id || !principal || !term_months) {
    return res.status(400).json({
      error: 'loan_product_id, principal, term_months are required',
    });
  }

  if (principal <= 0) {
    return res.status(400).json({ error: 'Principal must be greater than zero' });
  }

  const result = await supabaseAdmin.rpc('submit_loan_application', {
    p_member_id: memberId,
    p_loan_product_id: loan_product_id,
    p_principal: parseFloat(principal),
    p_term_months: parseInt(term_months),
    p_purpose: purpose || null,
    p_application_notes: application_notes || null,
  });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }
  if (!result.data) {
    return res.status(400).json({ error: 'Failed to submit loan application' });
  }

  res.json({
    success: true,
    loan_id: result.data,
    message: 'Loan application submitted for review',
  });
}));

// ---------------------------------------------------------------------
// GET /api/loans/pending  (Committee / management queue)
// ---------------------------------------------------------------------
router.get('/pending', asyncHandler(async (req, res) => {
  const role = getMemberRole(req);
  if (!MANAGEMENT_ROLES.includes(role)) {
    return res.status(403).json({ error: 'Access denied' });
  }

  const { data: loans, error } = await supabaseAdmin
    .from('loans')
    .select(`
      id, loan_reference, member_id, loan_product_id, principal_amount,
      total_repayable, monthly_instalment, term_months,
      application_date, application_notes, purpose, status
    `)
    .eq('status', 'Pending')
    .order('application_date', { ascending: true });

  if (error) return res.status(400).json({ error: error.message });
  if (!loans || loans.length === 0) return res.json({ success: true, loans: [] });

  const memberIds = [...new Set(loans.map((l) => l.member_id))];
  const productIds = [...new Set(loans.map((l) => l.loan_product_id))];
  const loanIds = loans.map((l) => l.id);

  const [membersRes, productsRes, suretiesRes] = await Promise.all([
    supabaseAdmin.from('members')
      .select('id, staff_id, first_name, last_name, email')
      .in('id', memberIds),
    supabaseAdmin.from('loan_products')
      .select('id, name')
      .in('id', productIds),
    supabaseAdmin.from('sureties')
      .select('id, loan_id, surety_member_id, status, consent_given_at')
      .in('loan_id', loanIds),
  ]);

  const suretyMemberIds = [...new Set(
    (suretiesRes.data || []).map((s) => s.surety_member_id)
  )];
  const { data: suretyMembers } = await supabaseAdmin
    .from('members')
    .select('id, staff_id, first_name, last_name')
    .in('id', suretyMemberIds);

  const enriched = loans.map((loan) => ({
    ...loan,
    member: membersRes.data?.find((m) => m.id === loan.member_id) || null,
    product: productsRes.data?.find((p) => p.id === loan.loan_product_id) || null,
    sureties: (suretiesRes.data || [])
      .filter((s) => s.loan_id === loan.id)
      .map((s) => ({
        ...s,
        member: suretyMembers?.find((m) => m.id === s.surety_member_id) || null,
      })),
  }));

  res.json({ success: true, loans: enriched });
}));

// ---------------------------------------------------------------------
// GET /api/loans/committee-members
// Returns the list of members eligible to sit on the Loan Committee
// (used to populate the attendance checklist on the decision form).
// ---------------------------------------------------------------------
router.get('/committee-members', requireLoanCommitteeChairman, asyncHandler(async (req, res) => {
  const { data, error } = await supabaseAdmin
    .from('members')
    .select('id, staff_id, first_name, last_name, role')
    .in('role', ['LoanCommittee', 'LoanCommitteeChairman', 'Treasurer'])
    .eq('status', 'Active')
    .order('first_name');

  if (error) return res.status(400).json({ error: error.message });
  res.json({ success: true, members: data || [] });
}));
// ---------------------------------------------------------------------
// GET /api/loans/awaiting-signoff
// Approved loans with fewer than 2 trustee signatures.
// Visible to trustees (Chairman, Secretary, Treasurer).
// ---------------------------------------------------------------------
router.get('/awaiting-signoff', asyncHandler(async (req, res) => {
  const role = getMemberRole(req);
  if (!['Chairman', 'Secretary', 'Treasurer', 'SystemAdmin'].includes(role)) {
    return res.status(403).json({ error: 'Access denied' });
  }

  const { data: loans, error } = await supabaseAdmin
    .from('loans')
    .select(`
      id, loan_reference, member_id, principal_amount, term_months,
      total_repayable, monthly_instalment, application_date,
      approved_at, trustee_signoff_1, trustee_signoff_2,
      loan_products(name)
    `)
    .eq('status', 'Approved')
    .order('approved_at', { ascending: true });

  if (error) return res.status(400).json({ error: error.message });

  const filtered = (loans || []).filter((l) => {
    const count = (l.trustee_signoff_1 ? 1 : 0) + (l.trustee_signoff_2 ? 1 : 0);
    return count < 2;
  });

  // Enrich with borrower names
  const memberIds = [...new Set(filtered.map((l) => l.member_id))];
  const { data: borrowers } = memberIds.length
    ? await supabaseAdmin.from('members')
        .select('id, staff_id, first_name, last_name')
        .in('id', memberIds)
    : { data: [] };

  const enriched = filtered.map((l) => {
    const signoffCount =
      (l.trustee_signoff_1 ? 1 : 0) + (l.trustee_signoff_2 ? 1 : 0);
    return {
      ...l,
      borrower: borrowers?.find((m) => m.id === l.member_id) || null,
      signoff_count: signoffCount,
    };
  });

  res.json({ success: true, loans: enriched });
}));

// ---------------------------------------------------------------------
// GET /api/loans/ready-to-disburse
// Approved loans with both trustee signatures — awaiting Treasurer.
// ---------------------------------------------------------------------
router.get('/ready-to-disburse', asyncHandler(async (req, res) => {
  const role = getMemberRole(req);
  if (!['Treasurer', 'SystemAdmin'].includes(role)) {
    return res.status(403).json({ error: 'Access denied' });
  }

  const { data: loans, error } = await supabaseAdmin
    .from('loans')
    .select(`
      id, loan_reference, member_id, principal_amount, term_months,
      total_repayable, monthly_instalment, approved_at,
      trustee_signoff_1, trustee_signoff_2,
      trustee_signoff_1_at, trustee_signoff_2_at,
      loan_products(name)
    `)
    .eq('status', 'Approved')
    .not('trustee_signoff_1', 'is', null)
    .not('trustee_signoff_2', 'is', null)
    .order('approved_at', { ascending: true });

  if (error) return res.status(400).json({ error: error.message });

  const memberIds = [...new Set((loans || []).map((l) => l.member_id))];
  const { data: borrowers } = memberIds.length
    ? await supabaseAdmin.from('members')
        .select('id, staff_id, first_name, last_name')
        .in('id', memberIds)
    : { data: [] };

  const enriched = (loans || []).map((l) => ({
    ...l,
    borrower: borrowers?.find((m) => m.id === l.member_id) || null,
  }));

  res.json({ success: true, loans: enriched });
}));


// ---------------------------------------------------------------------
// GET /api/loans/my  (Member's own loans)
// ---------------------------------------------------------------------
router.get('/my', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { status } = req.query;

  let query = supabaseAdmin
    .from('loans')
    .select(`
      id, loan_reference, principal_amount, total_repayable,
      monthly_instalment, term_months, total_repaid,
      instalments_paid, next_payment_due_date, status,
      application_date, approved_at, disbursed_at,
      trustee_signoff_1, trustee_signoff_2,
      loan_product_id, loan_products(name)
    `)
    .eq('member_id', memberId);

  if (status) query = query.eq('status', status);

  const { data: loans, error } = await query
    .order('created_at', { ascending: false });

  if (error) return res.status(400).json({ error: error.message });

  const withBalance = await Promise.all(loans.map(async (loan) => {
    const { data: balance } = await supabaseAdmin
      .rpc('get_loan_outstanding_balance', { p_loan_id: loan.id });
    return { ...loan, outstanding_balance: balance || 0 };
  }));

  res.json({ success: true, loans: withBalance });
}));

// ---------------------------------------------------------------------
// GET /api/loans/all  (Treasurer portfolio)
// ---------------------------------------------------------------------
router.get('/all', requireTreasurer, asyncHandler(async (req, res) => {
  const { status, member_id } = req.query;
  let query = supabaseAdmin.from('loan_portfolio').select('*');
  if (status) query = query.eq('status', status);
  if (member_id) query = query.eq('member_id', member_id);

  const { data, error } = await query.order('created_at', { ascending: false });
  if (error) return res.status(400).json({ error: error.message });
  res.json({ success: true, loans: data || [] });
}));

// ---------------------------------------------------------------------
// GET /api/loans/:loanId  (Full detail — owner or management)
// MUST come after all specific /all, /my, /pending, /products etc.
// ---------------------------------------------------------------------


router.get('/:loanId', asyncHandler(async (req, res) => {
  const callerId = getMemberId(req);
  const callerRole = getMemberRole(req);
  const { loanId } = req.params;

  const { data: loan, error } = await supabaseAdmin
    .from('loans')
    .select(`
      id, loan_reference, member_id, loan_product_id, principal_amount,
      member_savings_at_disbursement, covered_principal, surplus_principal,
      normal_interest_applied, surplus_interest_applied, total_interest,
      application_fee_charged, total_repayable, monthly_instalment,
      term_months, total_repaid, instalments_paid, next_payment_due_date,
      status, application_date, application_notes, purpose,
      approved_at, approved_by, disbursed_by, disbursed_at,
      trustee_signoff_1, trustee_signoff_2,
      trustee_signoff_1_at, trustee_signoff_2_at,
      override_credit_limit, override_reason,
      closed_at, closed_reason, created_at, updated_at,
      loan_products(id, name, normal_interest_rate, surplus_interest_rate)
    `)
    .eq('id', loanId)
    .single();

  if (error || !loan) return res.status(404).json({ error: 'Loan not found' });

  const isOwner = loan.member_id === callerId;
  const isManagement = MANAGEMENT_ROLES.includes(callerRole);

  if (!isOwner && !isManagement) {
    return res.status(403).json({ error: 'Access denied' });
  }

  // Fetch related records in parallel
  const [
    borrowerRes,
    committeeDecisionRes,
    suretiesRes,
    scheduleRes,
    outstandingRes,
    signoff1Res,
    signoff2Res,
  ] = await Promise.all([
    supabaseAdmin.from('members')
      .select('id, staff_id, first_name, last_name, email, department, position')
      .eq('id', loan.member_id).single(),
    supabaseAdmin.from('loan_committee_decisions')
      .select('*')
      .eq('loan_id', loanId)
      .order('recorded_at', { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabaseAdmin.from('sureties')
      .select('id, surety_member_id, status, consent_given_at, created_at')
      .eq('loan_id', loanId),
    supabaseAdmin.from('loan_schedule_report')
      .select('*')
      .eq('loan_id', loanId)
      .order('instalment_number', { ascending: true }),
    supabaseAdmin.rpc('get_loan_outstanding_balance', { p_loan_id: loanId }),
    loan.trustee_signoff_1
      ? supabaseAdmin.from('members')
          .select('id, first_name, last_name, role')
          .eq('id', loan.trustee_signoff_1).single()
      : Promise.resolve({ data: null }),
    loan.trustee_signoff_2
      ? supabaseAdmin.from('members')
          .select('id, first_name, last_name, role')
          .eq('id', loan.trustee_signoff_2).single()
      : Promise.resolve({ data: null }),
  ]);

  const suretyMemberIds = (suretiesRes.data || []).map((s) => s.surety_member_id);
  const { data: suretyMembers } = suretyMemberIds.length
    ? await supabaseAdmin.from('members')
        .select('id, staff_id, first_name, last_name, department')
        .in('id', suretyMemberIds)
    : { data: [] };

  const sureties = (suretiesRes.data || []).map((s) => ({
    ...s,
    member: suretyMembers?.find((m) => m.id === s.surety_member_id) || null,
  }));

  const decision = committeeDecisionRes.data || null;
  const signoff1 = signoff1Res.data || null;
  const signoff2 = signoff2Res.data || null;
  const signoffCount = (loan.trustee_signoff_1 ? 1 : 0) + (loan.trustee_signoff_2 ? 1 : 0);
  const hasSignedOff = callerId === loan.trustee_signoff_1
    || callerId === loan.trustee_signoff_2;

  const canDecide =
    loan.status === 'Pending'
    && (callerRole === 'LoanCommitteeChairman' || callerRole === 'SystemAdmin');

  const canSignoff =
    loan.status === 'Approved'
    && ['Chairman', 'Secretary', 'Treasurer', 'SystemAdmin'].includes(callerRole)
    && !hasSignedOff
    && signoffCount < 2;

  const canDisburse =
    loan.status === 'Approved'
    && signoffCount >= 2
    && (callerRole === 'Treasurer' || callerRole === 'SystemAdmin');

  res.json({
    success: true,
    loan: {
      ...loan,
      outstanding_balance: outstandingRes.data || 0,
      borrower: borrowerRes.data || null,
      product: loan.loan_products || null,
      sureties,
      decision,
      signoff_1: signoff1,
      signoff_2: signoff2,
      signoff_count: signoffCount,
    },
    schedule: scheduleRes.data || [],
    permissions: { canDecide, canSignoff, canDisburse },
  });
}));

// ---------------------------------------------------------------------
// GET /api/loans/schedule/:loanId
// ---------------------------------------------------------------------
router.get('/schedule/:loanId', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loanId } = req.params;

  const { data: loan, error: loanError } = await supabaseAdmin
    .from('loans')
    .select('member_id, status')
    .eq('id', loanId)
    .single();

  if (loanError || !loan) return res.status(404).json({ error: 'Loan not found' });

  if (loan.member_id !== memberId) {
    const role = getMemberRole(req);
    if (!MANAGEMENT_ROLES.includes(role)) {
      return res.status(403).json({ error: 'Access denied' });
    }
  }

  const { data: schedule, error: scheduleError } = await supabaseAdmin
    .from('loan_schedule_report')
    .select('*')
    .eq('loan_id', loanId)
    .order('instalment_number', { ascending: true });

  if (scheduleError) return res.status(400).json({ error: scheduleError.message });
  res.json({ success: true, schedule: schedule || [] });
}));

// ---------------------------------------------------------------------
// POST /api/loans/decline   (Chairman declines before committee)
// ---------------------------------------------------------------------
router.post('/decline', requireLoanCommitteeChairman, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id, reason } = req.body;

  if (!loan_id) return res.status(400).json({ error: 'loan_id is required' });
  if (!reason || !reason.trim()) {
    return res.status(400).json({ error: 'Decline reason is required' });
  }

  const { data: loan, error: fetchError } = await supabaseAdmin
    .from('loans')
    .select('id, member_id, status')
    .eq('id', loan_id)
    .single();

  if (fetchError || !loan) return res.status(404).json({ error: 'Loan not found' });
  if (loan.status !== 'Pending') {
    return res.status(400).json({ error: 'Loan is not pending' });
  }

  const { error: updateError } = await supabaseAdmin
    .from('loans')
    .update({
      status: 'Closed',
      closed_at: new Date().toISOString(),
      closed_reason: `Declined by Loan Committee: ${reason}`,
      approved_by: memberId,
      approved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', loan_id);

  if (updateError) return res.status(400).json({ error: updateError.message });

  await audit('DECLINE_LOAN', 'loan', loan_id, { reason }, req);
  await notify(
    loan.member_id,
    'APPROVAL_REJECTION',
    'Loan application declined',
    `Your loan application was declined. Reason: ${reason}`,
    { loan_id }
  );

  res.json({ success: true, message: 'Loan declined' });
}));

// ---------------------------------------------------------------------
// POST /api/loans/committee-decision
// Replaces the old /approve route with full committee-decision recording.
// ---------------------------------------------------------------------
router.post('/committee-decision', requireLoanCommitteeChairman, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const {
    loan_id,
    decision,
    amount_approved,
    interest_rate,
    repayment_months,
    committee_members_present,
    decision_reason,
    notes,
  } = req.body;

  if (!loan_id) return res.status(400).json({ error: 'loan_id is required' });

  if (!['Approved', 'Rejected', 'Deferred'].includes(decision)) {
    return res.status(400).json({
      error: 'decision must be Approved, Rejected, or Deferred',
    });
  }

  if (!Array.isArray(committee_members_present)
      || committee_members_present.length < 3) {
    return res.status(400).json({
      error: 'At least 3 committee members must be marked present (Section 33)',
    });
  }

  const result = await supabaseAdmin.rpc('record_committee_decision', {
    p_loan_id: loan_id,
    p_recorded_by: memberId,
    p_decision: decision,
    p_amount_approved: amount_approved ?? null,
    p_interest_rate: interest_rate ?? null,
    p_repayment_months: repayment_months ?? null,
    p_committee_members_present: committee_members_present,
    p_decision_reason: decision_reason || null,
    p_notes: notes || null,
  });

  if (result.error) return res.status(400).json({ error: result.error.message });
  if (!result.data?.success) {
    return res.status(400).json({
      error: result.data?.error || 'Failed to record decision',
    });
  }

  // Look up borrower for notification
  const { data: loan } = await supabaseAdmin
    .from('loans')
    .select('member_id, loan_reference')
    .eq('id', loan_id)
    .single();

  await audit('RECORD_COMMITTEE_DECISION', 'loan', loan_id, {
    decision,
    amount_approved,
    interest_rate,
    repayment_months,
    committee_members_present,
  }, req);

  if (loan) {
    const subject = decision === 'Approved'
      ? `Loan ${loan.loan_reference} approved`
      : decision === 'Rejected'
        ? `Loan ${loan.loan_reference} rejected`
        : `Loan ${loan.loan_reference} deferred`;
    const body = decision === 'Approved'
      ? `Your loan has been approved by the Loan Committee. Awaiting trustee sign-off and disbursement.`
      : decision === 'Rejected'
        ? `Your loan application was rejected. Reason: ${decision_reason || 'Not stated'}`
        : `Your loan application has been deferred. Reason: ${decision_reason || 'Not stated'}`;

    await notify(loan.member_id, 'APPROVAL_REJECTION', subject, body, { loan_id });
  }

  res.json({
    success: true,
    result: result.data,
    message: `Committee decision recorded: ${decision}`,
  });
}));

// ---------------------------------------------------------------------
// POST /api/loans/signoff
// Records one trustee sign-off. Slot is derived server-side.
// ---------------------------------------------------------------------
router.post('/signoff', requireTrustee, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id } = req.body;

  if (!loan_id) return res.status(400).json({ error: 'loan_id is required' });

  const result = await supabaseAdmin.rpc('record_loan_trustee_signoff', {
    p_loan_id: loan_id,
    p_trustee_id: memberId,
  });

  if (result.error) return res.status(400).json({ error: result.error.message });
  if (!result.data?.success) {
    return res.status(400).json({
      error: result.data?.error || 'Failed to record sign-off',
    });
  }

  await audit('TRUSTEE_SIGNOFF', 'loan', loan_id, {
    slot: result.data.slot,
    trustee_id: memberId,
    trustee_role: result.data.trustee_role,
  }, req);

  // If this was the second signature, notify the Treasurer that disbursement is ready
  if (result.data.slot === 2) {
    const { data: treasurers } = await supabaseAdmin
      .from('members')
      .select('id')
      .eq('role', 'Treasurer')
      .eq('status', 'Active');

    const { data: loan } = await supabaseAdmin
      .from('loans')
      .select('loan_reference')
      .eq('id', loan_id)
      .single();

    for (const t of treasurers || []) {
      await notify(
        t.id,
        'PENDING_QUEUE',
        `Loan ready for disbursement`,
        `Loan ${loan?.loan_reference || loan_id} has received both trustee signatures and is ready for disbursement.`,
        { loan_id }
      );
    }
  }

  res.json({
    success: true,
    slot: result.data.slot,
    message: `Signed off (slot ${result.data.slot})`,
  });
}));

// ---------------------------------------------------------------------
// POST /api/loans/disburse
// Treasurer disburses after both signoffs are recorded.
// ---------------------------------------------------------------------
router.post('/disburse', requireTreasurer, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id, recorder_id } = req.body;

  if (!loan_id) return res.status(400).json({ error: 'loan_id is required' });

  // Pre-flight checks (defence in depth — the RPC should also validate)
  const { data: loan, error: fetchError } = await supabaseAdmin
    .from('loans')
    .select('id, status, trustee_signoff_1, trustee_signoff_2, member_id, loan_reference')
    .eq('id', loan_id)
    .single();

  if (fetchError || !loan) return res.status(404).json({ error: 'Loan not found' });

  if (loan.status !== 'Approved') {
    return res.status(400).json({
      error: `Loan status is ${loan.status}; only Approved loans can be disbursed`,
    });
  }

  if (!loan.trustee_signoff_1 || !loan.trustee_signoff_2) {
    return res.status(400).json({
      error: 'Two trustee signatures are required before disbursement (Section 55(d))',
    });
  }

  // Check committee decision exists
  const { data: decision } = await supabaseAdmin
    .from('loan_committee_decisions')
    .select('id, decision')
    .eq('loan_id', loan_id)
    .eq('decision', 'Approved')
    .maybeSingle();

  if (!decision) {
    return res.status(400).json({
      error: 'No approved committee decision found for this loan',
    });
  }

  // FR-5.2: Treasurer cannot be the sole actor. Since two distinct
  // trustees must have signed, and only 3 trustees exist, if the Treasurer
  // is one signatory then a non-Treasurer also signed. Both slots being
  // filled satisfies this requirement automatically.

  const result = await supabaseAdmin.rpc('disburse_loan', {
    p_loan_id: loan_id,
    p_recorder_id: recorder_id || memberId,
  });

  if (result.error) return res.status(400).json({ error: result.error.message });
  if (!result.data?.success) {
    return res.status(400).json({
      error: result.data?.error || 'Disbursement failed',
    });
  }

  await audit('DISBURSE_LOAN', 'loan', loan_id, {
    amount: result.data.amount || null,
    treasurer_id: memberId,
  }, req);

  await notify(
    loan.member_id,
    'LOAN_DISBURSEMENT',
    'Loan disbursed',
    `Your loan ${loan.loan_reference} has been disbursed. Check your repayment schedule.`,
    { loan_id }
  );

  res.json({ success: true, result: result.data });
}));

export default router;