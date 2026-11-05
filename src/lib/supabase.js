// src/lib/supabase.js
import dns from 'dns';
dns.setDefaultResultOrder('ipv4first');

import { createClient } from '@supabase/supabase-js';
import config from '../config/index.js';

// Robust fetch with retry logic (handles 25% packet loss gracefully)
const fetchWithRetry = async (url, options = {}) => {
  const maxRetries = 5;              // Increased from 3
  const baseDelay = 500;             // Start with 500ms
  let lastError;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 20000); // 20s timeout

      const response = await fetch(url, {
        ...options,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      // Only log retries on success after retry
      if (attempt > 0) {
        console.log(`✅ Fetch succeeded on attempt ${attempt + 1}`);
      }

      return response;
    } catch (error) {
      lastError = error;

      if (attempt < maxRetries) {
        const delay = baseDelay * Math.pow(2, attempt); // 500, 1000, 2000, 4000, 8000ms
        // Only log every other attempt to reduce noise
        if (attempt % 2 === 0) {
          console.warn(`⚠️ Fetch retry ${attempt + 1}/${maxRetries} in ${delay}ms...`);
        }
        await new Promise((r) => setTimeout(r, delay));
      }
    }
  }

  console.error(`❌ Fetch failed after ${maxRetries} retries:`, lastError?.message);
  throw lastError;
};

const supabaseOptions = {
  auth: {
    autoRefreshToken: false,
    persistSession: false,
  },
  global: {
    fetch: fetchWithRetry,
  },
};

export const supabaseAnon = createClient(
  config.SUPABASE_URL,
  config.SUPABASE_ANON_KEY,
  supabaseOptions
);

export const supabaseAdmin = createClient(
  config.SUPABASE_URL,
  config.SUPABASE_SERVICE_ROLE_KEY,
  supabaseOptions
);

// ---------------------------------------------------------------------
// User-scoped Supabase client.
//
// Sends the caller's JWT on the Authorization header, so PostgREST
// resolves auth.uid() and SECURITY DEFINER RPCs see the real actor
// instead of the service-role context. Without this, app_member_id()
// and app_role() return NULL and write_audit() logs SYSTEM.
//
// extraHeaders are forwarded on every request. src/middleware/auth.js
// passes x-sscmps-client-ip and x-sscmps-client-ua here; the DB reads
// them from the request.headers GUC inside write_audit().
//
// Uses the same fetchWithRetry and ipv4first DNS as the admin/anon
// clients so 25%-packet-loss resilience is identical.
// ---------------------------------------------------------------------
export const createUserClient = (accessToken, extraHeaders = {}) => {
  if (!accessToken) {
    throw new Error('createUserClient requires an access token');
  }
  if (!config.SUPABASE_ANON_KEY) {
    // Fall back to service role would silently elevate every RPC to
    // admin — fail loudly instead.
    throw new Error('SUPABASE_ANON_KEY is required for user-scoped clients');
  }

  return createClient(config.SUPABASE_URL, config.SUPABASE_ANON_KEY, {
    ...supabaseOptions,
    global: {
      ...supabaseOptions.global,
      headers: {
        Authorization: `Bearer ${accessToken}`,
        ...extraHeaders,
      },
    },
  });
};

export const supabase = supabaseAdmin;