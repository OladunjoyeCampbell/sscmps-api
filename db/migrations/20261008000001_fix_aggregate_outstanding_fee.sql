-- ============================================================
-- Include application fee in aggregate outstanding loans
-- ============================================================
-- get_loan_outstanding_balance (per loan) already includes the
-- application fee since migration 20261007000006. This brings
-- get_member_total_outstanding_loans (aggregate) into agreement.
--
-- Statuses remain ('Disbursed','Active','Defaulted'). 'Approved'
-- loans are intentionally excluded — the member does not owe
-- anything until the loan is disbursed.
-- ============================================================

create or replace function public.get_member_total_outstanding_loans(p_member_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(
    sum(greatest(0, (total_repayable + application_fee_charged) - total_repaid)),
    0
  )::numeric(12,2)
  from loans
  where member_id = p_member_id
    and status in ('Disbursed', 'Active', 'Defaulted');
$$;

grant execute on function public.get_member_total_outstanding_loans(uuid) to authenticated;

notify pgrst, 'reload schema';