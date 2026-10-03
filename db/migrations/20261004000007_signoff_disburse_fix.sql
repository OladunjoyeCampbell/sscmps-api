-- ============================================================
-- Trustee signoff and disbursement: require EXACTLY the required
-- number of Accepted sureties
-- ============================================================
-- After committee approval, the count is guaranteed to be exactly
-- N (surplus is auto-released by record_committee_decision). Any
-- other count indicates a data integrity problem that should
-- block signoff/disbursement, not be silently allowed.
--
-- This replaces the earlier lenient version (<) with a strict
-- equality check (<>). Since the database has no Approved loans
-- yet, no historical data needs grandfathering.
-- ============================================================

-- ---------- record_loan_trustee_signoff ----------
create or replace function public.record_loan_trustee_signoff(
  p_loan_id uuid,
  p_trustee_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_loan record;
  v_product loan_products%rowtype;
  v_trustee_role text;
  v_slot integer;
  v_accepted_sureties integer;
begin
  select id, status, trustee_signoff_1, trustee_signoff_2, loan_product_id
  into v_loan from public.loans where id = p_loan_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Loan not found');
  end if;

  if v_loan.status <> 'Approved' then
    return jsonb_build_object('success', false,
      'error', 'Loan must be Approved by the Committee first');
  end if;

  select * into v_product from public.loan_products where id = v_loan.loan_product_id;

  -- Strict: exactly N accepted sureties
  if v_product.requires_sureties then
    select count(*) into v_accepted_sureties
    from public.sureties where loan_id = p_loan_id and status = 'Accepted';

    if v_accepted_sureties <> v_product.number_of_sureties_required then
      return jsonb_build_object('success', false,
        'error', format(
          'Loan must have exactly %s Accepted sureties before sign-off (Bye-law §49). Currently %s. Contact the Secretary.',
          v_product.number_of_sureties_required, v_accepted_sureties));
    end if;
  end if;

  select role into v_trustee_role from public.members where id = p_trustee_id;
  if v_trustee_role not in ('Chairman','Secretary','Treasurer') then
    return jsonb_build_object('success', false,
      'error', 'Only Chairman, Secretary, or Treasurer may sign off (Section 27)');
  end if;

  if v_loan.trustee_signoff_1 = p_trustee_id or v_loan.trustee_signoff_2 = p_trustee_id then
    return jsonb_build_object('success', false,
      'error', 'You have already signed off on this loan');
  end if;

  if v_loan.trustee_signoff_1 is null then
    v_slot := 1;
    update public.loans
    set trustee_signoff_1 = p_trustee_id, trustee_signoff_1_at = now(), updated_at = now()
    where id = p_loan_id;
  elsif v_loan.trustee_signoff_2 is null then
    v_slot := 2;
    update public.loans
    set trustee_signoff_2 = p_trustee_id, trustee_signoff_2_at = now(), updated_at = now()
    where id = p_loan_id;
  else
    return jsonb_build_object('success', false,
      'error', 'Both trustee signatures are already recorded');
  end if;

  return jsonb_build_object(
    'success', true,
    'slot', v_slot,
    'trustee_id', p_trustee_id,
    'trustee_role', v_trustee_role
  );
end;
$$;

-- ---------- disburse_loan ----------
create or replace function public.disburse_loan(
  p_loan_id uuid,
  p_recorder_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
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
  if app_role() not in ('Treasurer','SystemAdmin') then
    raise exception 'Only Treasurer/SystemAdmin may execute loan disbursement';
  end if;

  select * into l from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found'; end if;
  if l.status <> 'Approved' then raise exception 'Only approved loans may be disbursed'; end if;

  select * into p from loan_products where id = l.loan_product_id;

  -- Strict: exactly N accepted sureties
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

  v_first_due := (
    date_trunc('month', current_date) + interval '1 month' + interval '9 days'
  )::date;

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
    v_due := (
      date_trunc('month', current_date)
      + (i || ' month')::interval
      + interval '9 days'
    )::date;

    insert into loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount)
    values (
      l.id, i, v_due,
      case
        when i = 1 then v_first_amount
        when i = l.term_months then v_last
        else l.monthly_instalment
      end
    );
  end loop;

  insert into ledger_entries (
    member_id, loan_id, transaction_type, amount, source, status,
    approved_by, approved_at, allocation_notes
  ) values (
    l.member_id, l.id, 'LOAN_DISBURSEMENT', l.principal_amount,
    'SYSTEM', 'Approved', v_recorder, now(),
    'Loan principal disbursed; two-tier interest capitalised; application fee collected with first instalment'
  ) returning id into v_ledger;

  perform write_audit('DISBURSE_LOAN', 'loan', l.id, jsonb_build_object(
    'principal', l.principal_amount,
    'total_repayable', l.total_repayable,
    'monthly_instalment', l.monthly_instalment,
    'first_instalment_amount', v_first_amount,
    'application_fee', v_fee,
    'term_months', l.term_months,
    'first_due_date', v_first_due,
    'signatory_1', v_sign1,
    'signatory_2', v_sign2,
    'recorder', v_recorder,
    'ledger_entry', v_ledger,
    'accepted_sureties', v_accepted_sureties
  ));

  perform queue_notification(
    l.member_id, 'LOAN_DISBURSEMENT', 'Loan disbursed',
    'Your loan has been disbursed. Monthly instalment: N' ||
      to_char(l.monthly_instalment, 'FM999,999,990.00') ||
      ' for ' || l.term_months || ' months. ' ||
      'First payment of N' || to_char(v_first_amount, 'FM999,999,990.00') ||
      ' (includes N' || to_char(v_fee, 'FM999,999,990.00') ||
      ' application fee) is due ' || to_char(v_first_due, 'DD Mon YYYY') || '.',
    jsonb_build_object(
      'loan_id', l.id,
      'monthly_instalment', l.monthly_instalment,
      'first_instalment', v_first_amount,
      'application_fee', v_fee,
      'term_months', l.term_months,
      'first_due_date', v_first_due
    )
  );

  return jsonb_build_object(
    'success', true,
    'loan_id', l.id,
    'total_repayable', l.total_repayable,
    'monthly_instalment', l.monthly_instalment,
    'first_instalment', v_first_amount,
    'first_due_date', v_first_due
  );
end;
$$;

notify pgrst, 'reload schema';