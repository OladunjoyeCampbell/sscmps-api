// src/config/index.js
import dotenv from 'dotenv';

// Load .env file
dotenv.config();

const processEnv = process.env || {};

// Validate required environment variables
const required = ['JWT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'SUPABASE_ANON_KEY'];
const missing = required.filter(key => !processEnv[key]);

if (missing.length > 0) {
  console.warn(`⚠️ Missing environment variables: ${missing.join(', ')}`);
  console.warn('   Please check your .env file.');
  if (processEnv.NODE_ENV === 'production') {
    console.error('❌ Production requires all environment variables.');
  } else {
    console.warn('   Some features may not work correctly.');
  }
}

// Check if running in Cloudflare Workers environment
const isCloudflare = typeof process === 'undefined' || typeof processEnv === 'undefined';

export default {
  NODE_ENV: processEnv.NODE_ENV || 'development',
  PORT: parseInt(processEnv.PORT || '3000', 10),
  JWT_SECRET: processEnv.JWT_SECRET || '',
  SUPABASE_URL: processEnv.SUPABASE_URL || '',
  SUPABASE_SERVICE_ROLE_KEY: processEnv.SUPABASE_SERVICE_ROLE_KEY || '',
  SUPABASE_ANON_KEY: processEnv.SUPABASE_ANON_KEY || '',
  CORS_ORIGIN: processEnv.CORS_ORIGIN || 'http://localhost:3000,http://localhost:5173',

// ⬇️ ADD RESEND CONFIGURATION ⬇️
  RESEND_API_KEY: processEnv.RESEND_API_KEY || '',
  RESEND_FROM_EMAIL: processEnv.RESEND_FROM_EMAIL || 'onboarding@resend.dev',
  RESEND_FROM_NAME: processEnv.RESEND_FROM_NAME || 'SSCMPS Cooperative',
  
  // Supabase client options
  supabaseOptions: {
    auth: {
      autoRefreshToken: true,
      persistSession: false,
      detectSessionInUrl: false,
    },
    db: {
      schema: 'public',
    },
  },
  
  // JWT options
  jwtOptions: {
    expiresIn: '24h',
    issuer: 'sscmps-api',
    audience: 'sscmps-frontend',
  },
  
  // CORS options
  corsOptions: {
    origin: (processEnv.CORS_ORIGIN || 'http://localhost:3000,http://localhost:5173').split(',').map(o => o.trim()),
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With'],
  },
  
  isDevelopment: processEnv.NODE_ENV === 'development',
  isProduction: processEnv.NODE_ENV === 'production',
  isTest: processEnv.NODE_ENV === 'test',
  isCloudflare,
};