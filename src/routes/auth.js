// src/routes/auth.js
import express from 'express';
import { supabaseAdmin, supabaseAnon } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { authenticateToken } from '../middleware/auth.js';

const router = express.Router();

/**
 * POST /api/auth/register
 * Register a new member (Applicant status)
 */
router.post('/register', asyncHandler(async (req, res) => {
  const {
    staff_id, email, password, first_name, last_name, middle_name,
    phone, department, position, home_address,
    next_of_kin_name, next_of_kin_phone, next_of_kin_relationship,
    outside_indebtedness_declaration,
  } = req.body;

  if (!staff_id || !email || !password || !first_name || !last_name) {
    return res.status(400).json({
      error: 'Missing required fields: staff_id, email, password, first_name, last_name',
    });
  }

  const { data: existingMember } = await supabaseAdmin
    .from('members').select('id').eq('staff_id', staff_id).maybeSingle();
  if (existingMember) return res.status(409).json({ error: 'Staff ID already registered' });

  const { data: existingEmail } = await supabaseAdmin
    .from('members').select('id').eq('email', email).maybeSingle();
  if (existingEmail) return res.status(409).json({ error: 'Email already registered' });

  const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
    email, password, email_confirm: true,
    user_metadata: { staff_id, first_name, last_name },
  });

  if (authError) return res.status(400).json({ error: authError.message });

  const { data: member, error: memberError } = await supabaseAdmin
    .from('members')
    .insert({
      auth_user_id: authData.user.id,
      staff_id, email, first_name, last_name, middle_name,
      phone, department, position, home_address,
      next_of_kin_name, next_of_kin_phone, next_of_kin_relationship,
      outside_indebtedness_declaration,
      status: 'Applicant',
      role: 'Member',
    })
    .select()
    .single();

  if (memberError) {
    await supabaseAdmin.auth.admin.deleteUser(authData.user.id);
    return res.status(400).json({ error: memberError.message });
  }

  res.status(201).json({
    success: true,
    message: 'Registration successful. Your application is pending approval by the Management Committee.',
    member: {
      id: member.id,
      staff_id: member.staff_id,
      first_name: member.first_name,
      last_name: member.last_name,
      email: member.email,
      status: member.status,
      role: member.role,
    },
  });
}));

/**
 * POST /api/auth/login
 */
router.post('/login', asyncHandler(async (req, res) => {
  const { email, password } = req.body;
  if (!email || !password) {
    return res.status(400).json({ error: 'Email and password are required' });
  }

  const normalizedEmail = email.trim().toLowerCase();
  const clientIp = req.headers['cf-connecting-ip'] || req.ip || null;

  let lockout = null;
  try {
    const { data } = await supabaseAdmin.rpc('check_login_lockout', {
      p_email: normalizedEmail, p_window_minutes: 15, p_threshold: 5,
    });
    lockout = data;
  } catch (err) {
    console.warn('[auth] lockout check failed:', err.message);
  }

  if (lockout?.locked) {
    return res.status(429).json({
      error: 'Account temporarily locked due to repeated failed attempts. Please try again in 15 minutes.',
      code: 'ACCOUNT_LOCKED',
    });
  }

  const { data: authData, error: authError } = await supabaseAnon.auth.signInWithPassword({
    email: normalizedEmail, password,
  });

  if (authError) {
    try {
      await supabaseAdmin.rpc('record_login_attempt', {
        p_email: normalizedEmail, p_ip: clientIp,
      });
    } catch (err) {
      console.warn('[auth] failed to record login attempt:', err.message);
    }
    return res.status(401).json({ error: 'Invalid credentials' });
  }

  const { data: member, error: memberError } = await supabaseAdmin
    .from('members')
    .select('id, staff_id, first_name, last_name, email, status, role')
    .eq('email', normalizedEmail)
    .single();

  if (memberError || !member) {
    return res.status(401).json({
      error: 'Member record not found',
      debug: { email_searched: normalizedEmail },
    });
  }

  if (['Suspended', 'Terminated', 'Exited'].includes(member.status)) {
    return res.status(403).json({ error: 'Account is not active' });
  }

  try {
    await supabaseAdmin.rpc('clear_login_attempts', { p_email: normalizedEmail });
  } catch (err) {
    console.warn('[auth] failed to clear login attempts:', err.message);
  }

  res.json({
    success: true,
    token: authData.session.access_token,
    refresh_token: authData.session.refresh_token,
    expires_at: authData.session.expires_at,
    member: {
      id: member.id,
      staff_id: member.staff_id,
      first_name: member.first_name,
      last_name: member.last_name,
      email: member.email,
      status: member.status,
      role: member.role,
    },
  });
}));

/**
 * POST /api/auth/refresh
 */
router.post('/refresh', asyncHandler(async (req, res) => {
  const { refresh_token } = req.body;
  if (!refresh_token) {
    return res.status(400).json({ error: 'refresh_token is required' });
  }

  const { data, error } = await supabaseAnon.auth.refreshSession({ refresh_token });

  if (error || !data?.session) {
    console.warn('[auth] refresh failed:', error?.message || 'no session');
    return res.status(401).json({
      error: 'Invalid or expired refresh token',
      code: 'REFRESH_FAILED',
    });
  }

  console.log('[auth] refresh rotated for user', data.session.user.id);

  res.json({
    success: true,
    token: data.session.access_token,
    refresh_token: data.session.refresh_token,
    expires_at: data.session.expires_at,
  });
}));

/**
 * GET /api/auth/me
 */
router.get('/me', authenticateToken, asyncHandler(async (req, res) => {
  res.json({ success: true, member: req.user });
}));

/**
 * POST /api/auth/logout
 * Server-side logout — revokes the current Supabase session.
 * Other devices where the same member is logged in stay active.
 */
router.post('/logout', authenticateToken, asyncHandler(async (req, res) => {
  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.startsWith('Bearer ')
    ? authHeader.slice(7)
    : null;

  if (accessToken) {
    try {
      await supabaseAdmin.auth.admin.signOut(accessToken, 'local');
    } catch (err) {
      console.warn('[auth] logout revocation failed:', err.message);
    }
  }

  res.json({ success: true, message: 'Logged out successfully' });
}));

export default router;