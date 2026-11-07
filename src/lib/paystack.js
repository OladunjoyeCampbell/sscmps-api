// src/lib/paystack.js
//
// Paystack helpers — server-side only. Never expose PAYSTACK_SECRET_KEY
// to the browser.

const PAYSTACK_BASE = 'https://api.paystack.co';

export const getPaystackSecret = () => {
  const key = process.env.PAYSTACK_SECRET_KEY;
  if (!key) {
    const err = new Error('PAYSTACK_SECRET_KEY is not configured');
    err.code = 'PAYSTACK_NOT_CONFIGURED';
    throw err;
  }
  return key;
};

export const isPaystackConfigured = () => !!process.env.PAYSTACK_SECRET_KEY;

/**
 * Initialize a Paystack transaction.
 * amountNaira is in the MAJOR unit (naira); we convert to kobo internally.
 */
export async function initializePaystackTransaction({
  email,
  amountNaira,
  reference,
  metadata,
  callbackUrl,
}) {
  const amountKobo = Math.round(Number(amountNaira) * 100);
  if (!Number.isFinite(amountKobo) || amountKobo < 100) {
    throw new Error('Amount must be at least ₦1');
  }

  const res = await fetch(`${PAYSTACK_BASE}/transaction/initialize`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${getPaystackSecret()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email,
      amount: amountKobo,
      reference,
      metadata,
      callback_url: callbackUrl,
    }),
  });

  const data = await res.json();
  if (!res.ok || !data.status) {
    throw new Error(data.message || 'Paystack initialization failed');
  }

  return {
    authorization_url: data.data.authorization_url,
    access_code: data.data.access_code,
    reference: data.data.reference,
  };
}

/**
 * Verify a transaction by reference (used by the callback page).
 */
export async function verifyPaystackTransaction(reference) {
  const res = await fetch(
    `${PAYSTACK_BASE}/transaction/verify/${encodeURIComponent(reference)}`,
    { headers: { Authorization: `Bearer ${getPaystackSecret()}` } }
  );
  const data = await res.json();
  if (!res.ok || !data.status) {
    throw new Error(data.message || 'Verification failed');
  }
  return {
    status: data.data.status,             // 'success' | 'failed' | 'abandoned'
    amount_naira: data.data.amount / 100,
    reference: data.data.reference,
    paid_at: data.data.paid_at,
    channel: data.data.channel,
    gateway_response: data.data.gateway_response,
  };
}

/**
 * Verify a Paystack webhook signature.
 * Paystack signs the RAW request body with HMAC-SHA512 using your secret
 * key and sends the hex digest in the x-paystack-signature header.
 *
 * Uses the Web Crypto API — compatible with Cloudflare Workers.
 */
export async function verifyPaystackSignature(rawBody, signature) {
  if (!signature || typeof signature !== 'string') return false;

  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    encoder.encode(getPaystackSecret()),
    { name: 'HMAC', hash: 'SHA-512' },
    false,
    ['sign']
  );

  const sigBuffer = await crypto.subtle.sign(
    'HMAC',
    cryptoKey,
    encoder.encode(rawBody)
  );

  const hexSig = Array.from(new Uint8Array(sigBuffer))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (hexSig.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < hexSig.length; i++) {
    diff |= hexSig.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return diff === 0;
}