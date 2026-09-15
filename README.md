# SSCMPS Cooperative Management System API

**Niger State Polytechnic Senior Staff Cooperative & Multipurpose Society Ltd.**

---
This README.md provides:

1. **Project overview** – what the API does
2. **Technology stack** – what it's built with
3. **Folder structure** – where everything lives
4. **Environment variables** – how to configure
5. **Setup & deployment** – how to run it
6. **RBAC summary** – who can do what
7. **API endpoints** – all routes with roles
8. **Security notes** – important safeguards

## 📖 Overview

This is the backend API for the Digital Cooperative Management System, built for the Niger State Polytechnic Senior Staff Cooperative & Multipurpose Society Limited. It provides secure, role‑based access to member management, contributions, loans, sureties, treasury operations, and financial workflows — all backed by a Supabase PostgreSQL database with append‑only ledger and strict business‑rule enforcement.

---

## 🚀 Technology Stack

| **Component** | **Technology** |
|---------------|----------------|
| Runtime | Node.js + Express |
| Database | Supabase (PostgreSQL) |
| Authentication | JWT (signed with custom secret) |
| Deployment | Cloudflare Workers (Wrangler) |
| ORM / Client | Supabase JavaScript client |
| Security | Helmet, CORS, RLS, least‑privilege grants |

---

## 📂 Project Structure
sscmps-api/
├── src/
│ ├── index.js # Entry point
│ ├── routes/
│ │ ├── auth.js # Login, register, me, logout
│ │ ├── members.js # Profile, dashboard, statement
│ │ ├── payments.js # Submit, approve, decline, pending
│ │ ├── loans.js # Apply, calculate, approve, signoff, disburse
│ │ ├── sureties.js # Request, accept, view
│ │ ├── treasury.js # Dashboard, unidentified, reconciliation
│ │ ├── withdrawals.js # Request, approve, process
│ │ └── admin.js # Member applications, audit, fees
│ ├── middleware/
│ │ ├── auth.js # JWT verification
│ │ ├── rbac.js # Role‑based access control
│ │ └── error.js # Global error handler
│ ├── lib/
│ │ └── supabase.js # Supabase client (anon & service‑role)
│ └── config/
│ └── index.js # Environment config (optional)
├── .env # Environment variables (not committed)
├── .env.example # Template for environment variables
├── wrangler.toml # Cloudflare Workers configuration
├── package.json
└── README.md


---

## 🔐 Environment Variables

Create a `.env` file from `.env.example` and fill in the real values:

```env
NODE_ENV=development
PORT=3000
JWT_SECRET=your‑generated‑secret
SUPABASE_URL=https://your‑project‑id.supabase.co
SUPABASE_SERVICE_ROLE_KEY=your‑service‑role‑key
SUPABASE_ANON_KEY=your‑anon‑key

🛠️ Installation & Setup:
# 1. Clone the repository
git clone <your‑repo‑url>
cd sscmps-api

# 2. Install dependencies
npm install

# 3. Create environment file
cp .env.example .env
# Edit .env with real credentials

# 4. Run locally (development)
npm run dev

# 5. Deploy to Cloudflare Workers
npm run deploy


🔒 Role‑Based Access Control (RBAC)
The API uses JWT‑based authentication and enforces the following roles:

Role	Permissions
Member	View own profile, submit payments, apply for loans, request surety, request withdrawal
Treasurer	Approve/decline payments, manage unidentified deposits, disburse loans, reconcile bank transactions
Chairman	Sign off loan disbursements, approve withdrawals, view management dashboards
Secretary	Sign off loan disbursements, approve withdrawals, view management dashboards
LoanCommittee	Approve/reject loan applications
ManagementCommittee	Approve/reject member applications, update member status
SystemAdmin	Full access (audit logs, system configuration)
📡 API Endpoints Summary
🔐 Authentication
Method	Endpoint	Description
POST	/api/auth/register	Register new member (Applicant)
POST	/api/auth/login	Login with email/password → returns JWT
GET	/api/auth/me	Get current authenticated user
POST	/api/auth/logout	Logout (client‑side token discard)
👤 Members
Method	Endpoint	Description	Roles
GET	/api/members/profile	Get own profile	Member
PUT	/api/members/profile	Update non‑critical fields	Member
GET	/api/members/dashboard	Savings, loans, summary	Member
GET	/api/members/statement	Generate statement (PDF data)	Member
POST	/api/members/contribution-authority	Request contribution revision (Jan/Jul only)	Member
💳 Payments
Method	Endpoint	Description	Roles
POST	/api/payments/submit	Submit payment evidence	Member
GET	/api/payments/pending	Unified pending queue	Treasurer
POST	/api/payments/approve	Approve with split allocation	Treasurer
POST	/api/payments/decline	Decline with reason	Treasurer
GET	/api/payments/history	Payment history for member	Member
🏦 Loans
Method	Endpoint	Description	Roles
GET	/api/loans/products	Get active loan products	All
GET	/api/loans/calculate	Calculate two‑tier interest	Member
POST	/api/loans/apply	Apply for a loan	Member
GET	/api/loans/my	View own loans	Member
GET	/api/loans/schedule/:loanId	Repayment schedule	Member
POST	/api/loans/approve	Loan Committee approval	LoanCommittee
POST	/api/loans/signoff	Trustee sign‑off	Chairman, Secretary, Treasurer
POST	/api/loans/disburse	Disburse loan	Treasurer
GET	/api/loans/all	Full portfolio	Treasurer
🤝 Sureties
Method	Endpoint	Description	Roles
POST	/api/sureties/request	Request a surety	Borrower
POST	/api/sureties/accept	Accept a surety request	Surety
GET	/api/sureties/my	View surety requests for the member	Member
GET	/api/sureties/loan/:loanId	View sureties for a loan	Borrower / Management
🏛️ Treasury
Method	Endpoint	Description	Roles
GET	/api/treasury/dashboard	Management dashboard	Treasurer
GET	/api/treasury/pending	Pending payments (queue)	Treasurer
GET	/api/treasury/unidentified	Unidentified deposits	Treasurer
POST	/api/treasury/unidentified/resolve	Resolve a deposit	Treasurer
GET	/api/treasury/portfolio	Loan portfolio	Treasurer
GET	/api/treasury/reconciliation	Monthly reconciliation	Treasurer
GET	/api/treasury/bank-transactions	Bank transactions	Treasurer
POST	/api/treasury/ingest-api-credit	Ingest bank API credit	Treasurer
💰 Withdrawals
Method	Endpoint	Description	Roles
POST	/api/withdrawals/request	Request a withdrawal	Member
GET	/api/withdrawals/my	View own withdrawal requests	Member
GET	/api/withdrawals/pending	View pending withdrawals	Treasurer
POST	/api/withdrawals/approve	Approve a withdrawal	Trustee
POST	/api/withdrawals/process	Process an approved withdrawal	Treasurer
👑 Admin
Method	Endpoint	Description	Roles
GET	/api/admin/members/pending	Pending member applications	ManagementCommittee
POST	/api/admin/members/decide	Approve/reject application	ManagementCommittee
POST	/api/admin/members/update-status	Update member status	ManagementCommittee
GET	/api/admin/audit-log	Full audit log	SystemAdmin
POST	/api/admin/fees	Post entrance/loan form fees	Treasurer
🔒 Security Best Practices
All routes (except /api/auth/*) require a valid JWT.

RLS policies in Supabase enforce row‑level permissions.

service_role key is used only for backend operations (never exposed to frontend).

Ledger entries are append‑only — corrections must use the REVERSAL workflow.

Idempotency keys prevent duplicate API credit ingestion.

.env is never committed to version control.