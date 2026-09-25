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
    staff_id,
    email,
    password,
    first_name,
    last_name,
    middle_name,
    phone,
    department,
    position,
    home_address,
    next_of_kin_name,
    next_of_kin_phone,
    next_of_kin_relationship,
    outside_indebtedness_declaration,
  } = req.body;

  if (!staff_id || !email || !password || !first_name || !last_name) {
    return res.status(400).json({
      error: 'Missing required fields: staff_id, email, password, first_name, last_name',
    });
  }

  // Check if staff_id already exists
  const { data: existingMember } = await supabaseAdmin
    .from('members')
    .select('id')
    .eq('staff_id', staff_id)
    .maybeSingle();

  if (existingMember) {
    return res.status(409).json({ error: 'Staff ID already registered' });
  }

  // Check if email already exists
  const { data: existingEmail } = await supabaseAdmin
    .from('members')
    .select('id')
    .eq('email', email)
    .maybeSingle();

  if (existingEmail) {
    return res.status(409).json({ error: 'Email already registered' });
  }

  // 1. Create auth user
  const { data: authData, error: authError } = await supabaseAdmin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      staff_id,
      first_name,
      last_name,
    },
  });

  if (authError) {
    return res.status(400).json({ error: authError.message });
  }

  // 2. Create member record
  const { data: member, error: memberError } = await supabaseAdmin
    .from('members')
    .insert({
      auth_user_id: authData.user.id,
      staff_id,
      email,
      first_name,
      last_name,
      middle_name,
      phone,
      department,
      position,
      home_address,
      next_of_kin_name,
      next_of_kin_phone,
      next_of_kin_relationship,
      outside_indebtedness_declaration,
      status: 'Applicant',
      role: 'Member',
    })
    .select()
    .single();

  if (memberError) {
    // Rollback auth user creation
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
 * Login with email and password - returns Supabase access token
 */
router.post('/login', asyncHandler(async (req, res) => {
  const { email, password } = req.body;

  if (!email || !password) {
    return res.status(400).json({ error: 'Email and password are required' });
  }

  const normalizedEmail = email.trim().toLowerCase();
  const clientIp = req.headers['cf-connecting-ip'] || req.ip || null;

  // 1. Check per-account lockout BEFORE calling Supabase
  let lockout = null;
  try {
    const { data } = await supabaseAdmin.rpc('check_login_lockout', {
      p_email: normalizedEmail,
      p_window_minutes: 15,
      p_threshold: 5,
    });
    lockout = data;
  } catch (err) {
    console.warn('[auth] lockout check failed:', err.message);
  }

  if (lockout?.locked) {
    return res.status(429).json({
      error:
        'Account temporarily locked due to repeated failed attempts. Please try again in 15 minutes.',
      code: 'ACCOUNT_LOCKED',
    });
  }

  // 2. Attempt Supabase login
  const { data: authData, error: authError } = await supabaseAnon.auth.signInWithPassword({
    email: normalizedEmail,
    password,
  });

  if (authError) {
    // Record the failed attempt without blocking the response
    try {
      await supabaseAdmin.rpc('record_login_attempt', {
        p_email: normalizedEmail,
        p_ip: clientIp,
      });
    } catch (err) {
      console.warn('[auth] failed to record login attempt:', err.message);
    }

    return res.status(401).json({ error: 'Invalid credentials' });
  }

  // 3. Look up the member record
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

  // 4. Check status
  if (
    member.status === 'Suspended' ||
    member.status === 'Terminated' ||
    member.status === 'Exited'
  ) {
    return res.status(403).json({ error: 'Account is not active' });
  }

  // 5. Successful login — clear the failure record for this email
  try {
    await supabaseAdmin.rpc('clear_login_attempts', { p_email: normalizedEmail });
  } catch (err) {
    console.warn('[auth] failed to clear login attempts:', err.message);
  }

  // 6. Return token and member
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
 * GET /api/auth/me
 * Get current authenticated user
 */
router.get('/me', authenticateToken, asyncHandler(async (req, res) => {
  res.json({
    success: true,
    member: req.user,
  });
}));

/**
 * POST /api/auth/logout
 * Logout (client-side token discard)
 */
router.post('/logout', (req, res) => {
  res.json({ success: true, message: 'Logged out successfully' });
});

export default router;