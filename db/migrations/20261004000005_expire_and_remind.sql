-- ============================================================
-- Expire stale surety invitations + send time-based reminders
-- ============================================================
-- Both functions are called by the notification worker cron
-- (every 5 minutes). Idempotent.
-- ============================================================

-- ---------- 5a. Product-aware expiry sweep ----------
create or replace function public.expire_stale_surety_requests()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_count integer;
begin
  update sureties s
  set status = 'Expired', updated_at = now()
  from loans l
  join loan_products lp on lp.id = l.loan_product_id
  where s.loan_id = l.id
    and s.status = 'Pending'
    and l.status = 'Pending'
    and s.created_at < now() - (lp.surety_response_window_hours || ' hours')::interval;

  get diagnostics v_count = row_count;

  if v_count > 0 then
    perform write_audit(
      'EXPIRE_SURETY_INVITATIONS', 'system', null,
      jsonb_build_object('expired_count', v_count)
    );
  end if;

  return v_count;
end;
$$;

grant execute on function public.expire_stale_surety_requests() to authenticated;

-- ---------- 5b. Reminders ----------
-- Reminder checkpoints are hours since invitation. A reminder fires only
-- if the product window is longer than that checkpoint and it hasn't
-- already been sent.
create or replace function public.send_surety_reminders()
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_row record;
  v_count integer := 0;
  v_checkpoints int[] := array[24, 48, 120];
  v_cp int;
  v_hours_remaining numeric;
begin
  for v_row in
    select s.id, s.surety_member_id, s.created_at, s.loan_id,
           l.loan_reference, l.member_id as borrower_id,
           b.first_name as borrower_first, b.last_name as borrower_last,
           lp.surety_response_window_hours
    from sureties s
    join loans l on l.id = s.loan_id
    join loan_products lp on lp.id = l.loan_product_id
    join members b on b.id = l.member_id
    where s.status = 'Pending'
      and l.status = 'Pending'
  loop
    foreach v_cp in array v_checkpoints loop
      if v_row.surety_response_window_hours > v_cp
         and now() - v_row.created_at >= (v_cp || ' hours')::interval
         and now() - v_row.created_at <  ((v_cp + 1) || ' hours')::interval
         and not exists (
           select 1 from notification_queue nq
           where nq.recipient_member_id = v_row.surety_member_id
             and nq.category = 'SURETY_REQUEST'
             and nq.payload->>'surety_id' = v_row.id::text
             and nq.payload->>'reminder_hour' = v_cp::text
         )
      then
        v_hours_remaining := v_row.surety_response_window_hours - v_cp;

        perform queue_notification(
          v_row.surety_member_id,
          'SURETY_REQUEST',
          format('Reminder: surety request for %s %s — %s hours left',
                 v_row.borrower_first, v_row.borrower_last,
                 v_hours_remaining::int),
          format(
            'You were invited to guarantee loan %s for %s %s. '
            'You have about %s hours remaining to respond before the invitation expires. '
            'Please accept or decline from your surety list on the portal.',
            v_row.loan_reference, v_row.borrower_first, v_row.borrower_last,
            v_hours_remaining::int
          ),
          jsonb_build_object(
            'surety_id', v_row.id,
            'loan_id', v_row.loan_id,
            'reminder', true,
            'reminder_hour', v_cp
          )
        );

        v_count := v_count + 1;
      end if;
    end loop;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.send_surety_reminders() to authenticated;

notify pgrst, 'reload schema';