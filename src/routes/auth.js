// src/routes/auth.js
import express from "express";
import { supabaseAdmin, supabaseAnon } from "../lib/supabase.js";
import { asyncHandler } from "../middleware/error.js";
import { authenticateToken } from "../middleware/auth.js";
import { validatePassword } from "../lib/passwordPolicy.js";

const router = express.Router();

/**
 * POST /api/auth/register
 * Register a new member (Applicant status)
 */
router.post(
  "/register",
  asyncHandler(async (req, res) => {
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
        error:
          "Missing required fields: staff_id, email, password, first_name, last_name",
      });
    }
    // Enforce the password policy server-side. The frontend validates too,
    // but a direct API call could otherwise create a member with a weak
    // password and bypass the 12-character minimum.
    const policy = validatePassword(password, {
      email,
      firstName: first_name,
      lastName: last_name,
      staffId: staff_id,
    });

    if (!policy.valid) {
      return res.status(400).json({
        error: policy.errors[0] || "Password does not meet the policy",
        errors: policy.errors,
        code: "PASSWORD_POLICY",
      });
    }

    const { data: existingMember } = await supabaseAdmin
      .from("members")
      .select("id")
      .eq("staff_id", staff_id)
      .maybeSingle();
    if (existingMember)
      return res.status(409).json({ error: "Staff ID already registered" });

    const { data: existingEmail } = await supabaseAdmin
      .from("members")
      .select("id")
      .eq("email", email)
      .maybeSingle();
    if (existingEmail)
      return res.status(409).json({ error: "Email already registered" });

    const { data: authData, error: authError } =
      await supabaseAdmin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { staff_id, first_name, last_name },
      });

    if (authError) return res.status(400).json({ error: authError.message });

    const { data: member, error: memberError } = await supabaseAdmin
      .from("members")
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
        status: "Applicant",
        role: "Member",
      })
      .select()
      .single();

    if (memberError) {
      await supabaseAdmin.auth.admin.deleteUser(authData.user.id);
      return res.status(400).json({ error: memberError.message });
    }

    res.status(201).json({
      success: true,
      message:
        "Registration successful. Your application is pending approval by the Management Committee.",
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
  }),
);

/**
 * POST /api/auth/login
 */
router.post(
  "/login",
  asyncHandler(async (req, res) => {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: "Email and password are required" });
    }

    const normalizedEmail = email.trim().toLowerCase();
    const clientIp = req.headers["cf-connecting-ip"] || req.ip || null;

    let lockout = null;
    try {
      const { data } = await supabaseAdmin.rpc("check_login_lockout", {
        p_email: normalizedEmail,
        p_window_minutes: 15,
        p_threshold: 5,
      });
      lockout = data;
    } catch (err) {
      console.warn("[auth] lockout check failed:", err.message);
    }

    if (lockout?.locked) {
      return res.status(429).json({
        error:
          "Account temporarily locked due to repeated failed attempts. Please try again in 15 minutes.",
        code: "ACCOUNT_LOCKED",
      });
    }

    const { data: authData, error: authError } =
      await supabaseAnon.auth.signInWithPassword({
        email: normalizedEmail,
        password,
      });

    if (authError) {
      const threshold = 5;
      let attempts = 0;

      // Record this failed attempt
      try {
        await supabaseAdmin.rpc("record_login_attempt", {
          p_email: normalizedEmail,
          p_ip: clientIp,
        });
      } catch (err) {
        console.warn("[auth] failed to record login attempt:", err.message);
      }

      // Read back the current failure count
      try {
        const { data: state } = await supabaseAdmin.rpc("check_login_lockout", {
          p_email: normalizedEmail,
          p_window_minutes: 15,
          p_threshold: threshold,
        });
        if (state) attempts = state.attempts ?? 0;
      } catch (err) {
        console.warn("[auth] lockout re-check failed:", err.message);
      }

      const remaining = Math.max(0, threshold - attempts);

      return res.status(401).json({
        error: "Invalid credentials",
        attempts,
        attempts_remaining: remaining,
        lockout_threshold: threshold,
        lockout_window_minutes: 15,
      });
    }

    const { data: member, error: memberError } = await supabaseAdmin
      .from("members")
      .select("id, staff_id, first_name, last_name, email, status, role")
      .eq("email", normalizedEmail)
      .single();

    if (memberError || !member) {
      return res.status(401).json({
        error: "Member record not found",
        debug: { email_searched: normalizedEmail },
      });
    }

    if (["Suspended", "Terminated", "Exited"].includes(member.status)) {
      return res.status(403).json({ error: "Account is not active" });
    }

    try {
      await supabaseAdmin.rpc("clear_login_attempts", {
        p_email: normalizedEmail,
      });
    } catch (err) {
      console.warn("[auth] failed to clear login attempts:", err.message);
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
  }),
);
/**
 * POST /api/auth/forgot-password
 * Initiates a password reset. Never reveals whether the email exists.
 */
router.post(
  "/forgot-password",
  asyncHandler(async (req, res) => {
    const { email } = req.body;

    if (!email) {
      return res.status(400).json({ error: "Email is required" });
    }

    const normalizedEmail = email.trim().toLowerCase();

    // Always respond with the same message, regardless of whether the
    // email exists. This prevents account enumeration.
    const safeResponse = {
      success: true,
      message:
        "If that email is registered, a password reset link has been sent. Please check your inbox and spam folder.",
    };

    // Silent lookup — do not leak the result
    try {
      const { data: member } = await supabaseAdmin
        .from("members")
        .select("id, status")
        .eq("email", normalizedEmail)
        .maybeSingle();

      // Only trigger the reset for members in a state that should have
      // access. Suspended/Terminated members silently get no email.
      if (
        !member ||
        ["Suspended", "Terminated", "Exited"].includes(member.status)
      ) {
        return res.json(safeResponse);
      }

      const redirectTo = `${process.env.APP_URL || "https://sscmps.com.ng"}/reset-password`;

      const { error: resetError } =
        await supabaseAdmin.auth.resetPasswordForEmail(normalizedEmail, {
          redirectTo,
        });

      if (resetError) {
        console.error(
          "[auth] resetPasswordForEmail failed:",
          resetError.message,
        );
        // Do not surface the error — same response either way
      }

      // Optional: queue an in-app notification so the member sees a
      // record on their next login
      try {
        await supabaseAdmin.rpc("queue_notification", {
          p_member_id: member.id,
          p_category: "SYSTEM",
          p_subject: "Password reset requested",
          p_body:
            "A password reset was requested for your account. If this was not you, please contact the Secretary immediately.",
          p_payload: {},
        });
      } catch (err) {
        console.warn("[auth] reset notification failed:", err.message);
      }
    } catch (err) {
      console.error("[auth] forgot-password error:", err.message);
      // Never surface — same response
    }

    return res.json(safeResponse);
  }),
);

/**
 * POST /api/auth/reset-password
 * Verifies the reset token and updates the member's password.
 * The frontend receives the token from the URL fragment after the
 * user clicks the link in the reset email.
 */
router.post(
  "/reset-password",
  asyncHandler(async (req, res) => {
    const { access_token, new_password } = req.body;

    if (!access_token || !new_password) {
      return res.status(400).json({
        error: "access_token and new_password are required",
      });
    }

    // 1. Verify the reset token first — everything below depends on `user`
    const {
      data: { user },
      error: verifyError,
    } = await supabaseAdmin.auth.getUser(access_token);

    if (verifyError || !user) {
      return res.status(401).json({
        error:
          "This reset link is invalid or has expired. Please request a new one.",
        code: "INVALID_RESET_TOKEN",
      });
    }

    // 2. Look up the member record so the policy can check personal info
    const { data: memberForPolicy } = await supabaseAdmin
      .from("members")
      .select("id, first_name, last_name, staff_id, email")
      .eq("auth_user_id", user.id)
      .maybeSingle();

    // 3. Enforce the full password policy server-side
    const policy = validatePassword(new_password, {
      email: memberForPolicy?.email || user.email,
      firstName: memberForPolicy?.first_name,
      lastName: memberForPolicy?.last_name,
      staffId: memberForPolicy?.staff_id,
    });

    if (!policy.valid) {
      return res.status(400).json({
        error: policy.errors[0] || "Password does not meet the policy",
        errors: policy.errors,
        code: "PASSWORD_POLICY",
      });
    }

    // 4. Update the password via the admin API
    const { error: updateError } =
      await supabaseAdmin.auth.admin.updateUserById(user.id, {
        password: new_password,
      });

    if (updateError) {
      console.error("[auth] password update failed:", updateError.message);
      return res.status(400).json({
        error: updateError.message || "Failed to update password",
      });
    }

    // 5. Clear any lingering login attempts for this account — the reset
    //    is proof the user owns the email, so the lockout should lift.
    try {
      await supabaseAdmin.rpc("clear_login_attempts", {
        p_email: user.email.toLowerCase(),
      });
    } catch (err) {
      console.warn("[auth] clear_login_attempts failed:", err.message);
    }

    return res.json({
      success: true,
      message: "Password updated. You can now log in with your new password.",
    });
  }),
);
/**
 * POST /api/auth/refresh
 */
router.post(
  "/refresh",
  asyncHandler(async (req, res) => {
    const { refresh_token } = req.body;
    if (!refresh_token) {
      return res.status(400).json({ error: "refresh_token is required" });
    }

    const { data, error } = await supabaseAnon.auth.refreshSession({
      refresh_token,
    });

    if (error || !data?.session) {
      console.warn("[auth] refresh failed:", error?.message || "no session");
      return res.status(401).json({
        error: "Invalid or expired refresh token",
        code: "REFRESH_FAILED",
      });
    }

    console.log("[auth] refresh rotated for user", data.session.user.id);

    res.json({
      success: true,
      token: data.session.access_token,
      refresh_token: data.session.refresh_token,
      expires_at: data.session.expires_at,
    });
  }),
);

/**
 * GET /api/auth/me
 */
router.get(
  "/me",
  authenticateToken,
  asyncHandler(async (req, res) => {
    res.json({ success: true, member: req.user });
  }),
);

/**
 * POST /api/auth/logout
 * Server-side logout — revokes the current Supabase session.
 * Other devices where the same member is logged in stay active.
 */
router.post(
  "/logout",
  authenticateToken,
  asyncHandler(async (req, res) => {
    const authHeader = req.headers.authorization || "";
    const accessToken = authHeader.startsWith("Bearer ")
      ? authHeader.slice(7)
      : null;

    if (accessToken) {
      try {
        await supabaseAdmin.auth.admin.signOut(accessToken, "local");
      } catch (err) {
        console.warn("[auth] logout revocation failed:", err.message);
      }
    }

    res.json({ success: true, message: "Logged out successfully" });
  }),
);

/**
 * POST /api/auth/logout-all
 * Revoke every session for the current member, on every device.
 *
 * How it works:
 *   1. Stamp members.session_invalidated_at = now().
 *      The middleware rejects any JWT whose `iat` is older than this,
 *      on every device.
 *   2. Best-effort call to Supabase admin signOut with scope='global'
 *      so Supabase's own session list is tidy.
 *   3. Write an audit entry + queue an in-app notification.
 */
router.post('/logout-all', authenticateToken, asyncHandler(async (req, res) => {
  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.startsWith('Bearer ')
    ? authHeader.slice(7)
    : null;

  if (!accessToken) {
    return res.status(401).json({ error: 'No token provided' });
  }

  // 1. Stamp the invalidation time. This is the real enforcement.
  const { error: stampError } = await supabaseAdmin
    .from('members')
    .update({ session_invalidated_at: new Date().toISOString() })
    .eq('id', req.user.id);

  if (stampError) {
    console.error('[auth] failed to stamp session_invalidated_at:', stampError.message);
    return res.status(500).json({
      error: 'Failed to revoke sessions. Please try again.',
    });
  }

  // 2. Best-effort: also tell Supabase to clear its session list.
  //    Non-fatal if it fails — the middleware check above is what
  //    actually rejects tokens on other devices.
  try {
    await supabaseAdmin.auth.admin.signOut(accessToken, 'global');
  } catch (err) {
    console.warn('[auth] Supabase global signOut failed (non-fatal):', err.message);
  }

  // 3. Audit
  try {
    await supabaseAdmin.rpc('write_audit', {
      p_action: 'SIGN_OUT_EVERYWHERE',
      p_resource_type: 'member',
      p_resource_id: req.user.id,
      p_details: { self_service: true },
    });
  } catch (err) {
    console.warn('[auth] audit failed:', err.message);
  }

  // 4. Notification
  try {
    await supabaseAdmin.rpc('queue_notification', {
      p_member_id: req.user.id,
      p_category: 'SYSTEM',
      p_subject: 'Signed out of all devices',
      p_body:
        'Every session on your account has been signed out. If this was not you, contact the Secretary immediately.',
      p_payload: {},
    });
  } catch (err) {
    console.warn('[auth] notification failed:', err.message);
  }

  res.json({
    success: true,
    message: 'Signed out of all devices.',
  });
}));

/**
 * POST /api/auth/change-password
 * Change the password for the currently logged-in member.
 * Requires the current password for verification.
 */
router.post(
  "/change-password",
  authenticateToken,
  asyncHandler(async (req, res) => {
    const { current_password, new_password } = req.body;

    if (!current_password || !new_password) {
      return res.status(400).json({
        error: "current_password and new_password are required",
      });
    }

    // 1. Verify the current password by re-authenticating with Supabase
    const authHeader = req.headers.authorization || "";
    const accessToken = authHeader.startsWith("Bearer ")
      ? authHeader.slice(7)
      : null;

    if (!accessToken) {
      return res.status(401).json({ error: "No token provided" });
    }

    const {
      data: { user },
      error: verifyError,
    } = await supabaseAdmin.auth.getUser(accessToken);

    if (verifyError || !user) {
      return res.status(401).json({ error: "Invalid session" });
    }

    // Re-authenticate to confirm the current password
    const { error: signInError } = await supabaseAnon.auth.signInWithPassword({
      email: user.email,
      password: current_password,
    });

    if (signInError) {
      return res.status(401).json({
        error: "Current password is incorrect",
        code: "INVALID_CURRENT_PASSWORD",
      });
    }

    // 2. Reject if new password equals current
    if (current_password === new_password) {
      return res.status(400).json({
        error: "New password must be different from your current password",
        code: "SAME_PASSWORD",
      });
    }

    // 3. Enforce the full password policy server-side
    const { data: member } = await supabaseAdmin
      .from("members")
      .select("first_name, last_name, staff_id, email")
      .eq("auth_user_id", user.id)
      .maybeSingle();

    const policy = validatePassword(new_password, {
      email: member?.email || user.email,
      firstName: member?.first_name,
      lastName: member?.last_name,
      staffId: member?.staff_id,
    });

    if (!policy.valid) {
      return res.status(400).json({
        error: policy.errors[0] || "Password does not meet the policy",
        errors: policy.errors,
        code: "PASSWORD_POLICY",
      });
    }

    // 4. Update the password via the admin API
    const { error: updateError } =
      await supabaseAdmin.auth.admin.updateUserById(user.id, {
        password: new_password,
      });

    if (updateError) {
      console.error(
        "[auth] change-password update failed:",
        updateError.message,
      );
      return res.status(400).json({
        error: updateError.message || "Failed to update password",
      });
    }

    // 5. Audit
    try {
      await supabaseAdmin.rpc("write_audit", {
        p_action: "PASSWORD_CHANGED",
        p_resource_type: "member",
        p_resource_id: member?.id || null,
        p_details: { self_service: true },
      });
    } catch (err) {
      console.warn("[auth] audit failed:", err.message);
    }

    // 6. In-app notification so the member sees the record
    if (member?.id) {
      try {
        await supabaseAdmin.rpc("queue_notification", {
          p_member_id: member.id,
          p_category: "SYSTEM",
          p_subject: "Password changed",
          p_body:
            "Your password was changed. If this was not you, contact the Secretary immediately.",
          p_payload: {},
        });
      } catch (err) {
        console.warn("[auth] notification failed:", err.message);
      }
    }

    res.json({
      success: true,
      message: "Password updated successfully",
    });
  }),
);
export default router;
