-- ============================================================
-- record_committee_decision fixes:
--   1. Accept >= required sureties (was: exactly = required)
--   2. Pre-approval capacity check for every accepted surety
--   3. On approval, auto-release surplus sureties beyond required
--   4. On rejection, release all attached sureties
-- ============================================================
create or replace function public.record_committee_decision(
  p_loan_id uuid,
  p_recorded_by uuid,
  p_decision text,
  p_amount_approved numeric,
  p_interest_rate numeric,
  p_repayment_months integer,
  p_committee_members_present uuid[],
  p_decision_reason text,
  p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_loan record;
  v_product loan_products%rowtype;
  v_recorder_role text;
  v_decision_id uuid;
  v_member_count integer;
  v_accepted_sureties integer;
  v_savings_snapshot numeric(12,2);
  v_term integer;
  v_covered numeric(12,2);
  v_surplus numeric(12,2);
  v_i1 numeric(12,2);
  v_i2 numeric(12,2);
  v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
  v_surety record;
  v_surety_capacity integer;
  v_kept integer := 0;
begin
  select id, status, loan_product_id, member_savings_at_disbursement
  into v_loan from public.loans where id = p_loan_id;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Loan not found');
  end if;

  if v_loan.status <> 'Pending' then
    return jsonb_build_object('success', false,
      'error', format('Loan status is %s; only Pending loans can be decided', v_loan.status));
  end if;

  select role into v_recorder_role from public.members where id = p_recorded_by;
  if v_recorder_role not in ('LoanCommitteeChairman','SystemAdmin') then
    return jsonb_build_object('success', false,
      'error', 'Only the Loan Committee Chairman may record a decision');
  end if;

  select * into v_product from public.loan_products where id = v_loan.loan_product_id;

  -- Surety requirement: at least N accepted (was: exactly N)
  if v_product.requires_sureties then
    select count(*) into v_accepted_sureties
    from public.sureties where loan_id = p_loan_id and status = 'Accepted';

    if v_accepted_sureties < v_product.number_of_sureties_required then
      return jsonb_build_object('success', false,
        'error', format(
          'At least %s sureties must accept before the committee can decide (Bye-law §49). Currently %s accepted.',
          v_product.number_of_sureties_required, v_accepted_sureties));
    end if;
  end if;

  -- On approval, verify every accepted surety has remaining capacity
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
          'error', format(
            'Surety %s already guarantees 2 active loans and cannot take on this one. Replace them before approving.',
            v_surety.surety_member_id),
          'offending_surety', v_surety.surety_member_id);
      end if;
    end loop;
  end if;

  if p_decision not in ('Approved','Rejected','Deferred') then
    return jsonb_build_object('success', false,
      'error', 'decision must be Approved, Rejected, or Deferred');
  end if;

  if p_committee_members_present is null
     or array_length(p_committee_members_present, 1) < 3 then
    return jsonb_build_object('success', false,
      'error', 'Quorum not met: at least 3 committee members required (Section 33)');
  end if;
  v_member_count := array_length(p_committee_members_present, 1);

  if p_decision = 'Approved' then
    if p_amount_approved is null or p_amount_approved <= 0 then
      return jsonb_build_object('success', false,
        'error', 'amount_approved required for approved loans');
    end if;
    if p_interest_rate is null or p_interest_rate > 10 then
      return jsonb_build_object('success', false,
        'error', 'interest_rate required and must not exceed 10% p.a. (Section 43a)');
    end if;
  end if;

  insert into public.loan_committee_decisions (
    loan_id, decision, decision_reason, notes,
    amount_approved, interest_rate, repayment_months,
    committee_members_present, quorum_met, recorded_by
  ) values (
    p_loan_id, p_decision, p_decision_reason, p_notes,
    p_amount_approved, p_interest_rate,
    case when p_decision = 'Approved'
         then public.derive_loan_term(v_product.name, p_amount_approved)
         else null end,
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
      principal_amount = p_amount_approved,
      covered_principal = v_covered,
      surplus_principal = v_surplus,
      normal_interest_applied = v_i1,
      surplus_interest_applied = v_i2,
      total_interest = v_total_i,
      total_repayable = v_total,
      monthly_instalment = v_monthly,
      term_months = v_term,
      application_fee_charged = v_product.application_fee,
      status = 'Approved',
      approved_at = now(),
      approved_by = p_recorded_by,
      updated_at = now()
    where id = p_loan_id;

    -- Auto-release surplus accepted sureties beyond the required count.
    -- Keep the earliest consenters (first N by consent_given_at).
    if v_product.requires_sureties then
      for v_surety in
        select id, surety_member_id
        from public.sureties
        where loan_id = p_loan_id and status = 'Accepted'
        order by consent_given_at asc nulls last, created_at asc
      loop
        if v_kept < v_product.number_of_sureties_required then
          v_kept := v_kept + 1;
        else
          update public.sureties
          set status = 'Released', updated_at = now()
          where id = v_surety.id;

          perform queue_notification(
            v_surety.surety_member_id,
            'SURETY_REQUEST',
            'Surety commitment released',
            format(
              'Loan %s has been approved with two sureties. Your guarantee is no longer required; '
              'you are not committed to this loan.',
              (select loan_reference from public.loans where id = p_loan_id)
            ),
            jsonb_build_object('loan_id', p_loan_id)
          );
        end if;
      end loop;
    end if;

  elsif p_decision = 'Rejected' then
    -- Release all sureties on rejection
    for v_surety in
      select surety_member_id from public.sureties
      where loan_id = p_loan_id and status in ('Pending','Accepted')
    loop
      perform queue_notification(
        v_surety.surety_member_id,
        'SURETY_REQUEST',
        'Loan application rejected',
        format('Loan %s has been rejected. You are no longer a surety.',
          (select loan_reference from public.loans where id = p_loan_id)),
        jsonb_build_object('loan_id', p_loan_id)
      );
    end loop;

    update public.sureties
    set status = 'Released', updated_at = now()
    where loan_id = p_loan_id and status in ('Pending','Accepted');

    update public.loans set
      status = 'Closed',
      closed_at = now(),
      closed_reason = coalesce(p_decision_reason, 'Rejected by Loan Committee'),
      approved_by = p_recorded_by,
      approved_at = now(),
      updated_at = now()
    where id = p_loan_id;
  end if;

  return jsonb_build_object(
    'success', true,
    'decision_id', v_decision_id,
    'decision', p_decision,
    'quorum_met', true,
    'committee_members_count', v_member_count
  );
end;
$$;

notify pgrst, 'reload schema';