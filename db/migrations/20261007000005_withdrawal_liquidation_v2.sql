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

  -- Liquidate each loan
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

        -- Single entry that reduces savings AND records the loan payment
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

  -- Recompute savings AFTER liquidation
  v_savings_after := get_member_savings_balance(v_request.member_id);

  -- Type-specific cap
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