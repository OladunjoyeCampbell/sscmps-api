-- ============================================================
-- Notify the member when a payment is approved
-- ============================================================
-- Previously, approving a payment queued no member notification
-- (except for the EARLY_REPAYMENT case, which is separate). Members
-- only found out via their dashboard. This adds a single summary
-- notification with the savings and loan allocations.
--
-- The RPC keeps all existing behaviour. Only an extra
-- queue_notification call is added at the end, before the return.
-- ============================================================

create or replace function public.approve_payment_with_split(
  p_payment_notification_id uuid,
  p_savings_allocation numeric(12,2),
  p_loan_allocations jsonb default '[]'::jsonb,
  p_match_override_member_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n payment_notifications%rowtype;
  r record;
  v_sum numeric(12,2) := coalesce(p_savings_allocation, 0);
  v_out numeric(12,2);
  v_member uuid;
  v_ledger uuid;
  v_repaid numeric(12,2);
  v_remaining numeric(12,2);
  v_paid numeric(12,2);
  v_inst integer;
  v_early boolean;
  v_loan loans%rowtype;
  v_true_owed numeric(12,2);
  -- for notification
  v_loan_total numeric(12,2) := 0;
  v_loan_count integer := 0;
  v_body text;
begin
  if app_role() <> 'Treasurer' then
    raise exception 'Only Treasurer may approve and allocate payments';
  end if;

  select * into n from payment_notifications
  where id = p_payment_notification_id for update;

  if not found then
    raise exception 'Payment notification not found';
  end if;

  if n.status <> 'Pending' then
    raise exception 'Payment notification is not pending';
  end if;

  v_member := coalesce(p_match_override_member_id, n.member_id);

  if v_member is null then
    update payment_notifications
    set status = 'Unidentified', processed_at = now()
    where id = n.id;

    insert into unidentified_deposits(
      payment_notification_id, amount, transaction_date, bank_reference,
      payment_narration, sender_name, sender_account, source,
      evidence_url, api_response
    ) values (
      n.id, n.amount, n.transaction_date, n.bank_reference,
      n.payment_narration, n.sender_name, n.sender_account, n.source,
      n.evidence_url, n.api_response
    )
    on conflict (payment_notification_id) do nothing;

    perform write_audit(
      'MOVE_TO_UNIDENTIFIED',
      'payment_notification',
      n.id,
      jsonb_build_object('reason', 'No member match')
    );

    return jsonb_build_object('success', true, 'status', 'Unidentified');
  end if;

  if not exists (select 1 from members where id = v_member) then
    raise exception 'Matched member not found';
  end if;

  if (select status from members where id = v_member) <> 'Active' then
    raise exception 'Matched member is not Active';
  end if;

  -- Pre-flight: verify every loan allocation
  for r in
    select * from jsonb_to_recordset(coalesce(p_loan_allocations, '[]'::jsonb))
      x(loan_id uuid, amount numeric(12,2))
  loop
    if r.amount <= 0 then
      raise exception 'Loan allocation must be positive';
    end if;

    select * into v_loan from loans where id = r.loan_id for update;

    if not found
       or v_loan.member_id <> v_member
       or v_loan.status not in ('Active', 'Disbursed') then
      raise exception 'Loan % is not an active loan of the matched member', r.loan_id;
    end if;

    v_true_owed := v_loan.total_repayable + v_loan.application_fee_charged;
    v_out := v_true_owed - v_loan.total_repaid;

    if r.amount > v_out then
      raise exception 'Allocation N% exceeds current outstanding N% for loan %',
        r.amount, v_out, v_loan.loan_reference;
    end if;

    v_sum := v_sum + r.amount;
  end loop;

  if v_sum <> n.amount then
    raise exception 'Allocation total N% must equal payment amount N%', v_sum, n.amount;
  end if;

  update payment_notifications
  set member_id = v_member,
      status = 'Approved',
      approved_by = app_member_id(),
      approved_at = now(),
      processed_at = now()
  where id = n.id;

  -- ── Savings allocation ──────────────────────────────────────
  if p_savings_allocation > 0 then
    insert into ledger_entries(
      member_id, payment_notification_id, transaction_type, amount,
      payment_reference, evidence_url, source, match_confidence,
      status, approved_by, allocation_notes
    ) values (
      v_member, n.id, 'CONTRIBUTION', p_savings_allocation,
      n.payment_reference, n.evidence_url, n.source, n.match_confidence,
      'Approved', app_member_id(), 'Treasurer-approved savings allocation'
    ) returning id into v_ledger;

    insert into payment_allocations(
      payment_notification_id, member_id, destination_type, amount, ledger_entry_id
    ) values (n.id, v_member, 'SAVINGS', p_savings_allocation, v_ledger);

    perform activate_member_after_first_contribution(v_member);
  end if;

  -- ── Loan allocations ────────────────────────────────────────
  for r in
    select * from jsonb_to_recordset(coalesce(p_loan_allocations, '[]'::jsonb))
      x(loan_id uuid, amount numeric(12,2))
  loop
    select * into v_loan from loans where id = r.loan_id for update;

    v_true_owed := v_loan.total_repayable + v_loan.application_fee_charged;
    v_out := v_true_owed - v_loan.total_repaid;

    if r.amount > v_out then
      raise exception 'Concurrent allocation would overpay loan %', v_loan.loan_reference;
    end if;

    insert into ledger_entries(
      member_id, loan_id, payment_notification_id, transaction_type, amount,
      payment_reference, evidence_url, source, match_confidence,
      status, approved_by, allocation_notes
    ) values (
      v_member, r.loan_id, n.id, 'LOAN_REPAYMENT', r.amount,
      n.payment_reference, n.evidence_url, n.source, n.match_confidence,
      'Approved', app_member_id(), 'Treasurer-approved loan repayment allocation'
    ) returning id into v_ledger;

    insert into payment_allocations(
      payment_notification_id, member_id, destination_type, loan_id, amount, ledger_entry_id
    ) values (n.id, v_member, 'LOAN', r.loan_id, r.amount, v_ledger);

    v_repaid := v_loan.total_repaid + r.amount;
    update loans set total_repaid = v_repaid where id = r.loan_id;

    -- Apply payment to earliest unpaid schedule rows
    v_remaining := r.amount;
    for v_inst in
      select instalment_number
      from loan_repayment_schedule
      where loan_id = r.loan_id and amount_paid < scheduled_amount
      order by instalment_number
      for update
    loop
      exit when v_remaining <= 0;

      select scheduled_amount - amount_paid into v_out
      from loan_repayment_schedule
      where loan_id = r.loan_id and instalment_number = v_inst
      for update;

      v_paid := least(v_remaining, v_out);

      update loan_repayment_schedule
      set amount_paid = amount_paid + v_paid,
          status = case when amount_paid + v_paid >= scheduled_amount then 'Paid' else 'Partially Paid' end,
          paid_at = case when amount_paid + v_paid >= scheduled_amount then now() else paid_at end
      where loan_id = r.loan_id and instalment_number = v_inst;

      v_remaining := v_remaining - v_paid;
    end loop;

    -- Close loan if fully repaid
    select * into v_loan from loans where id = r.loan_id;
    v_early := v_repaid >= (v_loan.total_repayable + v_loan.application_fee_charged);

    if v_early then
      update loans
      set status = 'Closed',
          closed_at = now(),
          closed_reason = case
            when (select count(*) from loan_repayment_schedule
                  where loan_id = r.loan_id and status = 'Paid') < term_months
              then 'Closed (Early Repayment)'
              else 'Fully repaid'
          end,
          next_payment_due_date = null
      where id = r.loan_id;

      perform queue_notification(
        v_member, 'EARLY_REPAYMENT', 'Loan closed',
        'Loan ' || v_loan.loan_reference || ' has been fully repaid.',
        jsonb_build_object('loan_id', r.loan_id, 'amount', r.amount)
      );
    else
      update loans
      set instalments_paid = (
            select count(*) from loan_repayment_schedule
            where loan_id = r.loan_id and status = 'Paid'
          ),
          next_payment_due_date = (
            select min(due_date) from loan_repayment_schedule
            where loan_id = r.loan_id and status <> 'Paid'
          )
      where id = r.loan_id;
    end if;

    -- Accumulate for the approval notification
    v_loan_total := v_loan_total + r.amount;
    v_loan_count := v_loan_count + 1;
  end loop;

  -- ── NEW: notify the member of the approval ──────────────────
  -- One summary notification covering both savings and loan amounts.
  -- Skipped if the member is somehow missing (shouldn't happen — the
  -- Active check earlier prevents it).
  if v_member is not null then
    v_body :=
      'Your payment of N' || to_char(n.amount, 'FM999,999,990.00') ||
      coalesce(' (Ref: ' || n.payment_reference || ')', '') ||
      ' has been approved.';

    if p_savings_allocation > 0 then
      v_body := v_body || E'\n' ||
        '  • Savings: N' || to_char(p_savings_allocation, 'FM999,999,990.00');
    end if;

    if v_loan_count > 0 then
      v_body := v_body || E'\n' ||
        '  • Loan repayment: N' || to_char(v_loan_total, 'FM999,999,990.00') ||
        ' across ' || v_loan_count::text || ' loan' ||
        case when v_loan_count = 1 then '' else 's' end;
    end if;

    perform queue_notification(
      v_member,
      'PENDING_QUEUE',
      'Payment approved',
      v_body,
      jsonb_build_object(
        'payment_notification_id', n.id,
        'amount', n.amount,
        'savings_allocation', p_savings_allocation,
        'loan_allocations', p_loan_allocations
      )
    );
  end if;

  perform write_audit(
    'APPROVE_TRANSACTION',
    'payment_notification',
    n.id,
    jsonb_build_object(
      'total_amount', n.amount,
      'savings_allocation', p_savings_allocation,
      'loan_allocations', p_loan_allocations,
      'matched_member', v_member,
      'match_override', p_match_override_member_id is not null
    )
  );

  return jsonb_build_object(
    'success', true,
    'payment_notification_id', n.id,
    'member_id', v_member,
    'amount', n.amount
  );
end;
$$;

grant execute on function public.approve_payment_with_split(uuid, numeric, jsonb, uuid)
  to authenticated;

notify pgrst, 'reload schema';