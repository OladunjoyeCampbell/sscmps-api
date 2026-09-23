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


## Overview

Secure, role-based REST API powering member management, contributions, loans, sureties, treasury operations, admission votes, and compliance tracking for the Cooperative. Built on Express running inside Cloudflare Workers, backed by Supabase PostgreSQL with row-level security, append-only ledger, and strict business-rule enforcement.

---

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Runtime | Cloudflare Workers (Node.js compatibility) |
| HTTP framework | Express 4 via `httpServerHandler` from `cloudflare:node` |
| Database | Supabase (PostgreSQL) |
| Authentication | Supabase Auth (JWT) |
| Deployment | Cloudflare Workers via Wrangler 4 |
| Supabase client | `@supabase/supabase-js` |
| Email | Resend |
| Security | Helmet, CORS, RLS, least-privilege grants |
| Compatibility flags | `nodejs_compat`, `enable_nodejs_http_server_modules` |

---

## Project Structure

## Project Structure
sscmps-api/
├── src/
│ ├── index.js # Entry point, Express app, httpServerHandler
│ ├── config/
│ │ └── index.js # Environment config
│ ├── middleware/
│ │ ├── auth.js # JWT verification, requireAuth
│ │ ├── rbac.js # Role-based access control
│ │ └── error.js # Global error handler, asyncHandler
│ ├── lib/
│ │ ├── supabase.js # Supabase clients (anon + service-role)
│ │ └── resend.js # Resend email client
│ ├── routes/
│ │ ├── auth.js # Register, login, refresh, me, logout
│ │ ├── members.js # Profile, dashboard, statement
│ │ ├── payments.js # Submit, approve, decline, history
│ │ ├── loans.js # Apply, calculate, decision, signoff, disburse
│ │ ├── sureties.js # Request, accept, decline
│ │ ├── treasury.js # Dashboard, reconciliation, compliance
│ │ ├── withdrawals.js # Request, approve, process
│ │ ├── admin.js # Member applications, votes, audit
│ │ └── evidence.js # Signed-URL for payment evidence
│ └── workers/
│ └── emailWorker.js # Notification queue processor (Node-only)
├── db/
│ └── migrations/ # Append-only Supabase migrations
├── scripts/ # Admin utilities and migration tooling
├── patches/ # patch-package patches (iconv-lite)
├── wrangler.toml # Cloudflare Workers configuration
├── .dev.vars # Local secrets (gitignored)
├── .env.node # Node scripts env vars (gitignored)
├── .env.example # Template
├── package.json
└── README.md
---


---

## Environment Variables

### Production — Cloudflare Workers Secrets

Set with `npx wrangler secret put <NAME> --env=""`:

| Variable | Purpose |
|----------|---------|
| `JWT_SECRET` | Signs authentication tokens |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Service-role key (backend only, never exposed) |
| `SUPABASE_ANON_KEY` | Publishable key (protected by RLS) |
| `RESEND_API_KEY` | Resend email API key |
| `RESEND_FROM_EMAIL` | Verified sender address |
| `RESEND_FROM_NAME` | Display name on outgoing email |
| `CORS_ORIGIN` | Comma-separated allowed origins |

### Local development

`.dev.vars` (Wrangler reads this; gitignored) contains the same keys. `.env.node` (used by `scripts/*.mjs`) contains the same values in dotenv format. Neither file is committed.

---

## Setup & Local Development

```powershell
# 1. Clone
git clone <repo-url>
cd sscmps-api

# 2. Install
npm install

# 3. Create .dev.vars and .env.node from .env.example
#    Fill in the Supabase and Resend credentials

# 4. Run locally
npm run dev
# Wrangler starts on http://127.0.0.1:8787

powershell:
npx wrangler deploy --env=""
Runs on Cloudflare Workers free tier (100,000 requests/day). Update secrets with:

powershell:
npx wrangler secret put <NAME> --env=""
The --env="" flag tells Wrangler to use the top-level environment when wrangler.toml defines both [env.production] and [env.development].

Role-Based Access Control
Role	Permissions
Member	View own profile/dashboard/statement, submit payments, apply for loans, request sureties, request withdrawals
Treasurer	Approve/decline payments, manage unidentified deposits, disburse loans, reconcile bank transactions, run compliance checks, vote on admissions, sign off disbursements
Secretary	Sign off loan disbursements, approve withdrawals, vote on admissions, view management dashboards
Chairman	Sign off loan disbursements, approve withdrawals, vote on admissions, view management dashboards
LoanCommitteeChairman	Record committee decisions on loan applications
LoanCommittee	Sit on the Loan Committee (attendance recorded in decisions)
ManagementCommittee	Vote on member admissions, update member status
SystemAdmin	Full access (audit logs, system configuration)
Admission-vote access is granted to Chairman, Secretary, and Treasurer as ex officio members of the Management Committee (Bye-law §29).

Business Rules Enforced
Contributions
Minimum monthly: ₦10,000 (Bye-law §13a)

Contribution authority form editable only in January or July (Bye-law §13b)

Fines for missed contributions and unauthorised downward revisions are recorded as compliance events, not charged (Committee decision 2026-09)

Loans
Two-tier interest (Bye-law §43, SRS FR-4.4):

Covered portion (≤ member's savings) × normal rate ÷ 100

Surplus portion (> savings) × 20% ÷ 100

Rates are flat charges, not annualised

Total Repayable = Principal + Interest (fee excluded)

First instalment = (Total ÷ Term) + ₦2,000 fee; subsequent instalments = Total ÷ Term

Terms derived from the product (Bye-law §46, §47, §48):

Long-Term: 24 months

Short-Term / Emergency: 6 months (10 if principal > ₦300,000)

Essential Commodity: 10 months

Sureties must both accept before committee decision (Bye-law §49)

Quorum of 3 for committee decisions (Bye-law §33)

2-of-3 trustee signatures required before disbursement (Bye-law §55d)

Calculation frozen at application: interest, total repayable, and instalment schedule are computed once when the member submits; disbursement does not recalculate

Admission
2-of-3 committee votes required to finalise (Bye-law §10, §29)

Registration number auto-assigned on approval

Rejection requires a stated reason (Bye-law §10)

Compliance
Missed contribution months are flagged on demand via run_compliance_check()

Fines recorded in contribution_fine_events with ledger_entry_id = NULL

Member dashboard shows default months in a banner

API Endpoints
Authentication
Method	Endpoint	Description
POST	/api/auth/register	Register new member (Applicant status)
POST	/api/auth/login	Login → returns JWT + member
POST	/api/auth/refresh	Refresh an expired token
GET	/api/auth/me	Get current authenticated user
POST	/api/auth/logout	Logout (client-side token discard)
Members
Method	Endpoint	Roles
GET	/api/members/profile	Member
PUT	/api/members/profile	Member
GET	/api/members/dashboard	Member
GET	/api/members/eligible-sureties	Member
GET	/api/members/statement	Member
POST	/api/members/contribution-authority	Member
Payments
Method	Endpoint	Roles
POST	/api/payments/submit	Member
GET	/api/payments/pending	Treasurer
POST	/api/payments/approve	Treasurer
POST	/api/payments/decline	Treasurer
GET	/api/payments/history	Member
Loans
Method	Endpoint	Roles
GET	/api/loans/products	Authenticated
GET	/api/loans/calculate	Member
POST	/api/loans/apply	Member
GET	/api/loans/my	Member
GET	/api/loans/:loanId	Owner or Management
GET	/api/loans/schedule/:loanId	Owner or Management
GET	/api/loans/pending	Committee / Management
GET	/api/loans/committee-members	LoanCommitteeChairman
GET	/api/loans/awaiting-signoff	Trustee
GET	/api/loans/ready-to-disburse	Treasurer
GET	/api/loans/all	Treasurer
POST	/api/loans/decline	LoanCommitteeChairman
POST	/api/loans/committee-decision	LoanCommitteeChairman
POST	/api/loans/signoff	Trustee
POST	/api/loans/disburse	Treasurer
Sureties
Method	Endpoint	Roles
POST	/api/sureties/request	Borrower
POST	/api/sureties/accept	Surety
POST	/api/sureties/decline	Surety
GET	/api/sureties/my	Member
GET	/api/sureties/loan/:loanId	Borrower or Management
Treasury
Method	Endpoint	Roles
GET	/api/treasury/dashboard	Treasurer
GET	/api/treasury/pending	Treasurer
GET	/api/treasury/unidentified	Treasurer
POST	/api/treasury/unidentified/resolve	Treasurer
GET	/api/treasury/portfolio	Treasurer
GET	/api/treasury/reconciliation	Treasurer
GET	/api/treasury/bank-transactions	Treasurer
POST	/api/treasury/ingest-api-credit	Treasurer
POST	/api/treasury/run-compliance-check	Treasurer
GET	/api/treasury/defaulting-members	Treasurer
Withdrawals
Method	Endpoint	Roles
POST	/api/withdrawals/request	Member
GET	/api/withdrawals/my	Member
GET	/api/withdrawals/pending	Treasurer
POST	/api/withdrawals/approve	Trustee
POST	/api/withdrawals/process	Treasurer
Admin
Method	Endpoint	Roles
GET	/api/admin/members/pending	Admission Committee
POST	/api/admin/members/vote	Admission Committee
POST	/api/admin/members/update-status	Admission Committee
GET	/api/admin/audit-log	SystemAdmin
POST	/api/admin/fees	Treasurer
Evidence
Method	Endpoint	Roles
GET	/api/evidence/:notificationId	Owner or Treasurer
Health
Method	Endpoint	Description
GET	/health	Liveness check (no auth)
Database Migrations
Applied chronologically via the Supabase SQL Editor:

File	Purpose
20260715000000_initial_schema.sql	Base tables, RLS policies, RPCs
20260717000000_evidence_storage_rls.sql	Folder-scoped Storage policies
20260718000000_loan_committee_workflow.sql	Committee decisions table + RPC
20260719000000_admission_votes.sql	Admission vote table + RPC
20260720000000_loan_schedule_due_day.sql	Due dates on 10th of following month
20260720000001_fix_existing_schedule_due_dates.sql	Realign old schedules
20260720000002_fines_tracking_only.sql	Fines as compliance events
20260721000000_payment_reference_autogen.sql	Auto-generated payment references
20260722000000_registration_number.sql	Member registration number
20260723000000_loan_surety_guards.sql	§49 surety enforcement
20260724000000_loan_freeze_at_application.sql	Two-tier freeze at application
20260725000000_loan_flat_interest_fee_in_first.sql	Flat rates, fee in first instalment
20260726000000_loans_check2_remove_fee.sql	Constraint update for new fee rule
Security Notes
All routes except /api/auth/* and /health require a valid JWT

RLS policies in Supabase enforce row-level permissions on member data

SUPABASE_SERVICE_ROLE_KEY is used only by the backend (never exposed to the frontend)

Ledger entries are append-only; corrections require the REVERSAL workflow

Idempotency keys prevent duplicate API credit ingestion

All secrets live in Cloudflare Workers Secrets (production) or .dev.vars / .env.node (local, gitignored)

The iconv-lite compatibility patch for Cloudflare Workers is maintained via patch-package (patches/iconv-lite+0.4.24.patch)

Related
Frontend: https://github.com/OladunjoyeCampbell/sscmps-frontend (private)

Production frontend: https://sscmps.com.ng

Production API: https://api.sscmps.com.ng/api

Ownership
© 2026 Niger State Polytechnic Senior Staff Cooperative and Multipurpose Society Limited. All rights reserved.

Credits
Developed by Dr Oladele Campbell for the Cooperative.

Commissioned by the SSCMPS Management Committee, September 2026.

Contact
For enquiries about the cooperative, contributions, or loans: contact the Secretary or Treasurer of the Cooperative.