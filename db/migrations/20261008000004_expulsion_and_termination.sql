-- ============================================================
-- Correct termination flows per Bye-law §11, §12, §20(b)
-- ============================================================
-- Three paths:
--   1. Factual termination (death / insanity / employment ended)
--   2. Expulsion recommended by management, decided by general meeting
--   3. Voluntary final exit (already handled by withdrawal workflow)
--
-- Terminated = factual cause or expulsion
-- Exited     = voluntary withdrawal
-- ============================================================

-- ---------- 1. Supporting columns ----------
alter table public.members
  add column if not exists termination_reference text;

comment on column public.members.termination_reference is
  'Supporting reference for a termination (e.g., death certificate number, '
  'employment termination letter, or general meeting resolution reference).';

-- ---------- 2. Expulsion recommendations table ----------
create table if not exists public.member_expulsion_recommendations (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members(id) on delete cascade,
  recommended_by uuid not null references members(id),
  ground text not null check (ground in (
    'MISSED_CONTRIBUTIONS',    -- §12(a)
    'UNPAID_DEBTS',            -- §12(b)
    'CRIMINAL_CONVICTION',     -- §12(c)
    'MISCONDUCT'               -- §12(d)
  )),
  evidence text not null,
  status text not null default 'Pending'
    check (status in ('Pending','Upheld','Dismissed')),
  meeting_date date,
  votes_for integer,
  votes_against integer,
  votes_abstained integer,
  resolution_reference text,
  decided_at timestamptz,
  decided_by uuid references members(id),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists idx_expulsion_recs_member
  on public.member_expulsion_recommendations(member_id);
create index if not exists idx_expulsion_recs_status
  on public.member_expulsion_recommendations(status);

alter table public.member_expulsion_recommendations enable row level security;

drop policy if exists expulsion_recs_committee_select on public.member_expulsion_recommendations;
create policy expulsion_recs_committee_select
  on public.member_expulsion_recommendations
  for select using (
    app_role() in ('Chairman','Secretary','Treasurer','ManagementCommittee','SystemAdmin')
  );

drop policy if exists expulsion_recs_self_select on public.member_expulsion_recommendations;
create policy expulsion_recs_self_select
  on public.member_expulsion_recommendations
  for select using (member_id = app_member_id());

-- ---------- 3. Factual termination RPC ----------
create or replace function public.record_factual_termination(
  p_member_id uuid,
  p_event_type text,
  p_event_date date,
  p_reference text,
  p_recorded_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member members%rowtype;
  v_role text;
  v_savings numeric(12,2);
  v_request_id uuid;
  v_reason text;
begin
  select role into v_role from members where id = p_recorded_by;
  if v_role not in ('Secretary','Chairman','Treasurer','ManagementCommittee','SystemAdmin') then
    raise exception 'Only management may record a factual termination';
  end if;

  if p_event_type not in ('DEATH','INSANITY','EMPLOYMENT_ENDED') then
    raise exception 'event_type must be DEATH, INSANITY, or EMPLOYMENT_ENDED';
  end if;

  if p_reference is null or length(trim(p_reference)) = 0 then
    raise exception 'A reference (certificate or letter number) is required';
  end if;

  select * into v_member from members where id = p_member_id for update;
  if not found then
    raise exception 'Member not found';
  end if;

  if v_member.status in ('Terminated','Exited') then
    raise exception 'Member is already %', v_member.status;
  end if;

  if exists (
    select 1 from withdrawal_requests
    where member_id = p_member_id and status in ('Pending','Approved')
  ) then
    raise exception 'Member already has a pending or approved withdrawal request';
  end if;

  if exists (
    select 1 from loans
    where member_id = p_member_id and status = 'Approved'
  ) then
    raise exception 'Member has an approved loan awaiting disbursement';
  end if;

  v_savings := get_member_savings_balance(p_member_id);
  v_reason := case p_event_type
    when 'DEATH' then format('Death (ref: %s)', p_reference)
    when 'INSANITY' then format('Permanent insanity (ref: %s)', p_reference)
    when 'EMPLOYMENT_ENDED' then format('Employment ended (ref: %s)', p_reference)
  end;

  update members set
    status = 'Terminated',
    termination_date = p_event_date,
    termination_reason = v_reason,
    termination_reference = p_reference,
    session_invalidated_at = now(),
    updated_at = now()
  where id = p_member_id;

  if v_savings > 0 then
    insert into withdrawal_requests (
      member_id, withdrawal_type, requested_amount,
      charge_amount, net_amount, reason, status, created_by
    ) values (
      p_member_id, 'TERMINATION', v_savings, 0, v_savings,
      v_reason, 'Pending', p_recorded_by
    ) returning id into v_request_id;
  end if;

  perform write_audit('RECORD_FACTUAL_TERMINATION','member',p_member_id,
    jsonb_build_object(
      'event_type', p_event_type, 'event_date', p_event_date,
      'reference', p_reference, 'recorded_by', p_recorded_by,
      'savings', v_savings, 'withdrawal_request_id', v_request_id));

  return jsonb_build_object('success', true, 'withdrawal_request_id', v_request_id);
end;
$$;

grant execute on function public.record_factual_termination(uuid,text,date,text,uuid)
  to authenticated;

-- ---------- 4. Recommend expulsion RPC ----------
create or replace function public.recommend_member_expulsion(
  p_member_id uuid,
  p_ground text,
  p_evidence text,
  p_recommended_by uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_role text;
  v_member members%rowtype;
  v_rec_id uuid;
begin
  select role into v_role from members where id = p_recommended_by;
  if v_role not in ('Chairman','Secretary','Treasurer','ManagementCommittee','SystemAdmin') then
    raise exception 'Only management may recommend expulsion';
  end if;

  if p_ground not in ('MISSED_CONTRIBUTIONS','UNPAID_DEBTS','CRIMINAL_CONVICTION','MISCONDUCT') then
    raise exception 'Invalid ground';
  end if;

  if p_evidence is null or length(trim(p_evidence)) = 0 then
    raise exception 'Evidence/description is required';
  end if;

  select * into v_member from members where id = p_member_id;
  if not found then
    raise exception 'Member not found';
  end if;

  if v_member.status in ('Terminated','Exited') then
    raise exception 'Member is already %', v_member.status;
  end if;

  if exists (
    select 1 from member_expulsion_recommendations
    where member_id = p_member_id and status = 'Pending'
  ) then
    raise exception 'A pending expulsion recommendation already exists';
  end if;

  insert into member_expulsion_recommendations (
    member_id, recommended_by, ground, evidence, status
  ) values (
    p_member_id, p_recommended_by, p_ground, trim(p_evidence), 'Pending'
  ) returning id into v_rec_id;

  perform write_audit('RECOMMEND_EXPULSION','member',p_member_id,
    jsonb_build_object(
      'recommendation_id', v_rec_id, 'ground', p_ground,
      'recommended_by', p_recommended_by));

  return v_rec_id;
end;
$$;

grant execute on function public.recommend_member_expulsion(uuid,text,text,uuid)
  to authenticated;

-- ---------- 5. Record expulsion vote RPC ----------
create or replace function public.record_expulsion_vote(
  p_recommendation_id uuid,
  p_meeting_date date,
  p_votes_for integer,
  p_votes_against integer,
  p_votes_abstained integer,
  p_resolution_reference text,
  p_recorded_by uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_rec member_expulsion_recommendations%rowtype;
  v_member members%rowtype;
  v_role text;
  v_savings numeric(12,2);
  v_total_voting integer;
  v_threshold numeric;
  v_upheld boolean;
  v_request_id uuid;
begin
  select role into v_role from members where id = p_recorded_by;
  if v_role not in ('Secretary','Chairman','SystemAdmin') then
    raise exception 'Only Secretary or Chairman may record the general meeting decision';
  end if;

  if p_votes_for < 0 or p_votes_against < 0 or coalesce(p_votes_abstained,0) < 0 then
    raise exception 'Vote counts must be non-negative';
  end if;

  if p_resolution_reference is null or length(trim(p_resolution_reference)) = 0 then
    raise exception 'A meeting resolution reference is required';
  end if;

  select * into v_rec from member_expulsion_recommendations
  where id = p_recommendation_id for update;
  if not found then
    raise exception 'Recommendation not found';
  end if;
  if v_rec.status <> 'Pending' then
    raise exception 'Recommendation is already %', v_rec.status;
  end if;

  select * into v_member from members where id = v_rec.member_id for update;
  if not found then
    raise exception 'Member not found';
  end if;

  v_total_voting := p_votes_for + p_votes_against;
  if v_total_voting = 0 then
    raise exception 'At least one vote for or against is required';
  end if;

  v_threshold := p_votes_for::numeric / v_total_voting::numeric;
  v_upheld := v_threshold >= (2.0/3.0);

  if v_upheld then
    v_savings := get_member_savings_balance(v_rec.member_id);

    update member_expulsion_recommendations set
      status = 'Upheld',
      meeting_date = p_meeting_date,
      votes_for = p_votes_for,
      votes_against = p_votes_against,
      votes_abstained = p_votes_abstained,
      resolution_reference = p_resolution_reference,
      decided_at = now(),
      decided_by = p_recorded_by,
      notes = p_notes
    where id = p_recommendation_id;

    update members set
      status = 'Terminated',
      termination_date = p_meeting_date,
      termination_reason = format('Expulsion by two-thirds majority of general meeting (ref: %s)', p_resolution_reference),
      termination_reference = p_resolution_reference,
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_rec.member_id;

    if v_savings > 0 then
      insert into withdrawal_requests (
        member_id, withdrawal_type, requested_amount,
        charge_amount, net_amount, reason, status, created_by
      ) values (
        v_rec.member_id, 'TERMINATION', v_savings, 0, v_savings,
        format('Expulsion upheld (ref: %s)', p_resolution_reference),
        'Pending', p_recorded_by
      ) returning id into v_request_id;
    end if;

    perform write_audit('EXPULSION_UPHELD','member',v_rec.member_id,
      jsonb_build_object(
        'recommendation_id', p_recommendation_id,
        'votes_for', p_votes_for, 'votes_against', p_votes_against,
        'votes_abstained', p_votes_abstained,
        'threshold', round(v_threshold, 4),
        'withdrawal_request_id', v_request_id));

    return jsonb_build_object(
      'success', true, 'upheld', true,
      'threshold_met', round(v_threshold, 4),
      'withdrawal_request_id', v_request_id);
  else
    update member_expulsion_recommendations set
      status = 'Dismissed',
      meeting_date = p_meeting_date,
      votes_for = p_votes_for,
      votes_against = p_votes_against,
      votes_abstained = p_votes_abstained,
      resolution_reference = p_resolution_reference,
      decided_at = now(),
      decided_by = p_recorded_by,
      notes = p_notes
    where id = p_recommendation_id;

    perform write_audit('EXPULSION_DISMISSED','member',v_rec.member_id,
      jsonb_build_object(
        'recommendation_id', p_recommendation_id,
        'votes_for', p_votes_for, 'votes_against', p_votes_against,
        'votes_abstained', p_votes_abstained,
        'threshold', round(v_threshold, 4)));

    return jsonb_build_object(
      'success', true, 'upheld', false,
      'threshold_met', round(v_threshold, 4));
  end if;
end;
$$;

grant execute on function public.record_expulsion_vote(uuid,date,integer,integer,integer,text,uuid,text)
  to authenticated;

-- ---------- 6. process_withdrawal_with_liquidation — keep TERMINATION as Terminated ----------
create or replace function public.process_withdrawal_with_liquidation(
  p_request_id uuid,
  p_processed_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_request withdrawal_requests%rowtype;
  v_savings_before numeric(12,2);
  v_loans_outstanding numeric(12,2);
  v_savings_after numeric(12,2);
  v_loan record;
  v_remaining numeric(12,2);
  v_loan_repaid_total numeric(12,2) := 0;
  v_loans_closed integer := 0;
  v_cap numeric(12,2);
  v_gross numeric(12,2);
  v_charge numeric(12,2);
  v_net numeric(12,2);
  v_ledger uuid;
  v_approved_loan record;
begin
  select * into v_request from withdrawal_requests
  where id = p_request_id for update;
  if not found then
    return jsonb_build_object('success', false, 'error', 'Request not found');
  end if;
  if v_request.status <> 'Approved' then
    return jsonb_build_object('success', false,
      'error', format('Request is %s; only Approved requests can be processed', v_request.status));
  end if;

  select l.loan_reference into v_approved_loan
  from loans l
  where l.member_id = v_request.member_id and l.status = 'Approved'
  limit 1;
  if found then
    return jsonb_build_object('success', false,
      'error', format(
        'Member has an approved loan (%s) awaiting disbursement. Disburse or cancel it first.',
        v_approved_loan.loan_reference));
  end if;

  v_savings_before := get_member_savings_balance(v_request.member_id);
  v_loans_outstanding := get_member_total_outstanding_loans(v_request.member_id);

  if v_loans_outstanding > 0 then
    for v_loan in
      select id, loan_reference, total_repayable, application_fee_charged, total_repaid
      from loans
      where member_id = v_request.member_id
        and status in ('Active','Disbursed','Defaulted')
      order by disbursed_at asc nulls last, created_at asc
      for update
    loop
      v_remaining := (v_loan.total_repayable + v_loan.application_fee_charged) - v_loan.total_repaid;
      exit when v_remaining <= 0;
      exit when v_loan_repaid_total >= v_savings_before;

      declare
        v_available numeric(12,2);
        v_this numeric(12,2);
      begin
        v_available := v_savings_before - v_loan_repaid_total;
        v_this := least(v_remaining, v_available);

        insert into ledger_entries (
          member_id, loan_id, transaction_type, amount, source, status,
          approved_by, allocation_notes
        ) values (
          v_request.member_id, v_loan.id, 'LOAN_LIQUIDATION',
          v_this, 'SYSTEM', 'Approved', p_processed_by,
          format('Savings applied to clear loan %s during withdrawal processing (request %s)',
                 v_loan.loan_reference, p_request_id));

        update loans set
          total_repaid = total_repaid + v_this,
          instalments_paid = (
            select count(*) from loan_repayment_schedule
            where loan_id = v_loan.id and amount_paid >= scheduled_amount),
          status = case when total_repaid + v_this >= total_repayable + application_fee_charged
                        then 'Closed' else status end,
          closed_at = case when total_repaid + v_this >= total_repayable + application_fee_charged
                           then now() else closed_at end,
          closed_reason = case when total_repaid + v_this >= total_repayable + application_fee_charged
                               then 'Liquidated from savings during withdrawal' else closed_reason end,
          next_payment_due_date = case when total_repaid + v_this >= total_repayable + application_fee_charged
                                       then null else next_payment_due_date end,
          updated_at = now()
        where id = v_loan.id;

        if v_this >= v_remaining then
          update loan_repayment_schedule
          set amount_paid = scheduled_amount, status = 'Paid', paid_at = now()
          where loan_id = v_loan.id and amount_paid < scheduled_amount;
          v_loans_closed := v_loans_closed + 1;
        end if;

        v_loan_repaid_total := v_loan_repaid_total + v_this;
      end;
    end loop;
  end if;

  v_savings_after := get_member_savings_balance(v_request.member_id);

  v_cap := case when v_request.withdrawal_type = 'RETIREMENT'
                then round(v_savings_after * 0.5, 2)
                else v_savings_after end;

  v_gross := least(v_request.requested_amount, v_cap);
  v_charge := round(v_gross * 0.02, 2);
  v_net := v_gross - v_charge;

  if v_gross > 0 then
    insert into ledger_entries (
      member_id, transaction_type, amount, source, status,
      approved_by, allocation_notes
    ) values (
      v_request.member_id, 'WITHDRAWAL', v_gross, 'SYSTEM', 'Approved',
      p_processed_by,
      format('Withdrawal %s processed. Gross ₦%s, charge ₦%s, net ₦%s.',
             v_request.withdrawal_type, v_gross, v_charge, v_net))
    returning id into v_ledger;
  end if;

  update withdrawal_requests set
    status = 'Processed', processed_at = now(),
    liquidation_amount = v_loan_repaid_total,
    actual_payout = v_gross, charge_amount = v_charge, net_amount = v_net,
    ledger_entry_id = v_ledger
  where id = p_request_id;

  -- Status handling: TERMINATION keeps Terminated, FINAL_EXIT sets Exited
  if v_request.withdrawal_type = 'TERMINATION' then
    update members set
      status = 'Terminated',
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_request.member_id
      and status not in ('Terminated','Exited');
  elsif v_request.withdrawal_type = 'FINAL_EXIT' then
    update members set
      status = 'Exited',
      termination_date = coalesce(termination_date, current_date),
      termination_reason = coalesce(termination_reason, 'Final exit (withdrawal processed)'),
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_request.member_id;
  end if;

  perform write_audit('PROCESS_WITHDRAWAL','withdrawal_request',p_request_id,
    jsonb_build_object(
      'savings_before', v_savings_before,
      'loans_outstanding', v_loans_outstanding,
      'loans_closed', v_loans_closed,
      'loan_repaid_total', v_loan_repaid_total,
      'savings_after_liquidation', v_savings_after,
      'cap_applied', v_cap,
      'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net));

  return jsonb_build_object(
    'success', true, 'savings_before', v_savings_before,
    'loans_outstanding', v_loans_outstanding, 'loans_closed', v_loans_closed,
    'loan_repaid_total', v_loan_repaid_total,
    'savings_after_liquidation', v_savings_after, 'cap_applied', v_cap,
    'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net,
    'ledger_entry_id', v_ledger);
end;
$$;

notify pgrst, 'reload schema';