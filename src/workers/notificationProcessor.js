// src/workers/notificationProcessor.js
//
// Reads pending rows from notification_queue and sends them via Resend.
// Runs every 5 minutes on a Cloudflare Cron Trigger.
//
// Behaviour:
//   - Fetches up to 20 pending notifications, oldest first
//   - For each, resolves the recipient email (falls back to member record)
//   - Sends via Resend
//   - On success: status = 'Sent', sent_at = now
//   - On failure: increments attempts, stores last_error
//   - After 3 failed attempts, status = 'Failed' (no more retries)

import { Resend } from 'resend';
import { supabaseAdmin } from '../lib/supabase.js';
import config from '../config/index.js';

const MAX_ATTEMPTS = 3;
const BATCH_SIZE = 20;

export async function processNotificationQueue() {
  const summary = { processed: 0, sent: 0, failed: 0, skipped: 0 };

  // Prune stale login attempts on every cycle, regardless of queue state
  try {
    const { data: pruned } = await supabaseAdmin.rpc('prune_login_attempts');
    if (pruned > 0) {
      console.log(`[cron] pruned ${pruned} stale login attempt rows`);
    }
  } catch (err) {
    console.warn('[cron] prune failed:', err.message);
  }

  // Expire stale surety invitations on every cycle
  try {
    const { data: expired } = await supabaseAdmin.rpc('expire_stale_surety_requests');
    if (expired > 0) {
      console.log(`[cron] expired ${expired} stale surety invitation(s)`);
    }
  } catch (err) {
    console.warn('[cron] surety expiry failed:', err.message);
  }

  // Send surety reminders to sureties approaching their deadline
  try {
    const { data: reminded } = await supabaseAdmin.rpc('send_surety_reminders');
    if (reminded > 0) {
      console.log(`[cron] queued ${reminded} surety reminder(s)`);
    }
  } catch (err) {
    console.warn('[cron] surety reminders failed:', err.message);
  }
  if (!config.RESEND_API_KEY) {
    console.warn('[notify] RESEND_API_KEY not set — skipping queue processing');
    return summary;
  }

  const resend = new Resend(config.RESEND_API_KEY);

  // Fetch pending notifications ready for processing
  const { data: pending, error } = await supabaseAdmin
    .from('notification_queue')
    .select('*')
    .eq('status', 'Pending')
    .lt('attempts', MAX_ATTEMPTS)
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);

  if (error) {
    console.error('[notify] Failed to fetch queue:', error.message);
    return summary;
  }

  if (!pending || pending.length === 0) {
    return summary;
  }

  summary.processed = pending.length;

  for (const notification of pending) {
  try {
    // Resolve the recipient email
    let recipient = notification.recipient_email;

    if (!recipient && notification.recipient_member_id) {
      const { data: member } = await supabaseAdmin
        .from('members')
        .select('email')
        .eq('id', notification.recipient_member_id)
        .single();
      recipient = member?.email || null;
    }

    if (!recipient) {
      await markFailed(notification, 'No recipient email available');
      summary.skipped++;
      continue;
    }

    // Skip notifications whose referenced loan no longer exists
    if (notification.payload?.loan_id) {
      const { data: loan } = await supabaseAdmin
        .from('loans')
        .select('id')
        .eq('id', notification.payload.loan_id)
        .maybeSingle();

      if (!loan) {
        await markFailed(notification, 'Loan no longer exists — notification skipped');
        summary.skipped++;
        continue;
      }
    }

    // Send via Resend
    const { error: sendError } = await resend.emails.send({
      from: `${config.RESEND_FROM_NAME} <${config.RESEND_FROM_EMAIL}>`,
      to: recipient,
      subject: notification.subject,
      text: notification.body,
      html: buildEmailHtml(notification),
    });

    // ... rest unchanged

      if (sendError) {
        throw new Error(sendError.message || 'Resend send failed');
      }

      await supabaseAdmin
        .from('notification_queue')
        .update({
          status: 'Sent',
          sent_at: new Date().toISOString(),
          attempts: notification.attempts + 1,
          last_error: null,
          updated_at: new Date().toISOString(),
        })
        .eq('id', notification.id);

      summary.sent++;
    } catch (err) {
      console.error(`[notify] Failed to send ${notification.id}:`, err.message);
      await markFailed(notification, err.message);
      summary.failed++;
    }
  }

  return summary;
}



async function markFailed(notification, errorMessage) {
  const nextAttempts = notification.attempts + 1;
  const isFinal = nextAttempts >= MAX_ATTEMPTS;

  await supabaseAdmin
    .from('notification_queue')
    .update({
      status: isFinal ? 'Failed' : 'Pending',
      attempts: nextAttempts,
      last_error: errorMessage,
      updated_at: new Date().toISOString(),
    })
    .eq('id', notification.id);
}

function buildEmailHtml(notification) {
  const body = escapeHtml(notification.body);
  const year = new Date().getFullYear();

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
</head>
<body style="margin:0; padding:0; background:#f3f4f6; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif; color:#111827;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">
    <tr>
      <td align="center" style="padding:24px 12px;">
        <table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" style="max-width:600px; width:100%; background:#ffffff; border-radius:12px; overflow:hidden; box-shadow:0 1px 3px rgba(0,0,0,0.08);">
          <tr>
            <td style="background:#16a34a; padding:24px; text-align:center; color:#ffffff;">
              <img src="https://sscmps.com.ng/logo.png" alt="SSCMPS" width="64" height="64" style="display:block; margin:0 auto 8px;" />
              <div style="font-size:16px; font-weight:600; letter-spacing:0.5px;">SSCMPS</div>
              <div style="font-size:11px; opacity:0.85; margin-top:4px;">Niger State Polytechnic</div>
            </td>
          </tr>
          <tr>
            <td style="padding:32px 24px;">
              <h1 style="margin:0 0 16px; font-size:18px; font-weight:600; color:#111827;">${escapeHtml(notification.subject)}</h1>
              <p style="margin:0; font-size:14px; line-height:1.6; color:#374151; white-space:pre-line;">${body}</p>
            </td>
          </tr>
          <tr>
            <td style="padding:16px 24px 24px; text-align:center; border-top:1px solid #e5e7eb;">
              <p style="margin:0; font-size:11px; color:#9ca3af; line-height:1.5;">
                © ${year} SSCMPS Ltd. All rights reserved.<br />
                Senior Staff Cooperative and Multipurpose Society Limited
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function escapeHtml(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}