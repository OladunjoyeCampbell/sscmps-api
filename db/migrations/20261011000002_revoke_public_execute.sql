-- ============================================================
-- Revoke EXECUTE from PUBLIC on all public-schema functions
-- ============================================================
-- The previous migration revoked EXECUTE from `anon` specifically,
-- but Postgres grants EXECUTE to PUBLIC by default. `anon` inherits
-- that grant, so the Advisor still flags these functions.
--
-- Revoking from PUBLIC removes the inherited grant for every role
-- that doesn't hold an explicit grant. We then re-grant EXECUTE to
-- the roles that need it:
--   - authenticated  (portal users calling RPC via the REST API)
--   - service_role   (bypasses all grants anyway — no grant needed)
-- ============================================================

-- ---------- 1. Revoke EXECUTE from PUBLIC on every function ----------
do $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select
      p.oid,
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
  loop
    begin
      execute format(
        'revoke all on function %I.%I(%s) from public',
        r.nspname, r.proname, r.args
      );
      v_count := v_count + 1;
    exception when others then
      raise notice 'Skipped %.%(%): %', r.nspname, r.proname, r.args, sqlerrm;
    end;
  end loop;
  raise notice 'Revoked PUBLIC EXECUTE on % function(s)', v_count;
end $$;

-- ---------- 2. Re-grant EXECUTE to authenticated on the API surface ----------
-- These are the functions the portal actually calls. If any is
-- missing from this list, add it — otherwise the corresponding
-- feature will break when the browser calls it via RPC.

-- Balance / calculation helpers
grant execute on function public.get_member_savings_balance(uuid) to authenticated;
grant execute on function public.get_member_total_outstanding_loans(uuid) to authenticated;
grant execute on function public.get_loan_outstanding_balance(uuid) to authenticated;
grant execute on function public.calculate_loan_terms(uuid, uuid, numeric) to authenticated;
grant execute on function public.member_has_min_contributions(uuid, integer) to authenticated;
grant execute on function public.can_request_retirement(uuid) to authenticated;
grant execute on function public.can_request_final_exit(uuid) to authenticated;

-- Auth helpers (called by the Worker on behalf of the user)
grant execute on function public.check_login_lockout(text, integer, integer) to authenticated;
grant execute on function public.record_login_attempt(text, text) to authenticated;
grant execute on function public.clear_login_attempts(text) to authenticated;
grant execute on function public.prune_login_attempts() to authenticated;

-- Member workflows
grant execute on function public.request_contribution_revision(uuid, numeric) to authenticated;
grant execute on function public.update_member_profile(text, text, text, text, text, text, text, text) to authenticated;

-- Payments
grant execute on function public.submit_payment_notification(uuid, numeric, text, text, numeric, jsonb) to authenticated;
grant execute on function public.approve_payment_with_split(uuid, numeric, jsonb, uuid) to authenticated;
grant execute on function public.decline_payment(uuid, text) to authenticated;

-- Loans
grant execute on function public.submit_loan_application(uuid, uuid, numeric, text, text) to authenticated;
grant execute on function public.record_committee_decision(uuid, uuid, text, numeric, numeric, integer, uuid[], text, text) to authenticated;
grant execute on function public.record_loan_trustee_signoff(uuid, uuid) to authenticated;
grant execute on function public.disburse_loan(uuid, uuid) to authenticated;
grant execute on function public.reverse_ledger_entry(uuid, text, uuid) to authenticated;

-- Sureties
grant execute on function public.request_surety(uuid, uuid) to authenticated;
grant execute on function public.accept_surety(uuid) to authenticated;
grant execute on function public.release_surety(uuid, uuid, text) to authenticated;

-- Withdrawals
grant execute on function public.withdraw_loan_application(uuid, text) to authenticated;
grant execute on function public.record_withdrawal_signoff(uuid, uuid) to authenticated;
grant execute on function public.process_withdrawal_with_liquidation(uuid, uuid) to authenticated;
grant execute on function public.expire_stale_surety_requests() to authenticated;
grant execute on function public.send_surety_reminders() to authenticated;

-- Admin / management
grant execute on function public.record_admission_vote(uuid, uuid, text, text) to authenticated;
grant execute on function public.record_factual_termination(uuid, text, date, text, uuid) to authenticated;
grant execute on function public.recommend_member_expulsion(uuid, text, text, uuid) to authenticated;
grant execute on function public.record_expulsion_vote(uuid, date, integer, integer, integer, text, uuid, text) to authenticated;
grant execute on function public.resolve_unidentified_deposit(uuid, uuid, numeric, jsonb) to authenticated;
grant execute on function public.run_compliance_check() to authenticated;
grant execute on function public.flag_missed_contribution(uuid, date, text) to authenticated;

-- Notification / audit
grant execute on function public.queue_notification(uuid, text, text, text, jsonb) to authenticated;
grant execute on function public.write_audit(text, text, uuid, jsonb, uuid) to authenticated;

-- Membership helpers used by RLS policies
grant execute on function public.app_role() to authenticated;
grant execute on function public.app_member_id() to authenticated;
grant execute on function public.is_trustee(uuid) to authenticated;

-- If any function above doesn't exist in your schema, the whole
-- migration will fail. Comment out the missing ones and re-run.
-- Run the verification query below after applying to confirm the
-- grant set is complete.

notify pgrst, 'reload schema';