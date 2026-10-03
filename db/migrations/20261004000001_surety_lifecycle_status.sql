-- ============================================================
-- Surety lifecycle: add Released status
-- ============================================================
-- Released = the surety is no longer attached to the loan
-- because the loan was withdrawn, rejected, replaced, or the
-- surety themselves changed their mind while the loan is Pending.
-- Distinct from Declined (they said no) and Expired (no response).
-- ============================================================

alter table public.sureties
  drop constraint if exists sureties_status_check;

alter table public.sureties
  add constraint sureties_status_check
  check (status in ('Pending','Accepted','Declined','Expired','Released'));

comment on column public.sureties.status is
  'Pending = invited, awaiting response. Accepted = surety agrees. '
  'Declined = surety refused. Expired = no response within the invite window. '
  'Released = withdrawn by applicant, surety, or committee; or loan withdrawn/rejected.';

notify pgrst, 'reload schema';