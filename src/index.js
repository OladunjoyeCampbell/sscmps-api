// src/index.js
import dns from 'dns';
dns.setDefaultResultOrder('ipv4first');

import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import config from './config/index.js';

import { startEmailWorker } from './workers/emailWorker.js';

import authRoutes from './routes/auth.js';
import memberRoutes from './routes/members.js';
import paymentRoutes from './routes/payments.js';
import loanRoutes from './routes/loans.js';
import suretyRoutes from './routes/sureties.js';
import treasuryRoutes from './routes/treasury.js';
import withdrawalRoutes from './routes/withdrawals.js';
import adminRoutes from './routes/admin.js';
import evidenceRoutes from './routes/evidence.js';

import { authenticateToken, requireAuth } from './middleware/auth.js';
import { errorHandler } from './middleware/error.js';

// 🔧 DIAGNOSTIC (remove after debugging)
console.log('🔧 Supabase config check:');
console.log('   URL:', config.SUPABASE_URL);
console.log('   ANON key length:', config.SUPABASE_ANON_KEY?.length || 0);
console.log('   SERVICE key length:', config.SUPABASE_SERVICE_ROLE_KEY?.length || 0);
console.log('   URL has https:', config.SUPABASE_URL?.startsWith('https://'));

const app = express();

app.use(helmet({
  contentSecurityPolicy: false,
  crossOriginEmbedderPolicy: false,
}));

app.use(cors(config.corsOptions));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true, limit: '10mb' }));

app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    environment: config.NODE_ENV,
  });
});

app.use('/api/auth', authRoutes);
app.use('/api/members', authenticateToken, requireAuth, memberRoutes);
app.use('/api/payments', authenticateToken, requireAuth, paymentRoutes);
app.use('/api/loans', authenticateToken, requireAuth, loanRoutes);
app.use('/api/sureties', authenticateToken, requireAuth, suretyRoutes);
app.use('/api/treasury', authenticateToken, requireAuth, treasuryRoutes);
app.use('/api/withdrawals', authenticateToken, requireAuth, withdrawalRoutes);
app.use('/api/admin', authenticateToken, requireAuth, adminRoutes);
app.use('/api/evidence', authenticateToken, requireAuth, evidenceRoutes);

app.use(errorHandler);

export default {
  async fetch(request, env, ctx) {
    process.env = { ...process.env, ...env };
    return app(request, env, ctx);
  }
};

if (config.isDevelopment || config.NODE_ENV === 'production') {
  const PORT = config.PORT;

  app.listen(PORT, () => {
    console.log(`🚀 API running on http://localhost:${PORT}`);
    console.log(`📝 Environment: ${config.NODE_ENV}`);
    console.log(`🔑 JWT_SECRET: ${config.JWT_SECRET ? '✅ Set' : '❌ Missing'}`);
    console.log(`🛢️  SUPABASE_URL: ${config.SUPABASE_URL ? '✅ Set' : '❌ Missing'}`);
    console.log(`📧 RESEND_API_KEY: ${config.RESEND_API_KEY ? '✅ Set' : '❌ Missing'}`);

    if (config.RESEND_API_KEY) {
      startEmailWorker();
    } else {
      console.warn('⚠️ Email worker not started — RESEND_API_KEY is missing');
    }
  });
}