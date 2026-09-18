// src/index.js
import dns from 'dns';
dns.setDefaultResultOrder('ipv4first');
import { httpServerHandler } from 'cloudflare:node';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import config from './config/index.js';

// NOTE: startEmailWorker uses setInterval / Node timers which do not
// behave reliably in Cloudflare Workers. Email sending should instead
// be driven by a Cron Trigger reading from the notification_queue
// table (see wrangler.toml [triggers]). Re-enable this import once
// that pattern is in place.
// import { startEmailWorker } from './workers/emailWorker.js';

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

// Cloudflare Workers entry point. Workers' nodejs_compat layer detects
// that `app` is an Express instance and adapts (Request, Env, Ctx) to
// Express's (req, res, next) signature.

app.listen(3000);

export default httpServerHandler({ port: 3000 });