-- ============================================================
-- Fix Supabase Advisor warnings:
--   1. function_search_path_mutable
--   2. anon_security_definer_function_executable
-- ============================================================
-- 1. Set search_path on all flagged functions so SECURITY DEFINER
--    functions cannot be hijacked by search_path manipulation.
-- 2. Revoke EXECUTE from the anon role on every function in the
--    public schema. The anon key is not used for RPC in our
--    architecture — the Worker uses service_role, and the
--    browser talks to the Worker, not directly to Supabase.
-- ============================================================

-- ---------- 1. search_path fixes ----------
-- Uses ALTER FUNCTION ... SET search_path, which changes only
-- that attribute without replacing the function body.

-- login_attempts helpers
alter function public.check_login_lockout(text, integer, integer)
  set search_path = 'public', 'pg_temp';

-- financial year helpers (IMMUTABLE, no table access, but flagged)
alter function public.financial_year_start(date)
  set search_path = 'public', 'pg_temp';

alter function public.financial_year_end(date)
  set search_path = 'public', 'pg_temp';

-- generators
alter function public.generate_payment_reference()
  set search_path = 'public', 'pg_temp';

alter function public.generate_registration_number()
  set search_path = 'public', 'pg_temp';

-- loan term helper
alter function public.derive_loan_term(text, numeric)
  set search_path = 'public', 'pg_temp';

-- trigger functions
alter function public.set_compliance_tracking_from()
  set search_path = 'public', 'pg_temp';

-- validation helper (if it still exists)
do $$
begin
  if exists (
    select 1 from pg_proc
    where proname = 'assert_withdrawal_type_allowed'
      and pronamespace = 'public'::regnamespace
  ) then
    execute 'alter function public.assert_withdrawal_type_allowed(text, text) set search_path = ''public'', ''pg_temp''';
  end if;
end $$;

-- ---------- 2. Revoke EXECUTE from anon on every public function ----------
-- Our Cloudflare Worker uses the service_role key for all RPC calls.
-- The browser never talks to Supabase directly. The anon key is only
-- used for the keep-alive ping (a REST GET on loan_products), which
-- does not go through RPC.
--
-- Revoke is safe and closes the SECURITY DEFINER → anon path.
-- service_role is unaffected (it holds BYPASSRLS and cannot be
-- revoked from via this command).
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
      and p.prokind = 'f'   -- functions only, not procedures
  loop
    begin
      execute format(
        'revoke all on function %I.%I(%s) from anon',
        r.nspname, r.proname, r.args
      );
      v_count := v_count + 1;
    exception when others then
      raise notice 'Skipped %.%(%): %', r.nspname, r.proname, r.args, sqlerrm;
    end;
  end loop;
  raise notice 'Revoked anon EXECUTE on % function(s)', v_count;
end $$;

notify pgrst, 'reload schema';