// src/workers/emailWorker.js
import { supabaseAdmin } from '../lib/supabase.js';
import { sendEmail } from '../lib/resend.js';

const POLL_INTERVAL_MS = 5 * 60 * 1000;   // 5 minutes
const BATCH_SIZE = 10;
const MAX_ATTEMPTS = 3;

let isRunning = false;
let intervalHandle = null;
let consecutiveFailures = 0;

const processQueue = async () => {
  try {
    const { data: notifications, error } = await supabaseAdmin
      .from('notification_queue')
      .select('id, recipient_email, subject, body, attempts, payload')
      .eq('status', 'Pending')
      .lt('attempts', MAX_ATTEMPTS)
      .order('created_at', { ascending: true })
      .limit(BATCH_SIZE);

    if (error) {
      consecutiveFailures++;
      if (consecutiveFailures % 10 === 1) {
        console.error(`❌ Email worker failures: ${consecutiveFailures}. Last: ${error.message}`);
      }
      return;
    }

    // Reset failure counter on success
    if (consecutiveFailures > 0) {
      console.log(`✅ Email worker recovered after ${consecutiveFailures} failures`);
      consecutiveFailures = 0;
    }

    if (!notifications || notifications.length === 0) {
      return; // Silent when queue is empty
    }

    console.log(`📧 Processing ${notifications.length} pending email(s)`);

    for (const notification of notifications) {
      // Skip if no recipient
      if (!notification.recipient_email) {
        console.warn(`⚠️ Notification ${notification.id} has no recipient — marking failed`);
        await supabaseAdmin
          .from('notification_queue')
          .update({
            status: 'Failed',
            last_error: 'No recipient email',
            attempts: notification.attempts + 1,
            updated_at: new Date().toISOString(),
          })
          .eq('id', notification.id);
        continue;
      }

      // Attempt to send
      const result = await sendEmail(
        notification.recipient_email,
        notification.subject,
        notification.body
      );

      if (result.success) {
        // Mark as sent
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
      } else {
        // Mark as failed or retry
        const newAttempts = notification.attempts + 1;
        const newStatus = newAttempts >= MAX_ATTEMPTS ? 'Failed' : 'Pending';

        await supabaseAdmin
          .from('notification_queue')
          .update({
            status: newStatus,
            attempts: newAttempts,
            last_error: result.error || 'Unknown error',
            updated_at: new Date().toISOString(),
          })
          .eq('id', notification.id);
      }
    }
  } catch (error) {
    consecutiveFailures++;
    if (consecutiveFailures % 10 === 1) {
      console.error(`❌ Email worker exceptions: ${consecutiveFailures}. Last: ${error.message}`);
    }
  }
};

export const startEmailWorker = () => {
  if (isRunning) {
    console.warn('⚠️ Email worker is already running');
    return;
  }

  console.log('📧 Email worker started (polling every 5 min)');
  isRunning = true;

  // Run immediately, then on interval
  processQueue();
  intervalHandle = setInterval(processQueue, POLL_INTERVAL_MS);
};

export const stopEmailWorker = () => {
  if (intervalHandle) {
    clearInterval(intervalHandle);
    intervalHandle = null;
  }
  isRunning = false;
  console.log('📧 Email worker stopped');
};

export const processQueueNow = async () => {
  return await processQueue();
};