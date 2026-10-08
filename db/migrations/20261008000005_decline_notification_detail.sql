-- ============================================================
-- Improve the "Payment declined" notification body
-- ============================================================
-- The previous body read simply "Your payment was declined. Reason: X".
-- This version includes the amount and reference so the member can
-- identify exactly which payment was declined.
-- ============================================================

create or replace function public.decline_payment(
  p_payment_notification_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  n payment_notifications%rowtype;
begin
  if app_role() <> 'Treasurer' then
    raise exception 'Only Treasurer may decline payments';
  end if;

  if nullif(trim(p_reason), '') is null then
    raise exception 'Decline reason is required';
  end if;

  select * into n from payment_notifications
  where id = p_payment_notification_id for update;

  if n.status <> 'Pending' then
    raise exception 'Payment is not pending';
  end if;

  update payment_notifications set
    status = 'Declined',
    decline_reason = p_reason,
    approved_by = app_member_id(),
    approved_at = now(),
    processed_at = now()
  where id = n.id;

  if n.member_id is not null then
    perform queue_notification(
      n.member_id,
      'APPROVAL_REJECTION',
      'Payment declined',
      'Your payment of N' || to_char(n.amount, 'FM999,999,990.00') ||
      coalesce(' (Ref: ' || n.payment_reference || ')', '') ||
      ' was declined. Reason: ' || p_reason ||
      '. Please resubmit with the correct details.',
      jsonb_build_object(
        'payment_notification_id', n.id,
        'amount', n.amount,
        'reference', n.payment_reference
      )
    );
  end if;

  perform write_audit(
    'DECLINE_TRANSACTION',
    'payment_notification',
    n.id,
    jsonb_build_object('reason', p_reason, 'amount', n.amount)
  );
end;
$$;

grant execute on function public.decline_payment(uuid, text) to authenticated;

notify pgrst, 'reload schema';