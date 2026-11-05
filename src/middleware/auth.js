// src/middleware/auth.js
import { supabaseAdmin, createUserClient } from '../lib/supabase.js';

/**
 * Read a header whether req.headers is a plain object or a Headers
 * instance. Cloudflare Workers and Express-on-Workers expose this
 * inconsistently, so normalise both.
 */
function getHeader(req, name) {
  const h = req.headers;
  if (!h) return null;
  if (typeof h.get === 'function') return h.get(name);
  return h[name] ?? h[name.toLowerCase()] ?? null;
}

/**
 * Extract JWT token from Authorization header
 */
export const extractToken = (req) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return null;
  }
  return authHeader.substring(7);
};

/**
 * Decode the JWT payload WITHOUT verification.
 *
 * Safe: the caller must have already verified the token's signature
 * via supabaseAdmin.auth.getUser(token). We only read `iat`.
 *
 * Returns the parsed payload object, or null on any parse error.
 */
function decodeJwtPayload(token) {
  try {
    const part = token.split('.')[1];
    if (!part) return null;

    // Base64url → base64
    const padded = part + '='.repeat((4 - (part.length % 4)) % 4);
    const b64 = padded.replace(/-/g, '+').replace(/_/g, '/');

    // Buffer is available in Workers via nodejs_compat
    const json = Buffer.from(b64, 'base64').toString('utf-8');
    return JSON.parse(json);
  } catch {
    return null;
  }
}

/**
 * Authenticate token and attach user to request.
 *
 * SECURITY:
 *   1. The token's signature is verified by Supabase via
 *      supabaseAdmin.auth.getUser(token). Do NOT trust decoded
 *      payloads without this step.
 *   2. After signature verification, the token's `iat` claim is
 *      compared against members.session_invalidated_at. If the
 *      token was issued before the last "sign out everywhere", it
 *      is rejected. This is what makes the global sign-out stick.
 */
export const authenticateToken = async (req, res, next) => {
  const token = extractToken(req);

  if (!token) {
    return res.status(401).json({
      error: 'No token provided',
      code: 'UNAUTHORIZED',
    });
  }

  try {
    // 1. Verify the JWT signature + expiry with Supabase
    const {
      data: { user },
      error: authError,
    } = await supabaseAdmin.auth.getUser(token);

    if (authError || !user) {
      return res.status(401).json({
        error: 'Invalid or expired token',
        code: 'UNAUTHORIZED',
      });
    }

    // 2. Read `iat` from the (now-trusted) token payload
    const payload = decodeJwtPayload(token);
    const tokenIatMs = payload?.iat ? payload.iat * 1000 : null;

    // 3. Fetch the member record, including the invalidation stamp
    const { data: member, error: memberError } = await supabaseAdmin
      .from('members')
      .select(
        'id, staff_id, first_name, last_name, email, role, status, auth_user_id, session_invalidated_at'
      )
      .eq('auth_user_id', user.id)
      .single();

    if (memberError || !member) {
      return res.status(403).json({
        error: 'Member record not found',
        code: 'MEMBER_NOT_FOUND',
      });
    }

    // 4. Enforce session_invalidated_at.
    //    If the member signed out everywhere after this token was issued,
    //    the token is rejected here — regardless of whether Supabase still
    //    considers it valid.
    if (member.session_invalidated_at && tokenIatMs) {
      const invalidatedMs = new Date(member.session_invalidated_at).getTime();
      if (tokenIatMs < invalidatedMs) {
        return res.status(401).json({
          error: 'Your session was ended. Please log in again.',
          code: 'SESSION_REVOKED',
        });
      }
    }

    // 5. Account status check
    if (['Suspended', 'Terminated', 'Exited'].includes(member.status)) {
      return res.status(403).json({
        error: 'Account is not active',
        code: 'ACCOUNT_INACTIVE',
      });
    }

    // 6. Attach to request
    req.user = {
      ...member,
      token,
      supabaseUser: { id: user.id, email: user.email },
    };

    // 7. Attach a user-scoped Supabase client for downstream RPCs.
    //    Carries the caller's JWT on the Authorization header so PostgREST
    //    resolves auth.uid() → app_member_id() / app_role() see the real
    //    actor, and write_audit() attributes correctly.
    //    Client IP / UA are forwarded as custom headers so write_audit()
    //    can read them from PostgREST's request.headers GUC.
    //    cf-connecting-ip is set by Cloudflare and cannot be spoofed by
    //    the end user; x-forwarded-for is the fallback for non-CF deploys.
    const clientIp =
      getHeader(req, 'cf-connecting-ip') ||
      (getHeader(req, 'x-forwarded-for') || '').split(',')[0]?.trim() ||
      '';
    const clientUa = getHeader(req, 'user-agent') || '';

    req.supabase = createUserClient(token, {
      'x-sscmps-client-ip': clientIp,
      'x-sscmps-client-ua': clientUa,
    });

    next();
  } catch (error) {
    console.error('[auth] Authentication error:', error.message);
    return res.status(500).json({
      error: 'Authentication failed',
      code: 'AUTH_ERROR',
    });
  }
};

/**
 * Ensure user is authenticated (alias)
 */
export const requireAuth = (req, res, next) => {
  if (!req.user) {
    return res.status(401).json({
      error: 'Authentication required',
      code: 'UNAUTHORIZED',
    });
  }
  next();
};

export const getMemberId = (req) => req.user?.id;
export const getMemberRole = (req) => req.user?.role;