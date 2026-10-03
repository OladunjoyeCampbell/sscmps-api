-- ============================================================
-- Withdraw a Pending loan application; release all sureties
-- ============================================================
create or replace function public.withdraw_loan_application(
  p_loan_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_loan loans%rowtype;
  v_caller_member_id uuid := app_member_id();
  v_caller_role text := app_role();
  v_released integer := 0;
  v_surety record;
begin
  select * into v_loan from loans where id = p_loan_id for update;
  if not found then
    return jsonb_build_object('success', false, 'error', 'Loan not found');
  end if;

  if v_loan.status <> 'Pending' then
    return jsonb_build_object(
      'success', false,
      'error', format('Only Pending loans can be withdrawn. Current status: %s.', v_loan.status)
    );
  end if;

  if v_caller_member_id <> v_loan.member_id
     and v_caller_role not in ('LoanCommittee','LoanCommitteeChairman','Treasurer','SystemAdmin') then
    return jsonb_build_object('success', false,
      'error', 'Only the applicant or the Loan Committee may withdraw this application');
  end if;

  -- Capture sureties before update, so we can notify them
  for v_surety in
    select surety_member_id from sureties
    where loan_id = p_loan_id and status in ('Pending','Accepted')
  loop
    perform queue_notification(
      v_surety.surety_member_id,
      'SURETY_REQUEST',
      'Loan application withdrawn',
      format(
        'The loan application you had agreed to guarantee (Ref: %s) has been withdrawn. '
        'You are no longer a surety for this loan.',
        v_loan.loan_reference
      ),
      jsonb_build_object('loan_id', p_loan_id, 'released', true)
    );
  end loop;

  -- Release every attached surety
  update sureties
  set status = 'Released', updated_at = now()
  where loan_id = p_loan_id and status in ('Pending','Accepted');
  get diagnostics v_released = row_count;

  -- Close the loan
  update loans
  set status = 'Closed',
      closed_at = now(),
      closed_reason = coalesce(p_reason, 'Withdrawn by applicant'),
      updated_at = now()
  where id = p_loan_id;

  perform write_audit(
    'WITHDRAW_LOAN_APPLICATION', 'loan', p_loan_id,
    jsonb_build_object('reason', p_reason, 'sureties_released', v_released)
  );

  return jsonb_build_object(
    'success', true,
    'loan_id', p_loan_id,
    'sureties_released', v_released
  );
end;
$$;

grant execute on function public.withdraw_loan_application(uuid, text) to authenticated;

notify pgrst, 'reload schema';