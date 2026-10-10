-- ============================================================
-- Fix SECURITY DEFINER views → SECURITY INVOKER
-- ============================================================
-- Supabase Advisor flagged three views as SECURITY DEFINER, which
-- bypasses Row Level Security. Recreating them with
-- WITH (security_invoker = true) makes the views execute with the
-- permissions of the querying user, so RLS policies on the base
-- tables apply normally.
--
-- The underlying functions (get_member_savings_balance, etc.) remain
-- SECURITY DEFINER and continue to work — they perform controlled
-- calculations that do not expose raw rows.
-- ============================================================

-- ---------- 1. member_dashboard ----------
-- Shows each member's savings and active loans. The view itself is
-- unfiltered (returns one row per member), so RLS on the members
-- table must do the row filtering for non-management users.

create or replace view public.member_dashboard
with (security_invoker = true)
as
select
  m.id                              as member_id,
  m.first_name,
  m.last_name,
  m.email,
  m.status,
  get_member_savings_balance(m.id)  as savings_balance,
  get_member_total_outstanding_loans(m.id) as total_outstanding_loans,
  coalesce(
    (
      select jsonb_agg(
        jsonb_build_object(
          'loan_id', l.id,
          'loan_reference', l.loan_reference,
          'product_type', lp.name,
          'principal', l.principal_amount,
          'monthly_instalment', l.monthly_instalment,
          'outstanding_balance', get_loan_outstanding_balance(l.id),
          'instalments_paid', l.instalments_paid,
          'instalments_remaining', greatest(0, l.term_months - l.instalments_paid),
          'status', l.status,
          'next_payment_due', l.next_payment_due_date,
          'repayment_progress',
            case
              when (l.total_repayable + l.application_fee_charged) = 0 then 0
              else round(
                l.total_repaid / (l.total_repayable + l.application_fee_charged) * 100,
                2
              )
            end
        )
        order by l.next_payment_due_date
      )
      from loans l
      join loan_products lp on lp.id = l.loan_product_id
      where l.member_id = m.id
        and l.status in ('Active', 'Disbursed', 'Defaulted')
    ),
    '[]'::jsonb
  )                                 as active_loans
from public.members m;

comment on view public.member_dashboard is
  'Per-member dashboard summary. SECURITY INVOKER — RLS on the '
  'members table filters rows for non-management users.';

-- ---------- 2. loan_portfolio ----------
-- Used by the Treasurer to see all active loans. Management roles
-- see all rows; members see only their own via RLS on the loans
-- table. The RLS policy on loans already allows members to select
-- their own rows.

create or replace view public.loan_portfolio
with (security_invoker = true)
as
select
  l.id                                  as loan_id,
  l.loan_reference,
  l.member_id,
  m.first_name,
  m.last_name,
  lp.name                               as loan_type,
  l.principal_amount,
  l.member_savings_at_disbursement,
  l.covered_principal,
  l.surplus_principal,
  l.normal_interest_applied,
  l.surplus_interest_applied,
  l.total_interest,
  l.application_fee_charged,
  l.total_repayable,
  l.total_repaid,
  greatest(
    0,
    (l.total_repayable + l.application_fee_charged) - l.total_repaid
  )                                     as outstanding_balance,
  l.monthly_instalment,
  l.instalments_paid,
  greatest(0, l.term_months - l.instalments_paid) as instalments_remaining,
  l.term_months,
  l.status,
  l.next_payment_due_date,
  case
    when l.next_payment_due_date < current_date
     and l.status in ('Active', 'Disbursed') then 'Overdue'
    when l.next_payment_due_date <= current_date + 7
     and l.status in ('Active', 'Disbursed') then 'Due Soon'
    else 'Current'
  end                                   as payment_status
from public.loans l
join public.members m on m.id = l.member_id
join public.loan_products lp on lp.id = l.loan_product_id
where l.status in ('Active', 'Disbursed', 'Defaulted');

comment on view public.loan_portfolio is
  'Active loan portfolio. SECURITY INVOKER — RLS on the loans table '
  'filters rows for members; management roles see all.';

-- ---------- 3. loan_repayment_history ----------
-- Lists every loan repayment for a member. RLS on ledger_entries
-- already restricts members to their own rows.

create or replace view public.loan_repayment_history
with (security_invoker = true)
as
select
  le.loan_id,
  l.loan_reference,
  l.member_id,
  le.transaction_date   as repayment_date,
  le.amount,
  le.payment_reference,
  le.payment_notification_id,
  le.allocation_notes
from public.ledger_entries le
join public.loans l on l.id = le.loan_id
where le.transaction_type in ('LOAN_REPAYMENT', 'LOAN_LIQUIDATION')
  and le.status = 'Approved';

comment on view public.loan_repayment_history is
  'Loan repayment history. SECURITY INVOKER — RLS on ledger_entries '
  'restricts members to their own repayments.';

notify pgrst, 'reload schema';