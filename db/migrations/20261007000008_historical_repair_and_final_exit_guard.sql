-- ============================================================
-- Historical repair + Final Exit guard
-- ============================================================
-- 1. Relabel historical LOAN_REPAYMENT entries that were actually
--    liquidations (from withdrawal processing).
-- 2. Backfill members.status = 'Exited' for anyone with a processed
--    Final Exit.
-- 3. Add a DB-level check so a member cannot submit a Final Exit
--    if they already have one Pending/Approved/Processed.
-- ============================================================

-- ---------- 1. Relabel historical mislabeled liquidations ----------
update public.ledger_entries
set transaction_type = 'LOAN_LIQUIDATION'
where transaction_type = 'LOAN_REPAYMENT'
  and allocation_notes like 'Loan liquidated from savings during withdrawal%';

-- ---------- 2. Backfill Exited status for historical Final Exits ----------
update public.members m
set status = 'Exited',
    termination_date = coalesce(m.termination_date, current_date),
    termination_reason = coalesce(m.termination_reason, 'Final exit (processed historically)'),
    updated_at = now()
where exists (
  select 1 from public.withdrawal_requests wr
  where wr.member_id = m.id
    and wr.withdrawal_type = 'FINAL_EXIT'
    and wr.status = 'Processed'
)
and m.status <> 'Exited';

-- ---------- 3. Final-Exit-once guard function ----------
create or replace function public.can_request_final_exit(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select not exists (
    select 1 from withdrawal_requests
    where member_id = p_member_id
      and withdrawal_type = 'FINAL_EXIT'
      and status in ('Pending','Approved','Processed')
  );
$$;

grant execute on function public.can_request_final_exit(uuid) to authenticated;

notify pgrst, 'reload schema';