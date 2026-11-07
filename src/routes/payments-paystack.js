// src/routes/payments-paystack.js
import express from 'express';
import { supabaseAdmin } from '../lib/supabase.js';
import { asyncHandler } from '../middleware/error.js';
import { getMemberId } from '../middleware/auth.js';
import {
  initializePaystackTransaction,
  verifyPaystackTransaction,
  verifyPaystackSignature,
  isPaystackConfigured,
} from '../lib/paystack.js';

const router = express.Router();

// ---------------------------------------------------------------------
// GET /api/payments/paystack/status (authenticated)
// Frontend uses this to decide whether to show the "Pay Online" button.
// ---------------------------------------------------------------------
router.get(
  '/status',
  asyncHandler(async (_req, res) => {
    res.json({ success: true, configured: isPaystackConfigured() });
  })
);

// ---------------------------------------------------------------------
// POST /api/payments/paystack/initialize (authenticated)
// ---------------------------------------------------------------------
router.post(
  '/initialize',
  asyncHandler(async (req, res) => {
    if (!isPaystackConfigured()) {
      return res.status(503).json({
        error: 'Online payments are not yet enabled',
        code: 'PAYSTACK_NOT_CONFIGURED',
      });
    }

    const memberId = getMemberId(req);
    const { amount, reason } = req.body || {};

    const amountNaira = Number(amount);
    if (!Number.isFinite(amountNaira) || amountNaira < 100) {
      return res.status(400).json({ error: 'Minimum online payment is ₦100' });
    }

    const { data: member, error: memberErr } = await supabaseAdmin
      .from('members')
      .select('id, email, first_name, last_name, status')
      .eq('id', memberId)
      .maybeSingle();

    if (memberErr || !member) {
      return res.status(404).json({ error: 'Member not found' });
    }
    if (member.status !== 'Active' && member.status !== 'Applicant') {
      return res.status(400).json({
        error: 'Your account status does not permit online payments',
      });
    }

    const reference = `SSM-${Date.now()}-${Math.random()
      .toString(36)
      .substring(2, 8)
      .toUpperCase()}`;

    const frontendUrl = process.env.FRONTEND_URL || 'https://sscmps.com.ng';

    try {
      const init = await initializePaystackTransaction({
        email: member.email,
        amountNaira,
        reference,
        metadata: {
          member_id: memberId,
          member_name: `${member.first_name} ${member.last_name}`,
          reason: reason || null,
          portal: 'SSCMPS',
          expected_amount_naira: amountNaira,
        },
        callbackUrl: `${frontendUrl}/payments/paystack/callback?reference=${reference}`,
      });

      return res.json({
        success: true,
        authorization_url: init.authorization_url,
        reference: init.reference,
      });
    } catch (err) {
      console.error('[paystack.initialize] failed:', err.message);
      return res.status(500).json({
        error: 'Could not start payment session',
        detail: err.message,
      });
    }
  })
);

// ---------------------------------------------------------------------
// GET /api/payments/paystack/verify/:reference (authenticated)
// The callback page calls this to distinguish success from cancel.
// ---------------------------------------------------------------------
router.get(
  '/verify/:reference',
  asyncHandler(async (req, res) => {
    if (!isPaystackConfigured()) {
      return res.status(503).json({
        error: 'Online payments are not yet enabled',
        code: 'PAYSTACK_NOT_CONFIGURED',
      });
    }

    try {
      const result = await verifyPaystackTransaction(req.params.reference);
      return res.json({
        success: result.status === 'success',
        status: result.status,
        amount: result.amount_naira,
        reference: result.reference,
        paid_at: result.paid_at,
        channel: result.channel,
        gateway_response: result.gateway_response,
      });
    } catch (err) {
      console.error('[paystack.verify] failed:', err.message);
      return res.status(400).json({ error: err.message });
    }
  })
);

// ---------------------------------------------------------------------
// Webhook handler — mounted directly in index.js BEFORE express.json()
// so req.body remains a raw Buffer for signature verification.
// ---------------------------------------------------------------------
export async function paystackWebhookHandler(req, res) {
  try {
    if (!isPaystackConfigured()) {
      // Silently acknowledge so Paystack doesn't retry repeatedly
      return res.status(200).json({ ok: true, ignored: 'not_configured' });
    }

    const rawBody = Buffer.isBuffer(req.body)
      ? req.body.toString('utf8')
      : typeof req.body === 'string'
      ? req.body
      : null;

    if (!rawBody) {
      return res.status(400).json({ error: 'Empty body' });
    }

    const signature = req.headers['x-paystack-signature'];
    const isValid = await verifyPaystackSignature(rawBody, signature);
    if (!isValid) {
      console.warn('[paystack.webhook] signature verification failed');
      return res.status(401).json({ error: 'Invalid signature' });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return res.status(400).json({ error: 'Invalid JSON' });
    }

    if (event.event !== 'charge.success') {
      return res.status(200).json({ ok: true, ignored: event.event });
    }

    const data = event.data || {};
    const metadata = data.metadata || {};
    const memberId = metadata.member_id;

    if (!memberId) {
      console.warn(
        '[paystack.webhook] no member_id in metadata',
        data.reference
      );
      return res.status(200).json({ ok: true, ignored: 'no_member_id' });
    }

    const expectedKobo = Math.round(
      Number(metadata.expected_amount_naira || 0) * 100
    );
    const actualKobo = Number(data.amount || 0);
    const matchConfidence =
      expectedKobo > 0 && actualKobo === expectedKobo ? 'EXACT' : 'PARTIAL';

    const transactionDate = data.paid_at
      ? data.paid_at.split('T')[0]
      : new Date().toISOString().split('T')[0];

    const idempotencyKey = `paystack:${data.id}`;

    const result = await supabaseAdmin.rpc('ingest_api_credit', {
      p_amount: actualKobo / 100,
      p_transaction_date: transactionDate,
      p_bank_reference: data.reference,
      p_narration: `Paystack ${data.channel || 'charge'} — ${
        metadata.reason || 'Online payment'
      }`,
      p_sender_name: data.customer?.email || null,
      p_sender_account: data.authorization?.last4
        ? `****${data.authorization.last4}`
        : null,
      p_member_id: memberId,
      p_match_confidence: matchConfidence,
      p_api_response: data,
      p_idempotency_key: idempotencyKey,
    });

    if (result.error) {
      console.error('[paystack.webhook] ingest failed:', result.error);
      // 200 so Paystack doesn't retry a permanently broken state
      return res
        .status(200)
        .json({ ok: false, error: result.error.message });
    }

    const notificationId = result.data;

    // Notify Treasurer
    try {
      const { data: treasurers } = await supabaseAdmin
        .from('members')
        .select('id')
        .eq('role', 'Treasurer')
        .eq('status', 'Active');

      const amountFormatted = `₦${(actualKobo / 100).toLocaleString('en-NG')}`;
      const memberName = metadata.member_name || 'a member';

      for (const t of treasurers || []) {
        await supabaseAdmin.rpc('queue_notification', {
          p_member_id: t.id,
          p_category: 'PENDING_QUEUE',
          p_subject: 'New online payment received',
          p_body: `${memberName} paid ${amountFormatted} via Paystack. Reference: ${data.reference}. Awaiting your approval.`,
          p_payload: {
            payment_notification_id: notificationId,
            source: 'PAYSTACK',
            reference: data.reference,
          },
        });
      }
    } catch (err) {
      console.warn('[paystack.webhook] treasurer notify failed:', err.message);
    }

    return res
      .status(200)
      .json({ ok: true, payment_notification_id: notificationId });
  } catch (err) {
    console.error('[paystack.webhook] unhandled:', err);
    return res.status(500).json({ error: 'Internal error' });
  }
}

export default router;