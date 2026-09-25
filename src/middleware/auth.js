// src/middleware/auth.js
import { supabaseAdmin } from '../lib/supabase.js';

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
 * Authenticate token and attach user to request.
 *
 * SECURITY: The token's signature is verified by Supabase via
 * supabaseAdmin.auth.getUser(token). This endpoint validates the
 * JWT signature against the current signing key, checks expiry,
 * and confirms the user exists. Without this check, a forged JWT
 * with an arbitrary 'sub' claim would grant access as that user.
 *
 * Do NOT trust decoded JWT payloads without signature verification.
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
    // 1. Verify the JWT with Supabase (validates signature + expiry)
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

    // 2. Look up the member record by the verified user ID
    const { data: member, error: memberError } = await supabaseAdmin
      .from('members')
      .select('id, staff_id, first_name, last_name, email, role, status, auth_user_id')
      .eq('auth_user_id', user.id)
      .single();

    if (memberError || !member) {
      return res.status(403).json({
        error: 'Member record not found',
        code: 'MEMBER_NOT_FOUND',
      });
    }

    // 3. Check account status
    if (
      member.status === 'Suspended' ||
      member.status === 'Terminated' ||
      member.status === 'Exited'
    ) {
      return res.status(403).json({
        error: 'Account is not active',
        code: 'ACCOUNT_INACTIVE',
      });
    }

    // 4. Attach to request
    req.user = {
      ...member,
      token,
      supabaseUser: { id: user.id, email: user.email },
    };

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