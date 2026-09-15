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

export const supabase = supabaseAdmin;