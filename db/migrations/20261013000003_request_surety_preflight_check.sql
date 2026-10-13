-- ============================================================
-- Pre-flight surety capacity check in request_surety()
-- ============================================================
-- Bye-law §51: a member may stand surety for at most two active
-- loans. The actual enforcement is in accept_surety(), which
-- counts live Accepted sureties on non-closed loans.
--
-- This patch adds a pre-flight check to request_surety(), so the
-- borrowing member learns immediately when the proposed surety
-- is already at capacity, instead of sending an invitation that
-- the surety will be forced to decline.
--
-- Legacy sureties recorded only in the paper ledger are not
-- counted. Enforcement begins from system launch.
-- ============================================================

create or replace function public.request_surety(p_loan_id uuid, p_surety_member_id uuid)
returns uuid
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member uuid := app_member_id();
  v_loan loans%rowtype;
  v_count integer;
  v_live_surety_count integer;
  v_id uuid;
begin
  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found'; end if;

  if v_loan.member_id <> v_member then
    raise exception 'Only the borrowing member may request sureties';
  end if;

  if v_loan.status <> 'Pending' then
    raise exception 'Sureties may only be requested for a pending loan application';
  end if;

  if p_surety_member_id = v_member then
    raise exception 'A member cannot be surety for own loan';
  end if;

  if (select status from members where id = p_surety_member_id) <> 'Active' then
    raise exception 'Surety must be an Active member';
  end if;

  -- Per-loan cap (unchanged)
  select count(*) into v_count from sureties
  where loan_id = p_loan_id and status in ('Pending','Accepted');
  if v_count >= 2 then
    raise exception 'A loan may have at most 2 active sureties. Release one before inviting another.';
  end if;

  -- NEW: pre-flight per-member cap (Bye-law §51)
  select count(*) into v_live_surety_count
  from sureties s
  join loans l on l.id = s.loan_id
  where s.surety_member_id = p_surety_member_id
    and s.status = 'Accepted'
    and l.status in ('Approved','Disbursed','Active','Defaulted')
    and l.id <> p_loan_id;

  if v_live_surety_count >= 2 then
    raise exception 'Member is already standing surety for two active loans (Bye-law §51) and cannot be invited for another.';
  end if;

  if exists (select 1 from sureties where loan_id = p_loan_id and surety_member_id = p_surety_member_id) then
    raise exception 'Surety has already been requested';
  end if;

  insert into sureties(loan_id, surety_member_id, status)
  values (p_loan_id, p_surety_member_id, 'Pending')
  returning id into v_id;

  perform write_audit('REQUEST_SURETY','surety',v_id,
    jsonb_build_object('loan_id', p_loan_id, 'surety_member_id', p_surety_member_id));

  perform queue_notification(
    p_surety_member_id,
    'SURETY_REQUEST',
    'Surety consent requested',
    'You have been asked to stand as surety for a cooperative loan. Please review and accept or decline the request.',
    jsonb_build_object('surety_id', v_id, 'loan_id', p_loan_id)
  );

  return v_id;
end;
$$;

grant execute on function public.request_surety(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';