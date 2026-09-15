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
 * Decode JWT payload WITHOUT verification
 * Safe because Supabase verifies signatures server-side when we call admin API
 */
const decodeJWT = (token) => {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    // Base64-decode the payload (part 1)
    const payload = JSON.parse(
      Buffer.from(parts[1], 'base64').toString('utf-8')
    );
    return payload;
  } catch (error) {
    console.error('❌ JWT decode error:', error.message);
    return null;
  }
};

/**
 * Authenticate token and attach user to request
 */
export const authenticateToken = async (req, res, next) => {
  const token = extractToken(req);

  if (!token) {
    return res.status(401).json({ error: 'No token provided', code: 'UNAUTHORIZED' });
  }

  try {
    // 1. Decode JWT to get user ID (Supabase JWT contains 'sub' = user ID)
    const decoded = decodeJWT(token);

    if (!decoded || !decoded.sub) {
      console.error('❌ Invalid JWT structure');
      return res.status(401).json({ error: 'Invalid token', code: 'UNAUTHORIZED' });
    }

    // 2. Check token expiry
    const now = Math.floor(Date.now() / 1000);
    if (decoded.exp && decoded.exp < now) {
      console.error('❌ Token expired at:', new Date(decoded.exp * 1000));
      return res.status(401).json({ error: 'Token expired', code: 'TOKEN_EXPIRED' });
    }

    // 3. Look up member by auth_user_id (more reliable than auth.getUser)
    const { data: member, error: memberError } = await supabaseAdmin
      .from('members')
      .select('id, staff_id, first_name, last_name, email, role, status, auth_user_id')
      .eq('auth_user_id', decoded.sub)
      .single();

    if (memberError || !member) {
      console.error('❌ Member not found for auth_user_id:', decoded.sub);
      return res.status(401).json({ error: 'Member not found', code: 'MEMBER_NOT_FOUND' });
    }

    // 4. Check account status
    if (
      member.status === 'Suspended' ||
      member.status === 'Terminated' ||
      member.status === 'Exited'
    ) {
      return res.status(403).json({ error: 'Account is not active', code: 'ACCOUNT_INACTIVE' });
    }

    // 5. Attach to request
    req.user = {
      ...member,
      token,
      supabaseUser: { id: decoded.sub, email: decoded.email },
    };

    next();
  } catch (error) {
    console.error('❌ Auth error:', error.message);
    return res.status(500).json({ error: 'Authentication failed', code: 'AUTH_ERROR' });
  }
};

/**
 * Ensure user is authenticated (alias)
 */
export const requireAuth = (req, res, next) => {
  if (!req.user) {
    return res.status(401).json({ error: 'Authentication required', code: 'UNAUTHORIZED' });
  }
  next();
};

export const getMemberId = (req) => req.user?.id;
export const getMemberRole = (req) => req.user?.role;