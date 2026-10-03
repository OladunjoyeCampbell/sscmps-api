-- ============================================================
-- Release a single surety from a Pending loan
-- ============================================================
-- Callable by:
--   • The applicant (to swap out a surety)
--   • The surety themselves (to withdraw consent before committee review)
--   • Committee/Treasurer (administrative)
-- Only allowed while the loan is Pending. Once Approved, sureties are locked.
-- ============================================================
create or replace function public.release_surety(
  p_loan_id uuid,
  p_surety_member_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_loan loans%rowtype;
  v_surety sureties%rowtype;
  v_caller_member_id uuid := app_member_id();
  v_caller_role text := app_role();
begin
  select * into v_loan from loans where id = p_loan_id for update;
  if not found then
    return jsonb_build_object('success', false, 'error', 'Loan not found');
  end if;

  if v_loan.status <> 'Pending' then
    return jsonb_build_object('success', false,
      'error', 'Sureties can only be released while the loan is Pending');
  end if;

  select * into v_surety
  from sureties
  where loan_id = p_loan_id and surety_member_id = p_surety_member_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Surety not found on this loan');
  end if;

  if v_surety.status in ('Declined','Expired','Released') then
    return jsonb_build_object('success', true, 'already_released', true);
  end if;

  if not (
    v_caller_member_id = v_loan.member_id
    or v_caller_member_id = p_surety_member_id
    or v_caller_role in ('LoanCommittee','LoanCommitteeChairman','Treasurer','SystemAdmin')
  ) then
    return jsonb_build_object('success', false,
      'error', 'Not authorised to release this surety');
  end if;

  update sureties
  set status = 'Released', updated_at = now()
  where id = v_surety.id;

  if v_caller_member_id <> p_surety_member_id then
    perform queue_notification(
      p_surety_member_id,
      'SURETY_REQUEST',
      'Surety commitment released',
      format('You are no longer a surety for loan %s. Reason: %s',
        v_loan.loan_reference, coalesce(p_reason, 'Not stated')),
      jsonb_build_object('loan_id', p_loan_id)
    );
  end if;

  perform write_audit(
    'RELEASE_SURETY', 'loan', p_loan_id,
    jsonb_build_object(
      'surety_member_id', p_surety_member_id,
      'previous_status', v_surety.status,
      'reason', p_reason,
      'initiated_by', v_caller_member_id
    )
  );

  return jsonb_build_object('success', true, 'released', true);
end;
$$;

grant execute on function public.release_surety(uuid, uuid, text) to authenticated;

notify pgrst, 'reload schema';