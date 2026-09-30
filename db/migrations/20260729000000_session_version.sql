-- ============================================================
-- Session invalidation timestamp
-- ============================================================
-- Adds a column that records when a member explicitly signed out
-- everywhere. Every JWT issued *before* this timestamp is rejected
-- by the auth middleware, on every device.
--
-- Why this is needed:
--   supabaseAdmin.auth.admin.signOut(accessToken, 'global') is
--   documented to revoke "all sessions for the user", but in
--   practice it revokes only the session tied to the access token
--   supplied. Other devices keep their refresh tokens and can
--   silently mint new access tokens, defeating "sign out
--   everywhere". Stamping a timestamp on the member row and
--   rejecting older tokens is the reliable fix.
--
-- The column is nullable. NULL means "no invalidation has ever
-- been requested" — all tokens are valid. Set to a timestamp when
-- the member clicks "Sign out everywhere".
-- ============================================================

ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS session_invalidated_at timestamptz;

COMMENT ON COLUMN public.members.session_invalidated_at IS
  'Timestamp of the last "sign out everywhere". JWTs with an iat '
  'before this value are rejected by the auth middleware.';

-- Index for the middleware lookup (though it uses primary key
-- equality, so this is defensive — useful if the column is ever
-- queried in bulk).
CREATE INDEX IF NOT EXISTS idx_members_session_invalidated_at
  ON public.members (session_invalidated_at)
  WHERE session_invalidated_at IS NOT NULL;

NOTIFY pgrst, 'reload schema';