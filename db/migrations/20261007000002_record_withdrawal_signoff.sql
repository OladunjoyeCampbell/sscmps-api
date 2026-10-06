-- ============================================================
-- record_withdrawal_signoff: one trustee signs a withdrawal
-- ============================================================
create or replace function public.record_withdrawal_signoff(
  p_request_id uuid,
  p_trustee_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_request withdrawal_requests%rowtype;
  v_trustee_role text;
  v_count integer;
  v_first uuid;
  v_second uuid;
begin
  select * into v_request
  from withdrawal_requests
  where id = p_request_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'Request not found');
  end if;

  if v_request.status <> 'Pending' then
    return jsonb_build_object('success', false,
      'error', format('Request is %s; only Pending requests can be signed',
                      v_request.status));
  end if;

  select role into v_trustee_role from members where id = p_trustee_id;
  if v_trustee_role not in ('Chairman','Secretary','Treasurer') then
    return jsonb_build_object('success', false,
      'error', 'Only Chairman, Secretary, or Treasurer may sign off');
  end if;

  if exists (
    select 1 from withdrawal_signoffs
    where request_id = p_request_id and trustee_id = p_trustee_id
  ) then
    return jsonb_build_object('success', false,
      'error', 'You have already signed this request');
  end if;

  insert into withdrawal_signoffs (request_id, trustee_id)
  values (p_request_id, p_trustee_id);

  select count(*) into v_count
  from withdrawal_signoffs where request_id = p_request_id;

  if v_count >= 2 then
    select trustee_id into v_first
    from withdrawal_signoffs
    where request_id = p_request_id
    order by signed_at asc, id asc
    limit 1;

    select trustee_id into v_second
    from withdrawal_signoffs
    where request_id = p_request_id
    order by signed_at desc, id desc
    limit 1;

    update withdrawal_requests
    set status = 'Approved',
        approved_at = now(),
        trustee_1 = v_first,
        trustee_2 = v_second
    where id = p_request_id;
  end if;

  perform write_audit(
    'WITHDRAWAL_TRUSTEE_SIGNOFF',
    'withdrawal_request',
    p_request_id,
    jsonb_build_object(
      'trustee_id', p_trustee_id,
      'trustee_role', v_trustee_role,
      'signature_count', v_count,
      'finalised', v_count >= 2
    )
  );

  return jsonb_build_object(
    'success', true,
    'signature_count', v_count,
    'finalised', v_count >= 2
  );
end;
$$;

grant execute on function public.record_withdrawal_signoff(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';