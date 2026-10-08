-- ============================================================
-- Block withdrawal while an Approved (undisbursed) loan exists
-- ============================================================
-- A member with an Approved-but-not-yet-disbursed loan should not
-- be able to withdraw savings. Once the loan is disbursed, the
-- normal liquidation logic handles it. Until then, the loan is
-- a pending commitment that must be resolved first.
-- ============================================================

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

  -- NEW: refuse if there's an approved loan awaiting disbursement
  select l.loan_reference into v_approved_loan
  from loans l
  where l.member_id = v_request.member_id
    and l.status = 'Approved'
  limit 1;

  if found then
    return jsonb_build_object(
      'success', false,
      'error', format(
        'Member has an approved loan (%s) awaiting disbursement. The loan must be disbursed or cancelled before this withdrawal can be processed.',
        v_approved_loan.loan_reference
      )
    );
  end if;

  v_savings_before := get_member_savings_balance(v_request.member_id);
  v_loans_outstanding := get_member_total_outstanding_loans(v_request.member_id);

  -- Liquidate outstanding loans
  if v_loans_outstanding > 0 then
    for v_loan in
      select id, loan_reference, total_repayable, total_repaid
      from loans
      where member_id = v_request.member_id
        and status in ('Active','Disbursed','Defaulted')
      order by disbursed_at asc nulls last, created_at asc
      for update
    loop
      v_remaining := (v_loan.total_repayable + (select application_fee_charged from loans where id = v_loan.id)) - v_loan.total_repaid;
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
          status = case when total_repaid + v_this >= total_repayable + application_fee_charged then 'Closed' else status end,
          closed_at = case when total_repaid + v_this >= total_repayable + application_fee_charged then now() else closed_at end,
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
             v_request.withdrawal_type, v_gross, v_charge, v_net)
    ) returning id into v_ledger;
  end if;

  update withdrawal_requests set
    status = 'Processed', processed_at = now(),
    liquidation_amount = v_loan_repaid_total,
    actual_payout = v_gross, charge_amount = v_charge, net_amount = v_net,
    ledger_entry_id = v_ledger
  where id = p_request_id;

  -- Status change for FINAL_EXIT and TERMINATION
  if v_request.withdrawal_type in ('FINAL_EXIT', 'TERMINATION') then
    update members set
      status = case when v_request.withdrawal_type = 'FINAL_EXIT' then 'Exited' else 'Terminated' end,
      termination_date = current_date,
      termination_reason = case
        when v_request.withdrawal_type = 'FINAL_EXIT' then 'Final exit (withdrawal processed)'
        else coalesce(v_request.reason, 'Terminated by management')
      end,
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_request.member_id;
  end if;

  perform write_audit('PROCESS_WITHDRAWAL','withdrawal_request', p_request_id,
    jsonb_build_object(
      'savings_before', v_savings_before, 'loans_outstanding', v_loans_outstanding,
      'loans_closed', v_loans_closed, 'loan_repaid_total', v_loan_repaid_total,
      'savings_after_liquidation', v_savings_after, 'cap_applied', v_cap,
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

grant execute on function public.process_withdrawal_with_liquidation(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';