-- ============================================================
-- Login attempts table for per-account lockout
-- ============================================================
-- Complements the Cloudflare IP-based rate limit with a
-- per-account throttle. After 5 failed attempts against the
-- same email within 15 minutes, further attempts for that
-- email are rejected until the window expires.
--
-- Design:
--   - Records every failed login by email + IP + time
--   - Successful login clears the account's failed attempts
--   - A periodic cleanup job prunes rows older than 24 hours
-- ============================================================

CREATE TABLE IF NOT EXISTS public.login_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  ip_address text,
  attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_email_time
  ON public.login_attempts (email, attempted_at DESC);

CREATE INDEX IF NOT EXISTS idx_login_attempts_attempted_at
  ON public.login_attempts (attempted_at);

-- Helper: check if an account is currently locked
CREATE OR REPLACE FUNCTION public.check_login_lockout(
  p_email text,
  p_window_minutes integer DEFAULT 15,
  p_threshold integer DEFAULT 5
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT jsonb_build_object(
    'locked', count(*) >= p_threshold,
    'attempts', count(*),
    'threshold', p_threshold,
    'window_minutes', p_window_minutes
  )
  FROM public.login_attempts
  WHERE email = lower(trim(p_email))
    AND attempted_at > now() - (p_window_minutes || ' minutes')::interval;
$function$;

-- Helper: record a failed attempt
CREATE OR REPLACE FUNCTION public.record_login_attempt(
  p_email text,
  p_ip text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  INSERT INTO public.login_attempts (email, ip_address)
  VALUES (lower(trim(p_email)), p_ip);
END;
$function$;

-- Helper: clear attempts on successful login
CREATE OR REPLACE FUNCTION public.clear_login_attempts(p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  DELETE FROM public.login_attempts WHERE email = lower(trim(p_email));
END;
$function$;

-- Helper: prune rows older than 24 hours (call from cron or manually)
CREATE OR REPLACE FUNCTION public.prune_login_attempts()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM public.login_attempts
  WHERE attempted_at < now() - interval '24 hours';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.check_login_lockout(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_login_attempt(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_login_attempts(text) TO authenticated;

NOTIFY pgrst, 'reload schema';