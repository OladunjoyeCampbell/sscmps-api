-- ============================================================
-- Migration alignment — bring live schema in line with the
-- member-migration requirements and the fines-tracking-only policy
-- ============================================================
-- Run BEFORE seeding the 74 members.
-- Idempotent — safe to re-run.
-- Non-destructive — no DROP TABLE / DROP COLUMN / DROP FUNCTION.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Add the two migration columns
-- ------------------------------------------------------------
alter table public.members
  add column if not exists compliance_tracking_from date;

alter table public.members
  add column if not exists contributions_count_historical integer not null default 0;

comment on column public.members.compliance_tracking_from is
  'Date from which contribution compliance is tracked. For migrated members, '
  'set at cutover to the month after the migration window. Months before this '
  'are treated as historical and are not re-evaluated by run_compliance_check.';

comment on column public.members.contributions_count_historical is
  'Lifetime count of contributions made before migration cutover. Combined '
  'with post-migration CONTRIBUTION ledger entries to enforce Bye-law §42(d): '
  '6 contributions total, not necessarily consecutive.';

update public.members
set compliance_tracking_from = date_trunc('month', current_date)::date
where compliance_tracking_from is null
  and status = 'Active';

-- ------------------------------------------------------------
-- 2. Auto-set compliance_tracking_from for new members
-- ------------------------------------------------------------
create or replace function public.set_compliance_tracking_from()
returns trigger
language plpgsql
security invoker
as $$
begin
  if new.compliance_tracking_from is null and new.first_contribution_date is not null then
    new.compliance_tracking_from := date_trunc('month', new.first_contribution_date)::date;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_members_compliance_start on public.members;
create trigger trg_members_compliance_start
  before insert or update of first_contribution_date on public.members
  for each row execute function public.set_compliance_tracking_from();

-- ------------------------------------------------------------
-- 3. Replace the compliance view to anchor on compliance_tracking_from
-- ------------------------------------------------------------
create or replace view public.member_contribution_defaults as
with expected as (
  select
    m.id as member_id,
    m.staff_id,
    m.first_name,
    m.last_name,
    m.standing_contribution_amount,
    gs.month_start
  from public.members m
  cross join lateral generate_series(
    date_trunc('month', m.compliance_tracking_from)::date,
    (date_trunc('month', current_date) - interval '1 month')::date,
    interval '1 month'
  ) as gs(month_start)
  where m.status = 'Active'
    and m.compliance_tracking_from is not null
)
select
  e.member_id,
  e.staff_id,
  (e.first_name || ' ' || e.last_name) as name,
  e.month_start::date as contribution_month,
  (e.month_start + interval '1 month' + interval '9 days')::date as due_date,
  e.standing_contribution_amount,
  case
    when exists (
      select 1 from public.ledger_entries le
      where le.member_id = e.member_id
        and le.transaction_type = 'CONTRIBUTION'
        and le.status = 'Approved'
        and date_trunc('month', le.transaction_date) = e.month_start
    ) then true
    else false
  end as paid,
  case
    when exists (
      select 1 from public.contribution_fine_events cfe
      where cfe.member_id = e.member_id
        and cfe.fine_type = 'MISSED_MONTH'
        and cfe.contribution_month = e.month_start::date
    ) then true
    else false
  end as flagged
from expected e;

-- ------------------------------------------------------------
-- 4. Replace get_member_savings_balance — remove FINE
-- ------------------------------------------------------------
create or replace function public.get_member_savings_balance(p_member_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select greatest(0, coalesce(sum(case
    when le.transaction_type in ('CONTRIBUTION','ENTRANCE_FEE') then le.amount
    when le.transaction_type = 'WITHDRAWAL' then -le.amount
    when le.transaction_type = 'REVERSAL' then
      case
        when parent.transaction_type in ('CONTRIBUTION','ENTRANCE_FEE') then -le.amount
        when parent.transaction_type = 'WITHDRAWAL' then le.amount
        else 0
      end
    else 0
  end), 0))::numeric(12,2)
  from public.ledger_entries le
  left join public.ledger_entries parent on parent.id = le.parent_ledger_entry_id
  where le.member_id = p_member_id
    and le.status = 'Approved'
    and le.loan_id is null;
$$;

-- ------------------------------------------------------------
-- 5. Replace process_withdrawal — remove the FINE entry
-- ------------------------------------------------------------
create or replace function public.process_withdrawal(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  w withdrawal_requests%rowtype;
  v_ledger uuid;
begin
  if app_role() <> 'Treasurer' then
    raise exception 'Only Treasurer may process withdrawals';
  end if;

  select * into w from withdrawal_requests where id = p_request_id for update;
  if w.status <> 'Approved' then
    raise exception 'Withdrawal must be approved first';
  end if;

  if w.recorder_id is null or not exists (select 1 from members where id = w.recorder_id) then
    raise exception 'A valid recorder is required';
  end if;

  if w.recorder_id = w.trustee_1 or w.recorder_id = w.trustee_2 then
    raise exception 'Recorder/signatory separation violated';
  end if;

  perform 1 from members where id = w.member_id for update;

  if w.requested_amount > get_member_savings_balance(w.member_id) then
    raise exception 'Withdrawal exceeds current available savings balance';
  end if;

  insert into ledger_entries(
    member_id, transaction_type, amount, source, status, approved_by, allocation_notes
  )
  values(
    w.member_id, 'WITHDRAWAL', w.requested_amount, 'SYSTEM', 'Approved', app_member_id(),
    'Approved savings withdrawal; gross N' || w.requested_amount ||
    ', net paid to member N' || w.net_amount ||
    case when w.charge_amount > 0 then ', charge N' || w.charge_amount else '' end
  )
  returning id into v_ledger;

  update withdrawal_requests
  set status = 'Processed', processed_at = now(), ledger_entry_id = v_ledger
  where id = w.id;

  perform write_audit(
    'PROCESS_WITHDRAWAL', 'withdrawal_request', w.id,
    jsonb_build_object(
      'ledger_entry', v_ledger,
      'gross', w.requested_amount,
      'charge', w.charge_amount,
      'net', w.net_amount
    )
  );

  return v_ledger;
end;
$$;

-- ------------------------------------------------------------
-- 6. Count-based eligibility — non-destructive replacement
--    ⬅ CHANGED: no DROP. The old function becomes a shim.
-- ------------------------------------------------------------

-- 6a. Create the new function under its proper name.
create or replace function public.member_has_min_contributions(
  p_member_id uuid,
  p_min_count integer default 6
)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select (
    coalesce(
      (select contributions_count_historical from public.members where id = p_member_id),
      0
    )
    + (select count(*)
       from public.ledger_entries
       where member_id = p_member_id
         and transaction_type = 'CONTRIBUTION'
         and status = 'Approved'
         and loan_id is null
         and (allocation_notes is null
              or allocation_notes not like 'Historical savings brought forward%'))
  ) >= p_min_count;
$$;

grant execute on function public.member_has_min_contributions(uuid, integer) to authenticated;

-- 6b. Keep the old name as a backwards-compatible shim.
--     Anything still calling it gets the correct new answer.
create or replace function public.member_has_six_consecutive_months(
  p_member_id uuid,
  p_as_of date default current_date
)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  -- Deprecated. Retained as a compatibility shim.
  -- Bye-law §42(d), as interpreted by the Committee: a member needs
  -- 6 contributions total (not necessarily consecutive) before their
  -- first loan. The p_as_of parameter is accepted but ignored.
  select public.member_has_min_contributions(p_member_id, 6);
$$;

-- ------------------------------------------------------------
-- 7. Fix the stale comment on assess_missed_contributions
-- ------------------------------------------------------------
comment on function public.assess_missed_contributions(date) is
  'Disabled. Fines on hold per Management decision (Oct 2026). Use '
  'run_compliance_check() instead — it records MISSED_MONTH events in '
  'contribution_fine_events without posting ledger debits.';

-- ------------------------------------------------------------
-- 8. Grant missing EXECUTE for the 3-arg calculate_loan_terms
-- ------------------------------------------------------------
grant execute on function public.calculate_loan_terms(uuid, uuid, numeric) to authenticated;

notify pgrst, 'reload schema';