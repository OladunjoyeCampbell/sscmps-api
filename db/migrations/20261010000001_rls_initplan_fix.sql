-- ============================================================
-- RLS InitPlan Performance Fix
-- ============================================================
-- Wraps auth.uid() and auth.role() in (select ...) so the functions
-- are evaluated once per query instead of once per row.
--
-- Behaviour is identical. Only the evaluation timing changes.
-- ============================================================

-- members
drop policy if exists members_self_select on public.members;
create policy members_self_select on public.members
  for select using ((select auth.uid()) = auth_user_id);

drop policy if exists members_management_select on public.members;
create policy members_management_select on public.members
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','LoanCommittee',
                   'ManagementCommittee','SystemAdmin')
  );

drop policy if exists members_self_insert_application on public.members;
create policy members_self_insert_application on public.members
  for insert with check (
    (select auth.uid()) = auth_user_id
    and role = 'Member'
    and status = 'Applicant'
  );

drop policy if exists members_controlled_update on public.members;
create policy members_controlled_update on public.members
  for update using (
    app_role() in ('Treasurer','Secretary','ManagementCommittee','SystemAdmin')
    or (select auth.uid()) = auth_user_id
  )
  with check (
    app_role() in ('Treasurer','Secretary','ManagementCommittee','SystemAdmin')
    or (select auth.uid()) = auth_user_id
  );

-- loans
drop policy if exists loans_member_select on public.loans;
create policy loans_member_select on public.loans
  for select using (app_member_id() = member_id);

drop policy if exists loans_management_select on public.loans;
create policy loans_management_select on public.loans
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','LoanCommittee',
                   'ManagementCommittee','SystemAdmin')
  );

drop policy if exists loans_member_insert on public.loans;
create policy loans_member_insert on public.loans
  for insert with check (app_member_id() = member_id and status = 'Pending');

drop policy if exists loans_committee_update on public.loans;
create policy loans_committee_update on public.loans
  for update using (
    app_role() in ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin')
  );

-- sureties
drop policy if exists sureties_member_select on public.sureties;
create policy sureties_member_select on public.sureties
  for select using (
    app_member_id() = surety_member_id
    or app_member_id() = (select member_id from public.loans where id = loan_id)
  );

drop policy if exists sureties_management_all on public.sureties;
create policy sureties_management_all on public.sureties
  for all using (
    app_role() in ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin')
  );

drop policy if exists sureties_self_consent on public.sureties;
create policy sureties_self_consent on public.sureties
  for update using (app_member_id() = surety_member_id);

-- loan_repayment_schedule
drop policy if exists schedule_member_select on public.loan_repayment_schedule;
create policy schedule_member_select on public.loan_repayment_schedule
  for select using (
    app_member_id() = (select member_id from public.loans where id = loan_id)
  );

drop policy if exists schedule_management_select on public.loan_repayment_schedule;
create policy schedule_management_select on public.loan_repayment_schedule
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','LoanCommittee',
                   'ManagementCommittee','SystemAdmin')
  );

-- ledger_entries
drop policy if exists ledger_member_select on public.ledger_entries;
create policy ledger_member_select on public.ledger_entries
  for select using (app_member_id() = member_id);

drop policy if exists ledger_management_select on public.ledger_entries;
create policy ledger_management_select on public.ledger_entries
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin')
  );

-- notification_queue
drop policy if exists notifications_member_select on public.notification_queue;
create policy notifications_member_select on public.notification_queue
  for select using (app_member_id() = recipient_member_id);

drop policy if exists notifications_management_select on public.notification_queue;
create policy notifications_management_select on public.notification_queue
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','SystemAdmin')
  );

-- contribution_fine_events
drop policy if exists fines_member_select on public.contribution_fine_events;
create policy fines_member_select on public.contribution_fine_events
  for select using (app_member_id() = member_id);

drop policy if exists fines_management_select on public.contribution_fine_events;
create policy fines_management_select on public.contribution_fine_events
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin')
  );

-- withdrawal_requests
drop policy if exists withdrawals_member_select on public.withdrawal_requests;
create policy withdrawals_member_select on public.withdrawal_requests
  for select using (app_member_id() = member_id);

drop policy if exists withdrawals_management_select on public.withdrawal_requests;
create policy withdrawals_management_select on public.withdrawal_requests
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin')
  );

drop policy if exists withdrawals_member_insert on public.withdrawal_requests;
create policy withdrawals_member_insert on public.withdrawal_requests
  for insert with check (
    app_member_id() = member_id and created_by = app_member_id()
  );

drop policy if exists withdrawals_management_update on public.withdrawal_requests;
create policy withdrawals_management_update on public.withdrawal_requests
  for update using (
    app_role() in ('Treasurer','Chairman','Secretary','SystemAdmin')
  );

-- payment_notifications
drop policy if exists payment_queue_treasurer_select on public.payment_notifications;
create policy payment_queue_treasurer_select on public.payment_notifications
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','SystemAdmin')
  );

drop policy if exists payment_queue_member_select_own on public.payment_notifications;
create policy payment_queue_member_select_own on public.payment_notifications
  for select using (app_member_id() = member_id);

drop policy if exists payment_queue_member_insert on public.payment_notifications;
create policy payment_queue_member_insert on public.payment_notifications
  for insert with check (
    source = 'MANUAL' and app_member_id() = member_id and created_by = app_member_id()
  );

drop policy if exists payment_queue_treasurer_update on public.payment_notifications;
create policy payment_queue_treasurer_update on public.payment_notifications
  for update using (
    app_role() in ('Treasurer','SystemAdmin')
  );

-- payment_allocations
drop policy if exists allocations_member_select on public.payment_allocations;
create policy allocations_member_select on public.payment_allocations
  for select using (app_member_id() = member_id);

drop policy if exists allocations_management_select on public.payment_allocations;
create policy allocations_management_select on public.payment_allocations
  for select using (
    app_role() in ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin')
  );

-- member_expulsion_recommendations
drop policy if exists expulsion_recs_committee_select on public.member_expulsion_recommendations;
create policy expulsion_recs_committee_select on public.member_expulsion_recommendations
  for select using (
    app_role() in ('Chairman','Secretary','Treasurer','ManagementCommittee','SystemAdmin')
  );

drop policy if exists expulsion_recs_self_select on public.member_expulsion_recommendations;
create policy expulsion_recs_self_select on public.member_expulsion_recommendations
  for select using (member_id = app_member_id());

-- withdrawal_signoffs
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

notify pgrst, 'reload schema';