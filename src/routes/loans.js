import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireLoanCommittee, requireLoanCommitteeChairman, requireTrustee, requireTreasurer } from '../middleware/rbac.js';


const router = express.Router();

/**
 * GET /api/loans/products
 * Get available loan products
 */
router.get('/products', asyncHandler(async (req, res) => {
  const { data: products, error } = await supabaseAdmin
    .from('loan_products')
    .select('*')
    .eq('is_active', true)
    .order('name');

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, products });
}));

/**
 * GET /api/loans/calculate
 * Calculate loan terms (interest, instalment, etc.)
 */
router.get('/calculate', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { product_id, principal, term_months } = req.query;

  if (!product_id || !principal || !term_months) {
    return res.status(400).json({ error: 'product_id, principal, term_months are required' });
  }

  const result = await supabaseAdmin
    .rpc('calculate_loan_terms', {
      p_member_id: memberId,
      p_loan_product_id: product_id,
      p_principal: parseFloat(principal),
      p_term_months: parseInt(term_months)
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to calculate loan terms' });
  }

  res.json({ success: true, terms: result.data });
}));

/**
 * POST /api/loans/apply
 * Submit a loan application
 */
router.post('/apply', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_product_id, principal, term_months, purpose, application_notes } = req.body;

  console.log('📝 Loan application request:');
  console.log('   member_id:', memberId);
  console.log('   loan_product_id:', loan_product_id);
  console.log('   principal:', principal, '(type:', typeof principal, ')');
  console.log('   term_months:', term_months, '(type:', typeof term_months, ')');
  console.log('   purpose:', purpose);

  if (!loan_product_id || !principal || !term_months) {
    return res.status(400).json({
      error: 'loan_product_id, principal, term_months are required',
      received: { loan_product_id, principal, term_months }
    });
  }

  if (principal <= 0) {
    return res.status(400).json({ error: 'Principal must be greater than zero' });
  }

  console.log('🚀 Calling submit_loan_application RPC...');

  const result = await supabaseAdmin
    .rpc('submit_loan_application', {
      p_member_id: memberId,
      p_loan_product_id: loan_product_id,
      p_principal: parseFloat(principal),
      p_term_months: parseInt(term_months),
      p_purpose: purpose || null,
      p_application_notes: application_notes || null
    });

  console.log('📥 RPC result:', JSON.stringify(result, null, 2));

  if (result.error) {
    console.error('❌ RPC error:', result.error.message);
    return res.status(400).json({
      error: result.error.message || 'Database error',
      code: result.error.code,
      details: result.error.details,
      hint: result.error.hint,
    });
  }

  if (!result.data) {
    return res.status(400).json({
      error: 'Failed to submit loan application — no data returned'
    });
  }

  console.log('✅ Loan application created:', result.data);

  res.json({
    success: true,
    loan_id: result.data,
    message: 'Loan application submitted for review'
  });
}));

/**
 * GET /api/loans/pending
 * Get all pending loan applications (Loan Committee view)
 */
router.get('/pending', asyncHandler(async (req, res) => {
  const role = getMemberRole(req);

  const allowed = [
    'LoanCommitteeChairman',
    'LoanCommittee',
    'Treasurer',
    'Chairman',
    'Secretary',
    'SystemAdmin',
    'ManagementCommittee',
  ];

  if (!allowed.includes(role)) {
    return res.status(403).json({
      error: 'Access denied: Loan Committee access required',
      code: 'FORBIDDEN',
      required: allowed,
      userRole: role,
    });
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

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  if (!loans || loans.length === 0) {
    return res.json({ success: true, loans: [] });
  }

  // Fetch borrowers
  const memberIds = [...new Set(loans.map((l) => l.member_id))];
  const { data: members } = await supabaseAdmin
    .from('members')
    .select('id, staff_id, first_name, last_name, email')
    .in('id', memberIds);

  // Fetch products
  const productIds = [...new Set(loans.map((l) => l.loan_product_id))];
  const { data: products } = await supabaseAdmin
    .from('loan_products')
    .select('id, name')
    .in('id', productIds);

  // Fetch sureties
  const loanIds = loans.map((l) => l.id);
  const { data: sureties } = await supabaseAdmin
    .from('sureties')
    .select('id, loan_id, surety_member_id, status, consent_given_at')
    .in('loan_id', loanIds);

  // Fetch surety member details
  const suretyMemberIds = [...new Set((sureties || []).map((s) => s.surety_member_id))];
  const { data: suretyMembers } = await supabaseAdmin
    .from('members')
    .select('id, staff_id, first_name, last_name')
    .in('id', suretyMemberIds);

  // Enrich loans
  const enrichedLoans = loans.map((loan) => ({
    ...loan,
    member: members?.find((m) => m.id === loan.member_id) || null,
    product: products?.find((p) => p.id === loan.loan_product_id) || null,
    sureties: (sureties || [])
      .filter((s) => s.loan_id === loan.id)
      .map((s) => ({
        ...s,
        member: suretyMembers?.find((m) => m.id === s.surety_member_id) || null,
      })),
  }));

  res.json({ success: true, loans: enrichedLoans });
}));

/**
 * POST /api/loans/decline
 * Loan Committee Chairman declines a loan
 */
router.post('/decline', requireLoanCommitteeChairman, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id, reason } = req.body;

  if (!loan_id) {
    return res.status(400).json({ error: 'loan_id is required' });
  }

  if (!reason || !reason.trim()) {
    return res.status(400).json({ error: 'Decline reason is required' });
  }

  // Fetch the loan
  const { data: loan, error: fetchError } = await supabaseAdmin
    .from('loans')
    .select('id, member_id, status')
    .eq('id', loan_id)
    .single();

  if (fetchError || !loan) {
    return res.status(404).json({ error: 'Loan not found' });
  }

  if (loan.status !== 'Pending') {
    return res.status(400).json({ error: 'Loan is not pending' });
  }

  // Update loan status
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

  if (updateError) {
    return res.status(400).json({ error: updateError.message });
  }

  // Audit log (non-blocking)
  try {
    await supabaseAdmin.rpc('write_audit', {
      p_action: 'DECLINE_LOAN',
      p_resource_type: 'loan',
      p_resource_id: loan_id,
      p_details: { reason },
    });
  } catch (err) {
    console.warn('Audit log failed:', err.message);
  }

  // Notify member (non-blocking)
  try {
    await supabaseAdmin.rpc('queue_notification', {
      p_member_id: loan.member_id,
      p_category: 'APPROVAL_REJECTION',
      p_subject: 'Loan application declined',
      p_body: `Your loan application was declined. Reason: ${reason}`,
      p_payload: { loan_id },
    });
  } catch (err) {
    console.warn('Notification failed:', err.message);
  }

  res.json({ success: true, message: 'Loan declined' });
}));
/**
 * GET /api/loans/my
 * Get member's loans
 */
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
      loan_product_id, loan_products(name)
    `)
    .eq('member_id', memberId);

  if (status) {
    query = query.eq('status', status);
  }

  const { data: loans, error } = await query.order('created_at', { ascending: false });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  const loansWithBalance = await Promise.all(loans.map(async (loan) => {
    const { data: balance } = await supabaseAdmin
      .rpc('get_loan_outstanding_balance', { p_loan_id: loan.id });
    return { ...loan, outstanding_balance: balance || 0 };
  }));

  res.json({ success: true, loans: loansWithBalance });
}));

/**
 * GET /api/loans/schedule/:loanId
 * Get repayment schedule for a specific loan
 */
router.get('/schedule/:loanId', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loanId } = req.params;

  const { data: loan, error: loanError } = await supabaseAdmin
    .from('loans')
    .select('member_id, status')
    .eq('id', loanId)
    .single();

  if (loanError || !loan) {
    return res.status(404).json({ error: 'Loan not found' });
  }

  if (loan.member_id !== memberId) {
    const role = getMemberRole(req);
    if (!['Treasurer', 'Chairman', 'Secretary', 'LoanCommittee', 'SystemAdmin'].includes(role)) {
      return res.status(403).json({ error: 'Access denied' });
    }
  }

  const { data: schedule, error: scheduleError } = await supabaseAdmin
    .from('loan_schedule_report')
    .select('*')
    .eq('loan_id', loanId)
    .order('instalment_number', { ascending: true });

  if (scheduleError) {
    return res.status(400).json({ error: scheduleError.message });
  }

  res.json({ success: true, schedule });
}));

/**
 * POST /api/loans/approve
 * Loan Committee approves a loan
 */
router.post('/approve', requireLoanCommitteeChairman, asyncHandler(async (req, res) => {
  const { loan_id, override_credit_limit, override_reason } = req.body;

  if (!loan_id) {
    return res.status(400).json({ error: 'loan_id is required' });
  }

  const result = await supabaseAdmin
    .rpc('approve_loan', {
      p_loan_id: loan_id,
      p_override_credit_limit: override_credit_limit || false,
      p_override_reason: override_reason || null
    });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to approve loan' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Loan approval failed' });
  }

  res.json({ success: true, result: result.data });
}));

/**
 * POST /api/loans/signoff
 * Trustee sign-off for loan disbursement
 */
router.post('/signoff', requireTrustee, asyncHandler(async (req, res) => {
  const { loan_id, signoff_number } = req.body;

  if (!loan_id) {
    return res.status(400).json({ error: 'loan_id is required' });
  }

  if (!signoff_number || ![1, 2].includes(parseInt(signoff_number))) {
    return res.status(400).json({ error: 'signoff_number must be 1 or 2' });
  }

  const result = await supabaseAdmin
    .rpc('record_loan_trustee_signoff', {
      p_loan_id: loan_id,
      p_signoff_number: parseInt(signoff_number)
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to record sign-off' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Sign-off failed' });
  }

  res.json({ success: true, result: result.data });
}));

/**
 * POST /api/loans/disburse
 * Disburse the loan (Treasurer)
 */
router.post('/disburse', requireTreasurer, asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id, recorder_id } = req.body;

  if (!loan_id) {
    return res.status(400).json({ error: 'loan_id is required' });
  }

  const result = await supabaseAdmin
    .rpc('disburse_loan', {
      p_loan_id: loan_id,
      p_recorder_id: recorder_id || memberId
    });

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to disburse loan' });
  }

  if (!result.data.success) {
    return res.status(400).json({ error: result.data.error || 'Disbursement failed' });
  }

  res.json({ success: true, result: result.data });
}));

/**
 * GET /api/loans/all (Treasurer/Management)
 * Get all loans (portfolio view)
 */
router.get('/all', requireTreasurer, asyncHandler(async (req, res) => {
  const { status, member_id } = req.query;

  let query = supabaseAdmin.from('loan_portfolio').select('*');

  if (status) {
    query = query.eq('status', status);
  }

  if (member_id) {
    query = query.eq('member_id', member_id);
  }

  const { data: loans, error } = await query.order('created_at', { ascending: false });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  res.json({ success: true, loans });
}));

export default router;