-- 20261104000002_fix_audit_inet_cast.sql
--
-- Bug in 20261104000001_audit_ip_user_agent.sql: audit_log.ip_address is
-- type inet, but the new write_audit inserted a text variable directly.
-- Every financial RPC failed with:
--   column "ip_address" is of type inet but expression is of type text
-- The exception is: CREATE OR REPLACE preserves grants, so this migration
-- does NOT need to re-grant authenticated / service_role.

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
  BEGIN
    v_headers := current_setting('request.headers', true)::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := '{}'::jsonb;
  END;

  v_ip_text := COALESCE(
    NULLIF(v_headers->>'x-sscmps-client-ip', ''),
    NULLIF(p_ip, '')
  );
  v_ua := COALESCE(
    NULLIF(v_headers->>'x-sscmps-client-ua', ''),
    NULLIF(p_user_agent, '')
  );

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
