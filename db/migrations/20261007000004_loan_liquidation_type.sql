-- ============================================================
-- LOAN_LIQUIDATION: internal transfer from savings to clear a loan
-- ============================================================
-- Reduces savings AND reduces loan. Used only during withdrawal
-- processing when outstanding loans are cleared first.
-- ============================================================

-- 1. Extend the CHECK constraint on ledger_entries.transaction_type
alter table public.ledger_entries
  drop constraint if exists ledger_entries_transaction_type_check;

alter table public.ledger_entries
  add constraint ledger_entries_transaction_type_check
  check (transaction_type in (
    'CONTRIBUTION','LOAN_DISBURSEMENT','LOAN_REPAYMENT','FINE',
    'WITHDRAWAL','REVERSAL','ENTRANCE_FEE','LOAN_FORM_SALE',
    'LOAN_LIQUIDATION'
  ));

-- 2. Update get_member_savings_balance to subtract LOAN_LIQUIDATION
create or replace function public.get_member_savings_balance(p_member_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select greatest(0, coalesce(sum(case
    when le.transaction_type in ('CONTRIBUTION','ENTRANCE_FEE') then le.amount
    when le.transaction_type in ('WITHDRAWAL','LOAN_LIQUIDATION') then -le.amount
    when le.transaction_type = 'REVERSAL' then
      case
        when parent.transaction_type in ('CONTRIBUTION','ENTRANCE_FEE') then -le.amount
        when parent.transaction_type in ('WITHDRAWAL','LOAN_LIQUIDATION') then le.amount
        else 0
      end
    else 0
  end), 0))::numeric(12,2)
  from public.ledger_entries le
  left join public.ledger_entries parent on parent.id = le.parent_ledger_entry_id
  where le.member_id = p_member_id
    and le.status = 'Approved';
$$;

-- 3. Update the loan_repayment_history view to include LOAN_LIQUIDATION
create or replace view public.loan_repayment_history as
select le.loan_id, l.loan_reference, l.member_id,
       le.transaction_date repayment_date,
       le.amount, le.payment_reference, le.payment_notification_id,
       le.allocation_notes
from public.ledger_entries le
join public.loans l on l.id = le.loan_id
where le.transaction_type in ('LOAN_REPAYMENT','LOAN_LIQUIDATION')
  and le.status = 'Approved';

notify pgrst, 'reload schema';