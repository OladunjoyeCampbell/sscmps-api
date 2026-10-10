-- ============================================================
-- Retry: sureties_management_all policy rewrite
-- ============================================================
-- The original migration hit a deadlock on this policy (another
-- process held an AccessShareLock). This re-applies just that
-- policy with a lock timeout so it fails fast rather than
-- deadlocking again.
-- ============================================================

set lock_timeout = '5s';

drop policy if exists sureties_management_all on public.sureties;

create policy sureties_management_all on public.sureties
  for all using (
    app_role() in ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin')
  );

reset lock_timeout;

notify pgrst, 'reload schema';