// src/lib/resend.js
import { Resend } from 'resend';
import config from '../config/index.js';

// Initialize Resend client
export const resend = config.RESEND_API_KEY
  ? new Resend(config.RESEND_API_KEY)
  : null;

// Email sender configuration
const FROM_EMAIL = config.RESEND_FROM_EMAIL || 'onboarding@resend.dev';
const FROM_NAME = config.RESEND_FROM_NAME || 'SSCMPS Cooperative';

/**
 * Send an email via Resend
 */
export const sendEmail = async (to, subject, body) => {
  if (!resend) {
    console.warn('⚠️ Resend not configured — skipping email send');
    return { success: false, error: 'Resend not configured' };
  }

  try {
    const { data, error } = await resend.emails.send({
      from: `${FROM_NAME} <${FROM_EMAIL}>`,
      to: [to],
      subject: subject,
      html: body,
    });

    if (error) {
      console.error('❌ Resend error:', error);
      return { success: false, error: error.message };
    }

    console.log(`✅ Email sent to ${to} (id: ${data.id})`);
    return { success: true, id: data.id };
  } catch (error) {
    console.error('❌ Email send error:', error.message);
    return { success: false, error: error.message };
  }
};