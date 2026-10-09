-- ============================================================
-- In-app notification read state
-- ============================================================
-- notification_queue.status tracks EMAIL delivery (Pending/Sent/Failed).
-- This adds a separate axis: whether the member has READ the notification
-- in the app. A notification can be email-sent but unread, or read
-- without the email having gone out.
-- ============================================================

alter table public.notification_queue
  add column if not exists read_at timestamptz;

comment on column public.notification_queue.read_at is
  'When the member opened this notification in the portal. NULL = unread.';

-- Partial index for the fast unread count query.
create index if not exists idx_notifications_unread
  on public.notification_queue(recipient_member_id, created_at desc)
  where read_at is null;

notify pgrst, 'reload schema';