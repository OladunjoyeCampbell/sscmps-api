-- ============================================================
-- Withdrawal sign-off workflow
-- ============================================================
-- Mirrors the loan trustee sign-off model: each trustee signs
-- individually using their own identity. When the second
-- signature arrives, the request is auto-approved.
-- ============================================================

create table if not exists public.withdrawal_signoffs (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.withdrawal_requests(id) on delete cascade,
  trustee_id uuid not null references public.members(id),
  signed_at timestamptz not null default now(),
  unique (request_id, trustee_id)
);

create index if not exists idx_withdrawal_signoffs_request
  on public.withdrawal_signoffs(request_id);

alter table public.withdrawal_signoffs enable row level security;

drop policy if exists withdrawal_signoffs_select on public.withdrawal_signoffs;
create policy withdrawal_signoffs_select on public.withdrawal_signoffs
for select using (
  app_role() in ('Treasurer','Chairman','Secretary','SystemAdmin')
  or exists (
    select 1 from public.withdrawal_requests wr
    where wr.id = withdrawal_signoffs.request_id
      and wr.member_id = app_member_id()
  )
);

comment on table public.withdrawal_signoffs is
  'Individual trustee signatures on a withdrawal request. Two distinct '
  'trustees are required before the request is approved.';

notify pgrst, 'reload schema';