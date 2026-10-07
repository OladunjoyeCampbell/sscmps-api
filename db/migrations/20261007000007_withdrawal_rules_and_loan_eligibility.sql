-- ============================================================
-- Withdrawal rules + zero-savings loan eligibility
-- ============================================================
-- 1. RETIREMENT can only be requested once per member, ever.
-- 2. TERMINATION is management-initiated, not member-initiated.
-- 3. FINAL_EXIT processing sets the member status to Exited.
-- 4. A member with zero savings cannot apply for a new loan.
-- ============================================================

-- ---------- 1. Enforce once-ever retirement at the DB level ----------
create or replace function public.can_request_retirement(p_member_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select not exists (
    select 1 from withdrawal_requests
    where member_id = p_member_id
      and withdrawal_type = 'RETIREMENT'
      and status in ('Pending','Approved','Processed')
  );
$$;

grant execute on function public.can_request_retirement(uuid) to authenticated;

-- ---------- 2. Reject member-initiated TERMINATION in the RPC, if used ----------
-- (The route also blocks it; this is the last line of defence.)
create or replace function public.assert_withdrawal_type_allowed(
  p_withdrawal_type text,
  p_caller_role text
) returns void
language plpgsql
immutable
as $$
begin
  if p_withdrawal_type = 'TERMINATION'
     and p_caller_role not in ('Treasurer','Chairman','Secretary','SystemAdmin') then
    raise exception 'Termination is initiated by the management, not by the member';
  end if;
end;
$$;

-- ---------- 3. Update process_withdrawal_with_liquidation to set Exited on FINAL_EXIT ----------
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

  v_savings_before := get_member_savings_balance(v_request.member_id);
  v_loans_outstanding := get_member_total_outstanding_loans(v_request.member_id);

  if v_loans_outstanding > 0 then
    for v_loan in
      select id, loan_reference, total_repayable, total_repaid
      from loans
      where member_id = v_request.member_id
        and status in ('Active','Disbursed','Defaulted','Approved')
      order by disbursed_at asc nulls last, created_at asc
      for update
    loop
      v_remaining := v_loan.total_repayable - v_loan.total_repaid;
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
                 v_loan.loan_reference, p_request_id)
        );

        update loans set
          total_repaid = total_repaid + v_this,
          instalments_paid = (
            select count(*) from loan_repayment_schedule
            where loan_id = v_loan.id and amount_paid >= scheduled_amount
          ),
          status = case when total_repaid + v_this >= total_repayable then 'Closed' else status end,
          closed_at = case when total_repaid + v_this >= total_repayable then now() else closed_at end,
          closed_reason = case when total_repaid + v_this >= total_repayable
                               then 'Liquidated from savings during withdrawal' else closed_reason end,
          next_payment_due_date = case when total_repaid + v_this >= total_repayable
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
             v_request.withdrawal_type, v_gross, v_charge, v_net)
    ) returning id into v_ledger;
  end if;

  update withdrawal_requests set
    status = 'Processed', processed_at = now(),
    liquidation_amount = v_loan_repaid_total,
    actual_payout = v_gross, charge_amount = v_charge, net_amount = v_net,
    ledger_entry_id = v_ledger
  where id = p_request_id;

  -- FINAL_EXIT flips the member to Exited
  if v_request.withdrawal_type = 'FINAL_EXIT' then
    update members set
      status = 'Exited',
      termination_date = current_date,
      termination_reason = 'Final exit (withdrawal processed)',
      updated_at = now()
    where id = v_request.member_id;
  end if;

  perform write_audit('PROCESS_WITHDRAWAL','withdrawal_request', p_request_id,
    jsonb_build_object(
      'savings_before', v_savings_before, 'loans_outstanding', v_loans_outstanding,
      'loans_closed', v_loans_closed, 'loan_repaid_total', v_loan_repaid_total,
      'savings_after_liquidation', v_savings_after, 'cap_applied', v_cap,
      'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net,
      'final_exit', v_request.withdrawal_type = 'FINAL_EXIT'));

  return jsonb_build_object(
    'success', true, 'savings_before', v_savings_before,
    'loans_outstanding', v_loans_outstanding, 'loans_closed', v_loans_closed,
    'loan_repaid_total', v_loan_repaid_total,
    'savings_after_liquidation', v_savings_after, 'cap_applied', v_cap,
    'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net,
    'ledger_entry_id', v_ledger);
end;
$$;

grant execute on function public.process_withdrawal_with_liquidation(uuid, uuid) to authenticated;

-- ---------- 4. Block loan applications when savings = 0 ----------
create or replace function public.submit_loan_application(
  p_member_id uuid,
  p_loan_product_id uuid,
  p_principal numeric,
  p_purpose text default null::text,
  p_application_notes text default null::text
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_status text;
  v_id uuid;
  v_product loan_products%rowtype;
  v_savings numeric(12,2);
  v_covered numeric(12,2);
  v_surplus numeric(12,2);
  v_i1 numeric(12,2);
  v_i2 numeric(12,2);
  v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
  v_term integer;
begin
  if p_member_id is null then raise exception 'Member ID is required'; end if;

  select status into v_status from members where id = p_member_id;
  if v_status is null then raise exception 'Member not found'; end if;
  if v_status <> 'Active' then
    raise exception 'Only Active members may apply for loans. Current status: %', v_status;
  end if;

  -- New: minimum savings requirement
  v_savings := get_member_savings_balance(p_member_id);
  if v_savings <= 0 then
    raise exception 'You must have a savings balance before you can apply for a loan';
  end if;

  select * into v_product from loan_products
  where id = p_loan_product_id and is_active = true;
  if not found then raise exception 'Loan product not found or inactive'; end if;

  if p_principal <= 0 then raise exception 'Principal must be greater than zero'; end if;

  v_term := public.derive_loan_term(v_product.name, p_principal);

  -- Snapshot
  v_covered := least(p_principal, v_savings);
  v_surplus := greatest(p_principal - v_savings, 0);

  v_i1 := round(v_covered * (v_product.normal_interest_rate / 100), 2);
  v_i2 := round(v_surplus * (v_product.surplus_interest_rate / 100), 2);
  v_total_i := v_i1 + v_i2;
  v_total := p_principal + v_total_i;
  v_monthly := round(v_total / v_term, 2);

  insert into loans(
    member_id, loan_product_id, principal_amount,
    member_savings_at_disbursement,
    covered_principal, surplus_principal,
    normal_interest_applied, surplus_interest_applied, total_interest,
    application_fee_charged, total_repayable, monthly_instalment,
    term_months, application_notes, purpose, status
  ) values (
    p_member_id, p_loan_product_id, p_principal,
    v_savings,
    v_covered, v_surplus,
    v_i1, v_i2, v_total_i,
    v_product.application_fee, v_total, v_monthly,
    v_term, p_application_notes, p_purpose, 'Pending'
  ) returning id into v_id;

  perform write_audit('SUBMIT_LOAN_APPLICATION','loan',v_id,
    jsonb_build_object(
      'principal', p_principal, 'term_months', v_term,
      'savings_snapshot', v_savings,
      'covered_principal', v_covered, 'surplus_principal', v_surplus));

  perform queue_notification(
    p_member_id, 'PENDING_QUEUE',
    'Loan application submitted',
    'Your loan application has been submitted to the Loan Committee for review.',
    jsonb_build_object('loan_id', v_id));

  return v_id;
end;
$$;

notify pgrst, 'reload schema';