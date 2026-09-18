// src/routes/treasury.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { requireTreasurer } from '../middleware/rbac.js';

const router = express.Router();

// ---------------------------------------------------------------------
// GET /api/treasury/dashboard
// Treasury dashboard aggregates.
// ---------------------------------------------------------------------
router.get(
  '/dashboard',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    // Management dashboard aggregates (extra panel data)
    const { data: dashboard, error: dashError } = await supabaseAdmin
      .from('management_dashboard')
      .select('*');

    if (dashError) {
      console.error('Dashboard error:', dashError);
    }

    // Pending payments
    const { count: pendingCount } = await supabaseAdmin
      .from('pending_transactions')
      .select('*', { count: 'exact', head: true });

    // Unidentified deposits
    const { count: unidentifiedCount } = await supabaseAdmin
      .from('unidentified_deposits')
      .select('*', { count: 'exact', head: true })
      .in('status', ['Unclaimed', 'Escalated']);

    // Today's transactions
    const today = new Date().toISOString().split('T')[0];
    const { count: todayCount } = await supabaseAdmin
      .from('ledger_entries')
      .select('*', { count: 'exact', head: true })
      .gte('created_at', today);

    // Aggregate savings from ledger (non-loan entries only)
    const { data: savingsEntries } = await supabaseAdmin
      .from('ledger_entries')
      .select('transaction_type, amount')
      .eq('status', 'Approved')
      .is('loan_id', null)
      .in('transaction_type', ['CONTRIBUTION', 'FINE', 'WITHDRAWAL']);

    let totalSavings = 0;
    for (const entry of savingsEntries || []) {
      const amt = parseFloat(entry.amount);
      if (entry.transaction_type === 'CONTRIBUTION') {
        totalSavings += amt;
      } else if (
        entry.transaction_type === 'FINE' ||
        entry.transaction_type === 'WITHDRAWAL'
      ) {
        totalSavings -= amt;
      }
    }

    // Aggregate loans outstanding
    const { data: loans } = await supabaseAdmin
      .from('loans')
      .select('total_repayable, total_repaid')
      .in('status', ['Active', 'Disbursed', 'Defaulted']);

    let totalOutstanding = 0;
    for (const loan of loans || []) {
      totalOutstanding +=
        parseFloat(loan.total_repayable) - parseFloat(loan.total_repaid);
    }

    // Delinquent loans
    const { count: delinquentCount } = await supabaseAdmin
      .from('loans')
      .select('*', { count: 'exact', head: true })
      .eq('status', 'Defaulted');

    // Defaulting members (missed contribution months not yet paid)
    const { data: defaultingRows } = await supabaseAdmin
      .from('member_contribution_defaults')
      .select('member_id')
      .eq('paid', false)
      .lt('due_date', today);

    const defaultingMemberIds = new Set(
      (defaultingRows || []).map((r) => r.member_id)
    );

    res.json({
      success: true,
      dashboard: {
        aggregate_savings: totalSavings,
        aggregate_loans_outstanding: totalOutstanding,
        pending_payments: pendingCount || 0,
        unidentified_deposits: unidentifiedCount || 0,
        today_transactions: todayCount || 0,
        delinquent_loans: delinquentCount || 0,
        defaulting_members_count: defaultingMemberIds.size,
        dashboard_data: dashboard || [],
      },
    });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/pending
// Unified pending queue.
// ---------------------------------------------------------------------
router.get(
  '/pending',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { data: pending, error } = await supabaseAdmin
      .from('pending_transactions')
      .select('*');

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, pending: pending || [] });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/unidentified
// Unidentified deposits.
// ---------------------------------------------------------------------
router.get(
  '/unidentified',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { status } = req.query;

    let query = supabaseAdmin.from('unidentified_deposits').select('*');
    if (status) query = query.eq('status', status);

    const { data: deposits, error } = await query.order('created_at', {
      ascending: true,
    });

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, deposits: deposits || [] });
  })
);

// ---------------------------------------------------------------------
// POST /api/treasury/unidentified/resolve
// Resolve an unidentified deposit.
// ---------------------------------------------------------------------
router.post(
  '/unidentified/resolve',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { deposit_id, member_id, savings_allocation, loan_allocations } =
      req.body;

    if (!deposit_id || !member_id) {
      return res
        .status(400)
        .json({ error: 'deposit_id and member_id are required' });
    }

    const result = await supabaseAdmin.rpc('resolve_unidentified_deposit', {
      p_id: deposit_id,
      p_member_id: member_id,
      p_savings: savings_allocation || 0,
      p_loans: loan_allocations || '[]',
    });

    if (!result.data) {
      return res.status(400).json({ error: 'Failed to resolve deposit' });
    }
    if (!result.data.success) {
      return res
        .status(400)
        .json({ error: result.data.error || 'Resolution failed' });
    }

    res.json({ success: true, result: result.data });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/portfolio
// Loan portfolio.
// ---------------------------------------------------------------------
router.get(
  '/portfolio',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { data: portfolio, error } = await supabaseAdmin
      .from('loan_portfolio')
      .select('*');

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, portfolio: portfolio || [] });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/reconciliation
// Monthly reconciliation snapshot.
// ---------------------------------------------------------------------
router.get(
  '/reconciliation',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { year, month } = req.query;

    if (!year || !month) {
      return res.status(400).json({ error: 'year and month are required' });
    }

    const monthStr = `${year}-${String(month).padStart(2, '0')}-01`;

    const { data: reconciliation, error } = await supabaseAdmin
      .from('monthly_reconciliation')
      .select('*')
      .eq('month', monthStr)
      .maybeSingle();

    if (error && error.code !== 'PGRST116') {
      return res.status(400).json({ error: error.message });
    }

    res.json({
      success: true,
      reconciliation: reconciliation || {
        month: monthStr,
        bank_matched: 0,
        approved_ledger: 0,
        unreconciled_bank_amount: 0,
      },
    });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/bank-transactions
// Bank transactions for reconciliation.
// ---------------------------------------------------------------------
router.get(
  '/bank-transactions',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const { status, from, to } = req.query;

    let query = supabaseAdmin.from('bank_transactions').select('*');
    if (status) query = query.eq('status', status);
    if (from && to) {
      query = query
        .gte('transaction_date', from)
        .lte('transaction_date', to);
    }

    const { data: transactions, error } = await query.order(
      'transaction_date',
      { ascending: false }
    );

    if (error) {
      return res.status(400).json({ error: error.message });
    }

    res.json({ success: true, transactions: transactions || [] });
  })
);

// ---------------------------------------------------------------------
// POST /api/treasury/ingest-api-credit
// Ingest an API credit from a bank feed.
// ---------------------------------------------------------------------
router.post(
  '/ingest-api-credit',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const {
      amount,
      transaction_date,
      bank_reference,
      narration,
      sender_name,
      sender_account,
      member_id,
      match_confidence,
      api_response,
      idempotency_key,
    } = req.body;

    if (!amount || !transaction_date || !bank_reference) {
      return res.status(400).json({
        error: 'amount, transaction_date, and bank_reference are required',
      });
    }

    const result = await supabaseAdmin.rpc('ingest_api_credit', {
      p_amount: amount,
      p_transaction_date: transaction_date,
      p_bank_reference: bank_reference,
      p_narration: narration || null,
      p_sender_name: sender_name || null,
      p_sender_account: sender_account || null,
      p_member_id: member_id || null,
      p_match_confidence: match_confidence || 'NONE',
      p_api_response: api_response || null,
      p_idempotency_key: idempotency_key || null,
    });

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data) {
      return res.status(400).json({ error: 'Failed to ingest API credit' });
    }

    res.json({
      success: true,
      payment_notification_id: result.data,
      message: 'API credit ingested successfully',
    });
  })
);

// ---------------------------------------------------------------------
// POST /api/treasury/run-compliance-check
// Bulk-flag all members with missed contributions. Idempotent — running
// twice on the same day has no additional effect. Fines are recorded
// as compliance events only; no ledger debits are created.
// ---------------------------------------------------------------------
router.post(
  '/run-compliance-check',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const result = await supabaseAdmin.rpc('run_compliance_check');

    if (result.error) {
      return res.status(400).json({ error: result.error.message });
    }
    if (!result.data?.success) {
      return res
        .status(400)
        .json({ error: result.data?.error || 'Compliance check failed' });
    }

    res.json({
      success: true,
      total_flagged: result.data.total_flagged,
      members_affected: result.data.members_affected,
      message:
        result.data.total_flagged === 0
          ? 'No new defaults detected.'
          : `${result.data.total_flagged} month(s) flagged across ${result.data.members_affected} member(s).`,
    });
  })
);

// ---------------------------------------------------------------------
// GET /api/treasury/defaulting-members
// List currently defaulting members with their unpaid months.
// No fines have been charged; this is a compliance record.
// ---------------------------------------------------------------------
router.get(
  '/defaulting-members',
  requireTreasurer,
  asyncHandler(async (req, res) => {
    const today = new Date().toISOString().split('T')[0];

    const { data, error } = await supabaseAdmin
      .from('member_contribution_defaults')
      .select(
        'member_id, staff_id, name, contribution_month, due_date, standing_contribution_amount, paid, flagged'
      )
      .eq('paid', false)
      .lt('due_date', today)
      .order('due_date', { ascending: true });

    if (error) return res.status(400).json({ error: error.message });

    // Collapse to one row per member with all defaulted months listed
    const grouped = {};
    for (const row of data || []) {
      if (!grouped[row.member_id]) {
        grouped[row.member_id] = {
          member_id: row.member_id,
          staff_id: row.staff_id,
          name: row.name,
          standing_contribution_amount: row.standing_contribution_amount,
          months: [],
          flagged: false,
        };
      }
      grouped[row.member_id].months.push({
        month: row.contribution_month,
        due_date: row.due_date,
        flagged: row.flagged,
      });
      if (row.flagged) grouped[row.member_id].flagged = true;
    }

    res.json({
      success: true,
      defaulting_members: Object.values(grouped),
      total_defaulting: Object.keys(grouped).length,
    });
  })
);

export default router;