-- ============================================================
-- Withdrawal processing with loan liquidation + type-aware caps
-- ============================================================
-- Processing order (atomic):
--   1. Liquidate all outstanding loans from the member's savings
--   2. Compute the post-liquidation savings balance
--   3. Apply type-specific cap:
--        RETIREMENT               -> 50% of post-liquidation savings
--        TERMINATION / FINAL_EXIT -> 100% of post-liquidation savings
--   4. Gross payout = min(requested, cap)
--   5. Charge = 2% of gross payout
--   6. Net to member = gross payout - charge
--   7. Record: LOAN_REPAYMENT entries for each loan, one WITHDRAWAL
--      entry for the gross payout.
-- ============================================================

alter table public.withdrawal_requests
  add column if not exists liquidation_amount numeric(12,2) not null default 0,
  add column if not exists actual_payout numeric(12,2);

comment on column public.withdrawal_requests.liquidation_amount is
  'Amount of savings used to clear outstanding loans at process time.';
comment on column public.withdrawal_requests.actual_payout is
  'Gross payout before the administrative charge (actual_payout - charge_amount = net_amount).';

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
  select * into v_request
  from withdrawal_requests
  where id = p_request_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Request not found');
  end if;

  if v_request.status <> 'Approved' then
    return jsonb_build_object('success', false,
      'error', format('Request is %s; only Approved requests can be processed',
                      v_request.status));
  end if;

  v_savings_before := get_member_savings_balance(v_request.member_id);
  v_loans_outstanding := get_member_total_outstanding_loans(v_request.member_id);

  -- ── Step 1: Liquidate loans from savings ────────────────────
  if v_loans_outstanding > 0 then
    for v_loan in
      select id, loan_reference, total_repayable, total_repaid
      from loans
      where member_id = v_request.member_id
        and status in ('Active','Disbursed','Defaulted')
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
          v_request.member_id, v_loan.id, 'LOAN_REPAYMENT',
          v_this, 'SYSTEM', 'Approved', p_processed_by,
          format('Loan liquidated from savings during withdrawal processing (request %s)',
                 p_request_id)
        );

        update loans set
          total_repaid = total_repaid + v_this,
          instalments_paid = (
            select count(*) from loan_repayment_schedule
            where loan_id = v_loan.id and amount_paid >= scheduled_amount
          ),
          status = case
            when total_repaid + v_this >= total_repayable then 'Closed'
            else status
          end,
          closed_at = case
            when total_repaid + v_this >= total_repayable then now()
            else closed_at
          end,
          closed_reason = case
            when total_repaid + v_this >= total_repayable
              then 'Liquidated from savings during withdrawal'
            else closed_reason
          end,
          next_payment_due_date = case
            when total_repaid + v_this >= total_repayable then null
            else next_payment_due_date
          end,
          updated_at = now()
        where id = v_loan.id;

        if v_this >= v_remaining then
          update loan_repayment_schedule
          set amount_paid = scheduled_amount,
              status = 'Paid',
              paid_at = now()
          where loan_id = v_loan.id
            and amount_paid < scheduled_amount;

          v_loans_closed := v_loans_closed + 1;
        end if;

        v_loan_repaid_total := v_loan_repaid_total + v_this;
      end;
    end loop;
  end if;

  -- ── Step 2: Post-liquidation savings ────────────────────────
  v_savings_after := get_member_savings_balance(v_request.member_id);

  -- ── Step 3: Type-specific cap ───────────────────────────────
  if v_request.withdrawal_type = 'RETIREMENT' then
    v_cap := round(v_savings_after * 0.5, 2);
  else
    v_cap := v_savings_after;  -- TERMINATION / FINAL_EXIT
  end if;

  -- ── Step 4: Gross payout ────────────────────────────────────
  v_gross := least(v_request.requested_amount, v_cap);

  -- ── Step 5: Charge = 2% of gross ────────────────────────────
  v_charge := round(v_gross * 0.02, 2);

  -- ── Step 6: Net to member ───────────────────────────────────
  v_net := v_gross - v_charge;

  -- ── Step 7: Post WITHDRAWAL ledger entry for the GROSS ──────
  if v_gross > 0 then
    insert into ledger_entries (
      member_id, transaction_type, amount, source, status,
      approved_by, allocation_notes
    ) values (
      v_request.member_id, 'WITHDRAWAL', v_gross, 'SYSTEM', 'Approved',
      p_processed_by,
      format('Withdrawal %s processed. Gross ₦%s, charge ₦%s (retained), net paid ₦%s.',
             v_request.withdrawal_type, v_gross, v_charge, v_net)
    )
    returning id into v_ledger;
  end if;

  -- ── Step 8: Update the request ──────────────────────────────
  update withdrawal_requests set
    status = 'Processed',
    processed_at = now(),
    liquidation_amount = v_loan_repaid_total,
    actual_payout = v_gross,
    charge_amount = v_charge,
    net_amount = v_net,
    ledger_entry_id = v_ledger
  where id = p_request_id;

  -- ── Step 9: Audit ───────────────────────────────────────────
  perform write_audit(
    'PROCESS_WITHDRAWAL',
    'withdrawal_request',
    p_request_id,
    jsonb_build_object(
      'savings_before', v_savings_before,
      'loans_outstanding', v_loans_outstanding,
      'loans_closed', v_loans_closed,
      'loan_repaid_total', v_loan_repaid_total,
      'savings_after_liquidation', v_savings_after,
      'requested_amount', v_request.requested_amount,
      'cap_applied', v_cap,
      'gross_payout', v_gross,
      'charge', v_charge,
      'net_to_member', v_net,
      'ledger_entry', v_ledger
    )
  );

  return jsonb_build_object(
    'success', true,
    'savings_before', v_savings_before,
    'loans_outstanding', v_loans_outstanding,
    'loans_closed', v_loans_closed,
    'loan_repaid_total', v_loan_repaid_total,
    'savings_after_liquidation', v_savings_after,
    'requested_amount', v_request.requested_amount,
    'cap_applied', v_cap,
    'gross_payout', v_gross,
    'charge', v_charge,
    'net_to_member', v_net,
    'ledger_entry_id', v_ledger
  );
end;
$$;

grant execute on function public.process_withdrawal_with_liquidation(uuid, uuid)
  to authenticated;

notify pgrst, 'reload schema';