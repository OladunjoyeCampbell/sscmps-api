-- ============================================================
-- Remove SystemAdmin from financial/governance RPCs
-- ============================================================
-- After this migration, the SystemAdmin can:
--   - run migrations, change roles, review audit_log
--   - reset passwords, manage technical infrastructure
-- but cannot:
--   - approve loans, disburse loans, approve withdrawals
--   - admit members, expel members, record committee votes
--   - post fees, reverse ledger entries
--
-- Every function below is functionally identical to before;
-- only the auth-check line has been changed.
-- ============================================================

-- 1. approve_loan: Loan Committee only (drop SystemAdmin)
create or replace function public.approve_loan(
  p_loan_id uuid,
  p_override_credit_limit boolean default false,
  p_override_reason text default null
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE l loans%ROWTYPE; v_role text:=app_role();
BEGIN
  IF v_role NOT IN ('LoanCommittee','LoanCommitteeChairman') THEN RAISE EXCEPTION 'Only Loan Committee may approve loans'; END IF;
  SELECT * INTO l FROM loans WHERE id=p_loan_id FOR UPDATE;
  IF l.status <> 'Pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;
  IF p_override_credit_limit THEN
    UPDATE loans SET override_credit_limit=true, override_reason=p_override_reason,
      override_by=app_member_id(), override_at=now() WHERE id=p_loan_id;
  END IF;
  PERFORM validate_loan_application(p_loan_id);
  UPDATE loans SET status='Approved', approved_at=now(), approved_by=app_member_id() WHERE id=p_loan_id;
  PERFORM write_audit('APPROVE_LOAN','loan',p_loan_id,jsonb_build_object('override',p_override_credit_limit));
  PERFORM queue_notification(l.member_id,'APPROVAL_REJECTION','Loan application approved','Your loan application has been approved and is awaiting disbursement.');
  RETURN jsonb_build_object('success',true,'loan_id',p_loan_id);
END;
$$;
grant execute on function public.approve_loan(uuid, boolean, text) to authenticated;

-- 2. approve_withdrawal: Treasurer/Chairman/Secretary only (drop SystemAdmin)
create or replace function public.approve_withdrawal(
  p_request_id uuid, p_trustee_1 uuid, p_trustee_2 uuid, p_recorder_id uuid
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE w withdrawal_requests%ROWTYPE; v_balance numeric(12,2); v_charge numeric(12,2); v_net numeric(12,2);
BEGIN
  IF app_role() NOT IN ('Treasurer','Chairman','Secretary') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  SELECT * INTO w FROM withdrawal_requests WHERE id=p_request_id FOR UPDATE;
  IF w.status<>'Pending' THEN RAISE EXCEPTION 'Withdrawal is not pending'; END IF;
  IF p_trustee_1 IS NULL OR p_trustee_2 IS NULL OR p_trustee_1=p_trustee_2 THEN RAISE EXCEPTION 'Two different trustees are required'; END IF;
  IF NOT is_trustee(p_trustee_1) OR NOT is_trustee(p_trustee_2) THEN RAISE EXCEPTION 'Signatories must be trustees'; END IF;
  IF p_recorder_id IS NULL OR NOT EXISTS (SELECT 1 FROM members WHERE id=p_recorder_id) THEN RAISE EXCEPTION 'A valid recorder is required'; END IF;
  IF p_recorder_id=p_trustee_1 OR p_recorder_id=p_trustee_2 THEN RAISE EXCEPTION 'Recorder cannot be a signatory'; END IF;
  v_balance:=get_member_savings_balance(w.member_id);
  IF w.requested_amount>v_balance THEN RAISE EXCEPTION 'Withdrawal exceeds available savings balance'; END IF;
  IF w.withdrawal_type='RETIREMENT' THEN
    IF (SELECT status FROM members WHERE id=w.member_id) NOT IN ('Terminated','Exited') THEN RAISE EXCEPTION 'Retirement withdrawal requires termination/exit status'; END IF;
    IF (SELECT termination_date FROM members WHERE id=w.member_id) IS NULL OR current_date > (SELECT termination_date FROM members WHERE id=w.member_id)+interval '3 months' THEN
      RAISE EXCEPTION 'Retirement partial withdrawal must be within 3 months of retirement';
    END IF;
    IF w.requested_amount>v_balance*0.50 THEN RAISE EXCEPTION 'Retirement withdrawal may not exceed 50%% of savings'; END IF;
    v_charge:=round(w.requested_amount*0.02,2);
  ELSE
    v_charge:=0;
  END IF;
  v_net:=w.requested_amount-v_charge;
  IF v_net<=0 THEN RAISE EXCEPTION 'Net withdrawal must be positive'; END IF;
  UPDATE withdrawal_requests SET trustee_1=p_trustee_1,trustee_2=p_trustee_2,recorder_id=p_recorder_id,
    charge_amount=v_charge,net_amount=v_net,status='Approved',approved_at=now() WHERE id=w.id;
  PERFORM write_audit('APPROVE_WITHDRAWAL','withdrawal_request',w.id,jsonb_build_object('amount',w.requested_amount,'charge',v_charge));
  RETURN jsonb_build_object('success',true,'gross_amount',w.requested_amount,'charge',v_charge,'net_amount',v_net);
END;
$$;
grant execute on function public.approve_withdrawal(uuid, uuid, uuid, uuid) to authenticated;

-- 3. disburse_loan: Treasurer only (drop SystemAdmin)
create or replace function public.disburse_loan(
  p_loan_id uuid, p_recorder_id uuid default null
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  l loans%rowtype;
  p loan_products%rowtype;
  v_recorder uuid := coalesce(p_recorder_id, app_member_id());
  v_sign1 uuid;
  v_sign2 uuid;
  i integer;
  v_due date;
  v_first_due date;
  v_last numeric(12,2);
  v_first_amount numeric(12,2);
  v_ledger uuid;
  v_fee numeric(12,2);
  v_accepted_sureties integer;
begin
  if app_role() <> 'Treasurer' then
    raise exception 'Only Treasurer may execute loan disbursement';
  end if;

  select * into l from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found'; end if;
  if l.status <> 'Approved' then raise exception 'Only approved loans may be disbursed'; end if;

  select * into p from loan_products where id = l.loan_product_id;

  if p.requires_sureties then
    select count(*) into v_accepted_sureties
    from sureties where loan_id = l.id and status = 'Accepted';
    if v_accepted_sureties <> p.number_of_sureties_required then
      raise exception 'Loan must have exactly % Accepted sureties; found %',
        p.number_of_sureties_required, v_accepted_sureties;
    end if;
  end if;

  v_sign1 := l.trustee_signoff_1;
  v_sign2 := l.trustee_signoff_2;
  if v_sign1 is null or v_sign2 is null or v_sign1 = v_sign2 then
    raise exception 'Two different trustee sign-offs are required';
  end if;
  if not is_trustee(v_sign1) or not is_trustee(v_sign2) then
    raise exception 'Signatories must be Chairman, Secretary or Treasurer';
  end if;
  if v_recorder is null then raise exception 'Recorder is required'; end if;
  if not exists (select 1 from members where id = v_recorder) then
    raise exception 'Recorder must be a valid member';
  end if;

  perform 1 from members where id = l.member_id for update;

  v_first_due := (date_trunc('month', current_date) + interval '1 month' + interval '9 days')::date;

  update loans set
    next_payment_due_date = v_first_due,
    status = 'Active',
    recorder_id = v_recorder,
    disbursed_by = v_recorder,
    disbursed_at = now(),
    updated_at = now()
  where id = l.id;

  v_fee := l.application_fee_charged;
  v_first_amount := l.monthly_instalment + v_fee;
  v_last := round(l.total_repayable - l.monthly_instalment * (l.term_months - 1), 2);

  for i in 1..l.term_months loop
    v_due := (date_trunc('month', current_date) + (i || ' month')::interval + interval '9 days')::date;
    insert into loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount)
    values (l.id, i, v_due,
      case when i = 1 then v_first_amount
           when i = l.term_months then v_last
           else l.monthly_instalment end);
  end loop;

  insert into ledger_entries (member_id, loan_id, transaction_type, amount, source, status,
    approved_by, approved_at, allocation_notes)
  values (l.member_id, l.id, 'LOAN_DISBURSEMENT', l.principal_amount,
    'SYSTEM', 'Approved', v_recorder, now(),
    'Loan principal disbursed; two-tier interest capitalised; application fee collected with first instalment')
  returning id into v_ledger;

  perform write_audit('DISBURSE_LOAN', 'loan', l.id, jsonb_build_object(
    'principal', l.principal_amount, 'total_repayable', l.total_repayable,
    'monthly_instalment', l.monthly_instalment,
    'first_instalment_amount', v_first_amount, 'application_fee', v_fee,
    'term_months', l.term_months, 'first_due_date', v_first_due,
    'signatory_1', v_sign1, 'signatory_2', v_sign2, 'recorder', v_recorder,
    'ledger_entry', v_ledger, 'accepted_sureties', v_accepted_sureties));

  perform queue_notification(
    l.member_id, 'LOAN_DISBURSEMENT', 'Loan disbursed',
    'Your loan has been disbursed. Monthly instalment: N' || to_char(l.monthly_instalment, 'FM999,999,990.00') ||
      ' for ' || l.term_months || ' months. First payment of N' || to_char(v_first_amount, 'FM999,999,990.00') ||
      ' (includes N' || to_char(v_fee, 'FM999,999,990.00') || ' application fee) is due ' ||
      to_char(v_first_due, 'DD Mon YYYY') || '.',
    jsonb_build_object('loan_id', l.id, 'monthly_instalment', l.monthly_instalment,
      'first_instalment', v_first_amount, 'application_fee', v_fee,
      'term_months', l.term_months, 'first_due_date', v_first_due));

  return jsonb_build_object('success', true, 'loan_id', l.id,
    'total_repayable', l.total_repayable, 'monthly_instalment', l.monthly_instalment,
    'first_instalment', v_first_amount, 'first_due_date', v_first_due);
end;
$$;
grant execute on function public.disburse_loan(uuid, uuid) to authenticated;

-- 4. record_committee_decision: Loan Committee Chairman only (drop SystemAdmin)
-- The body is unchanged from the original; only the auth check differs.
-- See the schema dump for the full body; substitute the block below.
create or replace function public.record_committee_decision(
  p_loan_id uuid, p_recorded_by uuid, p_decision text,
  p_amount_approved numeric, p_interest_rate numeric, p_repayment_months integer,
  p_committee_members_present uuid[], p_decision_reason text, p_notes text
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_loan record; v_product loan_products%rowtype;
  v_recorder_role text; v_decision_id uuid; v_member_count integer;
  v_accepted_sureties integer; v_savings_snapshot numeric(12,2);
  v_term integer; v_covered numeric(12,2); v_surplus numeric(12,2);
  v_i1 numeric(12,2); v_i2 numeric(12,2); v_total_i numeric(12,2);
  v_total numeric(12,2); v_monthly numeric(12,2);
  v_surety record; v_surety_capacity integer; v_kept integer := 0;
begin
  select id, status, loan_product_id, member_savings_at_disbursement
  into v_loan from public.loans where id = p_loan_id;
  if not found then return jsonb_build_object('success', false, 'error', 'Loan not found'); end if;
  if v_loan.status <> 'Pending' then
    return jsonb_build_object('success', false,
      'error', format('Loan status is %s; only Pending loans can be decided', v_loan.status));
  end if;
  select role into v_recorder_role from public.members where id = p_recorded_by;
  if v_recorder_role <> 'LoanCommitteeChairman' then
    return jsonb_build_object('success', false,
      'error', 'Only the Loan Committee Chairman may record a decision');
  end if;
  select * into v_product from public.loan_products where id = v_loan.loan_product_id;
  if v_product.requires_sureties then
    select count(*) into v_accepted_sureties
    from public.sureties where loan_id = p_loan_id and status = 'Accepted';
    if v_accepted_sureties < v_product.number_of_sureties_required then
      return jsonb_build_object('success', false,
        'error', format('At least %s sureties must accept before the committee can decide (Bye-law §49). Currently %s accepted.',
          v_product.number_of_sureties_required, v_accepted_sureties));
    end if;
  end if;
  if p_decision = 'Approved' then
    for v_surety in
      select surety_member_id from public.sureties
      where loan_id = p_loan_id and status = 'Accepted'
    loop
      select count(*) into v_surety_capacity
      from public.sureties ss
      join public.loans l on l.id = ss.loan_id
      where ss.surety_member_id = v_surety.surety_member_id
        and ss.status = 'Accepted'
        and l.status in ('Approved','Disbursed','Active','Defaulted')
        and l.id <> p_loan_id;
      if v_surety_capacity >= 2 then
        return jsonb_build_object('success', false,
          'error', format('Surety %s already guarantees 2 active loans and cannot take on this one. Replace them before approving.', v_surety.surety_member_id),
          'offending_surety', v_surety.surety_member_id);
      end if;
    end loop;
  end if;
  if p_decision not in ('Approved','Rejected','Deferred') then
    return jsonb_build_object('success', false, 'error', 'decision must be Approved, Rejected, or Deferred');
  end if;
  if p_committee_members_present is null or array_length(p_committee_members_present, 1) < 3 then
    return jsonb_build_object('success', false, 'error', 'Quorum not met: at least 3 committee members required (Section 33)');
  end if;
  v_member_count := array_length(p_committee_members_present, 1);
  if p_decision = 'Approved' then
    if p_amount_approved is null or p_amount_approved <= 0 then
      return jsonb_build_object('success', false, 'error', 'amount_approved required for approved loans');
    end if;
    if p_interest_rate is null or p_interest_rate > 10 then
      return jsonb_build_object('success', false, 'error', 'interest_rate required and must not exceed 10% p.a. (Section 43a)');
    end if;
  end if;
  insert into public.loan_committee_decisions (
    loan_id, decision, decision_reason, notes, amount_approved, interest_rate,
    repayment_months, committee_members_present, quorum_met, recorded_by
  ) values (
    p_loan_id, p_decision, p_decision_reason, p_notes, p_amount_approved, p_interest_rate,
    case when p_decision = 'Approved' then public.derive_loan_term(v_product.name, p_amount_approved) else null end,
    p_committee_members_present, true, p_recorded_by
  ) returning id into v_decision_id;
  if p_decision = 'Approved' then
    v_savings_snapshot := v_loan.member_savings_at_disbursement;
    v_term := public.derive_loan_term(v_product.name, p_amount_approved);
    v_covered := least(p_amount_approved, v_savings_snapshot);
    v_surplus := greatest(p_amount_approved - v_savings_snapshot, 0);
    v_i1 := round(v_covered * (p_interest_rate / 100), 2);
    v_i2 := round(v_surplus * (v_product.surplus_interest_rate / 100), 2);
    v_total_i := v_i1 + v_i2;
    v_total := p_amount_approved + v_total_i;
    v_monthly := round(v_total / v_term, 2);
    update public.loans set
      principal_amount = p_amount_approved, covered_principal = v_covered,
      surplus_principal = v_surplus, normal_interest_applied = v_i1,
      surplus_interest_applied = v_i2, total_interest = v_total_i,
      total_repayable = v_total, monthly_instalment = v_monthly,
      term_months = v_term, application_fee_charged = v_product.application_fee,
      status = 'Approved', approved_at = now(), approved_by = p_recorded_by, updated_at = now()
    where id = p_loan_id;
    if v_product.requires_sureties then
      for v_surety in
        select id, surety_member_id from public.sureties
        where loan_id = p_loan_id and status = 'Accepted'
        order by consent_given_at asc nulls last, created_at asc
      loop
        if v_kept < v_product.number_of_sureties_required then
          v_kept := v_kept + 1;
        else
          update public.sureties set status = 'Released', updated_at = now() where id = v_surety.id;
          perform queue_notification(v_surety.surety_member_id, 'SURETY_REQUEST',
            'Surety commitment released',
            format('Loan %s has been approved with two sureties. Your guarantee is no longer required; you are not committed to this loan.',
              (select loan_reference from public.loans where id = p_loan_id)),
            jsonb_build_object('loan_id', p_loan_id));
        end if;
      end loop;
    end if;
  elsif p_decision = 'Rejected' then
    for v_surety in
      select surety_member_id from public.sureties
      where loan_id = p_loan_id and status in ('Pending','Accepted')
    loop
      perform queue_notification(v_surety.surety_member_id, 'SURETY_REQUEST',
        'Loan application rejected',
        format('Loan %s has been rejected. You are no longer a surety.',
          (select loan_reference from public.loans where id = p_loan_id)),
        jsonb_build_object('loan_id', p_loan_id));
    end loop;
    update public.sureties set status = 'Released', updated_at = now()
    where loan_id = p_loan_id and status in ('Pending','Accepted');
    update public.loans set
      status = 'Closed', closed_at = now(),
      closed_reason = coalesce(p_decision_reason, 'Rejected by Loan Committee'),
      approved_by = p_recorded_by, approved_at = now(), updated_at = now()
    where id = p_loan_id;
  end if;
  return jsonb_build_object('success', true, 'decision_id', v_decision_id,
    'decision', p_decision, 'quorum_met', true, 'committee_members_count', v_member_count);
end;
$$;
grant execute on function public.record_committee_decision(uuid, uuid, text, numeric, numeric, integer, uuid[], text, text) to authenticated;

-- 5. decide_member_application: Management Committee officers only (drop SystemAdmin)
create or replace function public.decide_member_application(
  p_member_id uuid, p_approve boolean, p_rejection_reason text default null
) returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE v_role text := app_role();
BEGIN
  IF v_role NOT IN ('ManagementCommittee','Chairman','Secretary','Treasurer') THEN
    RAISE EXCEPTION 'Only Management Committee members may decide membership applications';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM members WHERE id=p_member_id AND status='Applicant') THEN
    RAISE EXCEPTION 'Applicant not found or already decided';
  END IF;
  IF NOT p_approve AND NULLIF(trim(p_rejection_reason),'') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;
  UPDATE members SET
    status = CASE WHEN p_approve THEN 'Applicant' ELSE 'Exited' END,
    admission_decision_at=now(), admission_decision_by=app_member_id(),
    admission_rejection_reason=CASE WHEN p_approve THEN NULL ELSE p_rejection_reason END
  WHERE id=p_member_id;
  PERFORM write_audit(CASE WHEN p_approve THEN 'APPROVE_MEMBER' ELSE 'REJECT_MEMBER' END,
    'member',p_member_id,jsonb_build_object('reason',p_rejection_reason));
  PERFORM queue_notification(p_member_id,'APPROVAL_REJECTION',
    CASE WHEN p_approve THEN 'Membership application approved' ELSE 'Membership application rejected' END,
    CASE WHEN p_approve THEN 'Your membership application has been approved. Your membership becomes Active after your first contribution.'
         ELSE 'Your membership application was rejected. Reason: '||p_rejection_reason END);
  RETURN jsonb_build_object('success',true,'approved',p_approve);
END;
$$;
grant execute on function public.decide_member_application(uuid, boolean, text) to authenticated;

-- 6. post_non_loan_fee: Treasurer only
create or replace function public.post_non_loan_fee(
  p_member_id uuid, p_transaction_type text, p_amount numeric,
  p_reference text default null, p_notes text default null
) returns uuid
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE v_id uuid;
BEGIN
  IF app_role() <> 'Treasurer' THEN RAISE EXCEPTION 'Only Treasurer may post non-loan fees'; END IF;
  IF p_transaction_type NOT IN ('ENTRANCE_FEE','LOAN_FORM_SALE') THEN RAISE EXCEPTION 'Invalid non-loan transaction type'; END IF;
  IF p_amount<=0 THEN RAISE EXCEPTION 'Fee amount must be greater than zero'; END IF;
  IF NOT EXISTS(SELECT 1 FROM members WHERE id=p_member_id) THEN RAISE EXCEPTION 'Member not found'; END IF;
  INSERT INTO ledger_entries(member_id,transaction_type,amount,payment_reference,source,status,approved_by,allocation_notes)
  VALUES(p_member_id,p_transaction_type,p_amount,p_reference,'MANUAL','Approved',app_member_id(),p_notes)
  RETURNING id INTO v_id;
  PERFORM write_audit('POST_NON_LOAN_FEE','ledger_entry',v_id,jsonb_build_object('member_id',p_member_id,'transaction_type',p_transaction_type,'amount',p_amount));
  RETURN v_id;
END;
$$;
grant execute on function public.post_non_loan_fee(uuid, text, numeric, text, text) to authenticated;

-- 7. reverse_ledger_entry: Treasurer/Chairman/Secretary only (drop SystemAdmin, both checks)
create or replace function public.reverse_ledger_entry(
  p_ledger_entry_id uuid, p_reason text, p_second_approver uuid
) returns uuid
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE e ledger_entries%ROWTYPE; v_id uuid; v_actor uuid:=app_member_id(); v_actor_role text:=app_role();
BEGIN
  IF v_actor_role NOT IN ('Treasurer','Chairman','Secretary') THEN RAISE EXCEPTION 'Not authorised to reverse transactions'; END IF;
  IF NULLIF(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Reversal reason is required'; END IF;
  IF p_second_approver IS NULL OR p_second_approver=v_actor THEN RAISE EXCEPTION 'A different second approver is required'; END IF;
  IF NOT is_trustee(p_second_approver) THEN RAISE EXCEPTION 'Second approver must be a trustee'; END IF;
  SELECT * INTO e FROM ledger_entries WHERE id=p_ledger_entry_id AND status='Approved' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Approved ledger entry not found'; END IF;
  IF e.transaction_type='REVERSAL' THEN RAISE EXCEPTION 'A reversal cannot itself be reversed'; END IF;
  IF EXISTS(SELECT 1 FROM ledger_entries WHERE parent_ledger_entry_id=e.id AND transaction_type='REVERSAL' AND status='Approved') THEN
    RAISE EXCEPTION 'Ledger entry has already been reversed';
  END IF;
  INSERT INTO ledger_entries(member_id,loan_id,transaction_type,amount,source,status,approved_by,approved_at,parent_ledger_entry_id,reversal_reason,reversal_approved_by,allocation_notes)
  VALUES(e.member_id,e.loan_id,'REVERSAL',e.amount,'SYSTEM','Approved',v_actor,now(),e.id,p_reason,p_second_approver,'Approved reversal; original entry remains immutable')
  RETURNING id INTO v_id;
  IF e.transaction_type='LOAN_DISBURSEMENT' THEN
    RAISE EXCEPTION 'Loan disbursement reversal is not supported; use a controlled loan correction workflow';
  ELSIF e.transaction_type='LOAN_REPAYMENT' THEN
    DECLARE v_remaining numeric(12,2); v_sched record; v_reduce numeric(12,2);
    BEGIN
      UPDATE loans SET total_repaid=total_repaid-e.amount,
        status=CASE WHEN status='Closed' THEN 'Active' ELSE status END,
        closed_at=CASE WHEN status='Closed' THEN NULL ELSE closed_at END,
        closed_reason=CASE WHEN status='Closed' THEN NULL ELSE closed_reason END
      WHERE id=e.loan_id AND total_repaid>=e.amount;
      IF NOT FOUND THEN RAISE EXCEPTION 'Loan repayment reversal would make total repaid negative'; END IF;
      v_remaining:=e.amount;
      FOR v_sched IN SELECT id,amount_paid FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND amount_paid>0 ORDER BY instalment_number DESC FOR UPDATE LOOP
        EXIT WHEN v_remaining<=0;
        v_reduce:=LEAST(v_remaining,v_sched.amount_paid);
        UPDATE loan_repayment_schedule SET amount_paid=amount_paid-v_reduce,
          status=CASE WHEN amount_paid-v_reduce<=0 THEN 'Pending' ELSE 'Partially Paid' END,
          paid_at=CASE WHEN amount_paid-v_reduce<=0 THEN NULL ELSE paid_at END
        WHERE id=v_sched.id;
        v_remaining:=v_remaining-v_reduce;
      END LOOP;
    END;
    UPDATE loans SET instalments_paid=(SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND status='Paid'),
      next_payment_due_date=(SELECT min(due_date) FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND amount_paid<scheduled_amount)
    WHERE id=e.loan_id;
  END IF;
  PERFORM write_audit('REVERSE_TRANSACTION','ledger_entry',e.id,jsonb_build_object('reversal_id',v_id,'reason',p_reason,'second_approver',p_second_approver));
  RETURN v_id;
END;
$$;
grant execute on function public.reverse_ledger_entry(uuid, text, uuid) to authenticated;

notify pgrst, 'reload schema';