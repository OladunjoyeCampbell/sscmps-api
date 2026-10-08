// src/routes/sureties.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId, getMemberRole } from '../middleware/auth.js';
import { requireLoanCommittee } from '../middleware/rbac.js';

const router = express.Router();

/**
 * POST /api/sureties/release
 * Release a surety from a Pending loan.
 * Callable by the applicant, the surety themselves, or the committee.
 * Once the loan is Approved, sureties are locked and cannot be released.
 */
router.post('/release', asyncHandler(async (req, res) => {
  const { loan_id, surety_member_id, reason } = req.body;

  if (!loan_id || !surety_member_id) {
    return res.status(400).json({
      error: 'loan_id and surety_member_id are required',
    });
  }

  const result = await supabaseAdmin.rpc('release_surety', {
    p_loan_id: loan_id,
    p_surety_member_id: surety_member_id,
    p_reason: reason || null,
  });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }
  if (!result.data?.success) {
    return res.status(400).json({
      error: result.data?.error || 'Release failed',
    });
  }

  res.json({ success: true, result: result.data });
}));


/**
 * POST /api/sureties/request
 * Request a surety for a loan (borrower)
 */
router.post('/request', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loan_id, surety_member_id } = req.body;

  if (!loan_id || !surety_member_id) {
    return res.status(400).json({ error: 'loan_id and surety_member_id are required' });
  }

  const result = await supabaseAdmin
    .rpc('request_surety', {
      p_loan_id: loan_id,
      p_surety_member_id: surety_member_id
    });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }

  if (!result.data) {
    return res.status(400).json({ error: 'Failed to request surety' });
  }

  res.json({
    success: true,
    surety_id: result.data,
    message: 'Surety request sent'
  });
}));

/**
 * POST /api/sureties/accept
 * Accept a surety request (the surety member)
 */
router.post('/accept', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { surety_id } = req.body;

  if (!surety_id) {
    return res.status(400).json({ error: 'surety_id is required' });
  }

  const { data: surety, error: checkError } = await supabaseAdmin
    .from('sureties')
    .select('surety_member_id, status')
    .eq('id', surety_id)
    .single();

  if (checkError || !surety) {
    return res.status(404).json({ error: 'Surety request not found' });
  }

  if (surety.surety_member_id !== memberId) {
    const role = getMemberRole(req);
    if (!['LoanCommittee', 'Treasurer', 'SystemAdmin'].includes(role)) {
      return res.status(403).json({ error: 'Not authorized to accept this surety' });
    }
  }

  if (surety.status !== 'Pending') {
    return res.status(400).json({ error: 'Surety request is not pending' });
  }

  const result = await supabaseAdmin
    .rpc('accept_surety', {
      p_surety_id: surety_id
    });

  if (result.error) {
    return res.status(400).json({ error: result.error.message });
  }

  res.json({ success: true, message: 'Surety accepted' });
}));

/**
 * POST /api/sureties/decline
 * Decline a surety request (the surety member)
 */
router.post('/decline', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { surety_id, reason } = req.body;

  if (!surety_id) {
    return res.status(400).json({ error: 'surety_id is required' });
  }

  // Fetch the surety
  const { data: surety, error: checkError } = await supabaseAdmin
    .from('sureties')
    .select('surety_member_id, status')
    .eq('id', surety_id)
    .single();

  if (checkError || !surety) {
    return res.status(404).json({ error: 'Surety request not found' });
  }

  // Only the named surety can decline
  if (surety.surety_member_id !== memberId) {
    return res.status(403).json({ error: 'Not authorized to decline this surety' });
  }

  // Can only decline pending requests
  if (surety.status !== 'Pending') {
    return res.status(400).json({ error: 'Surety request is not pending' });
  }

  // Update the status
  const { error: updateError } = await supabaseAdmin
    .from('sureties')
    .update({
      status: 'Declined',
      updated_at: new Date().toISOString(),
    })
    .eq('id', surety_id);

  if (updateError) {
    return res.status(400).json({ error: updateError.message });
  }

  // Log audit
  await supabaseAdmin.rpc('write_audit', {
    p_action: 'DECLINE_SURETY',
    p_resource_type: 'surety',
    p_resource_id: surety_id,
    p_details: { reason: reason || 'No reason provided' },
  });

  res.json({ success: true, message: 'Surety declined' });
}));

/**
 * GET /api/sureties/my
 * Get surety requests for the current member (as surety)
 */
router.get('/my', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);

  console.log('📋 Fetching sureties for member:', memberId);

  // Step 1: Get sureties for this member
  const { data: sureties, error } = await supabaseAdmin
    .from('sureties')
    .select('id, loan_id, status, consent_given_at, created_at')
    .eq('surety_member_id', memberId)
    .order('created_at', { ascending: false });

  if (error) {
    console.error('❌ Sureties query error:', error.message);
    return res.status(400).json({ error: error.message });
  }

  console.log('   Found', sureties?.length || 0, 'sureties');

  if (!sureties || sureties.length === 0) {
    return res.json({ success: true, sureties: [] });
  }

  // Step 2: Fetch loan details separately
  const loanIds = sureties.map((s) => s.loan_id);

  const { data: loans, error: loansError } = await supabaseAdmin
    .from('loans')
    .select(
      'id, loan_reference, principal_amount, total_repayable, term_months, status, closed_reason, member_id, loan_products(name, surety_response_window_hours)'
    )
    .in('id', loanIds);

  if (loansError) {
    console.error('❌ Loans query error:', loansError.message);
    return res.status(400).json({ error: loansError.message });
  }

  // Step 3: Fetch borrower details
  const borrowerIds = [...new Set((loans || []).map((l) => l.member_id))];

  const { data: borrowers, error: borrowersError } = await supabaseAdmin
    .from('members')
    .select('id, first_name, last_name')
    .in('id', borrowerIds);

  if (borrowersError) {
    console.error('❌ Borrowers query error:', borrowersError.message);
    return res.status(400).json({ error: borrowersError.message });
  }

  // Step 4: Merge into final structure
  const enrichedSureties = sureties.map((s) => {
    const loan = (loans || []).find((l) => l.id === s.loan_id) || {};
    const borrower = (borrowers || []).find((b) => b.id === loan.member_id) || {};

    return {
      ...s,
      loans: {
        ...loan,
        members: borrower,
      },
    };
  });

  console.log('✅ Returning', enrichedSureties.length, 'enriched sureties');

  res.json({ success: true, sureties: enrichedSureties });
}));


/**
 * GET /api/sureties/loan/:loanId
 * Get sureties for a specific loan (borrower or management)
 */
router.get('/loan/:loanId', asyncHandler(async (req, res) => {
  const memberId = getMemberId(req);
  const { loanId } = req.params;

  // Check loan exists and get borrower
  const { data: loan, error: loanError } = await supabaseAdmin
    .from('loans')
    .select('member_id, status')
    .eq('id', loanId)
    .single();

  if (loanError || !loan) {
    return res.status(404).json({ error: 'Loan not found' });
  }

  // Authorization check
  const role = getMemberRole(req);
  if (loan.member_id !== memberId && !['Treasurer', 'Chairman', 'Secretary', 'LoanCommittee', 'SystemAdmin'].includes(role)) {
    return res.status(403).json({ error: 'Access denied' });
  }

  // Get sureties
  const { data: sureties, error } = await supabaseAdmin
    .from('sureties')
    .select('id, surety_member_id, status, consent_given_at, created_at')
    .eq('loan_id', loanId)
    .order('created_at', { ascending: true });

  if (error) {
    return res.status(400).json({ error: error.message });
  }

  if (!sureties || sureties.length === 0) {
    return res.json({ success: true, sureties: [] });
  }

  // Fetch member details separately
  const suretyMemberIds = sureties.map((s) => s.surety_member_id);

  const { data: members } = await supabaseAdmin
    .from('members')
    .select('id, first_name, last_name, staff_id, email')
    .in('id', suretyMemberIds);

  // Merge
  const enrichedSureties = sureties.map((s) => {
    const member = (members || []).find((m) => m.id === s.surety_member_id) || {};
    return {
      ...s,
      members: member,
    };
  });

  res.json({ success: true, sureties: enrichedSureties });
}));
export default router;