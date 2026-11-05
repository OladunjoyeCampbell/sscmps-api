-- 20261104000001_audit_ip_user_agent.sql
--
-- Purpose:
--   1. Add p_ip / p_user_agent parameters to write_audit() so existing
--      Node-level callers that already pass these parameters no longer
--      fail silently. (loans.js audit() helper and similar.)
--   2. Read client IP / User-Agent from PostgREST's request.headers GUC
--      so those fields are populated on every audit row, whether the
--      write_audit call originates from Node or from inside another
--      SECURITY DEFINER RPC.
--   3. Preserve the public-execute revoked posture of the previous
--      write_audit (per 20261011000002_revoke_public_execute.sql). The
--      default grant on any newly-created Postgres function is EXECUTE
--      to PUBLIC, so REVOKE is required explicitly.
--   4. Grant ingest_api_credit to authenticated so the Treasurer-triggered
--      /treasury/ingest-api-credit route keeps working after the Worker
--      swaps its RPC path from the service-role client to the user-JWT
--      client (req.supabase).
--
-- Application:
--   psql $env:SUPABASE_DB_URL --single-transaction -f db/migrations/20261104000001_audit_ip_user_agent.sql
--
-- Pre-flight confirmed 2026-11-04:
--   * write_audit grants before migration: authenticated, postgres, service_role
--   * write_audit owner: postgres, SECURITY DEFINER: true
--
-- Form chosen: ALTER ... RENAME instead of DROP ... IF EXISTS, so that a
-- signature typo in the identity-arguments list fails loudly instead of
-- silently creating a second overload.
--
-- Inet cast fix (2026-11-05):
--   audit_log.ip_address is type inet, not text. The initial version of
--   this migration inserted a text variable directly and every financial
--   RPC failed with:
--     column "ip_address" is of type inet but expression is of type text
--   The body below now explicitly casts via ::inet with an exception guard
--   so malformed client IPs (proxied garbage, IPv6-form edge cases) fall
--   through to NULL rather than failing the whole transaction. Any database
--   that already applied the buggy version needs
--   20261104000002_fix_audit_inet_cast.sql to pick up the corrected body.
--
-- Post-apply verification:
--   (a) psql $env:SUPABASE_DB_URL -c "select proname, pronargs, proowner::regrole from pg_proc where proname like 'write_audit%';"
--       Expected: single row write_audit | 8 | postgres
--   (b) psql $env:SUPABASE_DB_URL -c "select grantee from information_schema.routine_privileges where routine_schema='public' and routine_name='write_audit' order by grantee;"
--       Expected: authenticated, postgres, service_role  (NO PUBLIC)
--   (c) psql $env:SUPABASE_DB_URL -c "select grantee from information_schema.routine_privileges where routine_schema='public' and routine_name='ingest_api_credit' order by grantee;"
--       Expected: authenticated, postgres, service_role  (NO PUBLIC)

-- ---------------------------------------------------------------------
-- 1. Park the current function under a temporary name (hard error if absent)
-- ---------------------------------------------------------------------
ALTER FUNCTION public.write_audit(text, text, uuid, jsonb, uuid)
  RENAME TO write_audit_v0;

-- ---------------------------------------------------------------------
-- 2. Create the new version under the original name
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.write_audit(
  p_action        text,
  p_resource_type text  DEFAULT NULL,
  p_resource_id   uuid  DEFAULT NULL,
  p_details       jsonb DEFAULT '{}'::jsonb,
  p_actor_id      uuid  DEFAULT NULL,
  p_actor_role    text  DEFAULT NULL,
  p_ip            text  DEFAULT NULL,
  p_user_agent    text  DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id      uuid;
  v_headers jsonb := '{}'::jsonb;
  v_ip_text text;
  v_ua      text;
  v_ip      inet;
BEGIN
  -- request.headers is set by PostgREST; wrapped so that non-PostgREST
  -- callers (psql, pg_cron) fall back gracefully instead of erroring.
  BEGIN
    v_headers := current_setting('request.headers', true)::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := '{}'::jsonb;
  END;

  -- Header first: cf-connecting-ip is spoof-resistant and reflects the
  -- real client. p_ip (from req.ip in a Worker) is often the Worker's own
  -- egress IP, so it is used only as a fallback for non-Worker callers.
  v_ip_text := COALESCE(
    NULLIF(v_headers->>'x-sscmps-client-ip', ''),
    NULLIF(p_ip, '')
  );
  v_ua := COALESCE(
    NULLIF(v_headers->>'x-sscmps-client-ua', ''),
    NULLIF(p_user_agent, '')
  );

  -- audit_log.ip_address is inet, not text. Cast defensively; malformed
  -- values become NULL rather than failing the caller's transaction.
  IF v_ip_text IS NOT NULL THEN
    BEGIN
      v_ip := v_ip_text::inet;
    EXCEPTION WHEN OTHERS THEN
      v_ip := NULL;
    END;
  END IF;

  INSERT INTO public.audit_log(
    actor_id, actor_role, action, resource_type, resource_id,
    details, ip_address, user_agent
  ) VALUES (
    COALESCE(p_actor_id, app_member_id()),
    COALESCE(p_actor_role, app_role(), 'SYSTEM'),
    p_action, p_resource_type, p_resource_id,
    COALESCE(p_details, '{}'::jsonb),
    v_ip, v_ua
  ) RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- 3. Restore security posture
--    Postgres grants EXECUTE to PUBLIC by default on every new function.
--    Revoke it so anon (the frontend's publishable key) cannot invoke this
--    SECURITY DEFINER function and inject forged audit rows.
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION
  public.write_audit(text, text, uuid, jsonb, uuid, text, text, text)
  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.write_audit(text, text, uuid, jsonb, uuid, text, text, text)
  TO authenticated;

GRANT EXECUTE ON FUNCTION
  public.write_audit(text, text, uuid, jsonb, uuid, text, text, text)
  TO service_role;

-- ---------------------------------------------------------------------
-- 4. Drop the parked old function
-- ---------------------------------------------------------------------
DROP FUNCTION public.write_audit_v0(text, text, uuid, jsonb, uuid);

-- ---------------------------------------------------------------------
-- 5. Grant ingest_api_credit to authenticated
--    Route /api/treasury/ingest-api-credit is requireTreasurer, and the
--    Worker will call it via req.supabase (user JWT), so authenticated
--    must have EXECUTE.
--    Also revoke PUBLIC defensively — this function was NOT recreated in
--    this migration, so if it was already revoked by
--    20261011000002_revoke_public_execute.sql the REVOKE is a no-op;
--    if it wasn't, this closes the same hole.
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.ingest_api_credit(
  numeric, date, text, text, text, text, uuid, text, jsonb, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.ingest_api_credit(
  numeric, date, text, text, text, text, uuid, text, jsonb, text
) TO authenticated;