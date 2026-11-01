# Database Migrations — SSCMPS

This folder holds every database correction applied to the SSCMPS project.
The `.sql` files are the source of truth: they were executed against
both the copy DB (for verification) and the main DB (for production),
and re-running any file produces the same end state.

## Structure
db/
├── migrations/
│ ├── 20261101000001_phase1a_name_corrections.sql
│ ├── 20261101000002_phase1b_savings_corrections.sql
│ └── 20261101000003_phase2_additional_loans.sql
├── MIGRATIONS.md ← chronological log of every applied change
└── README.md ← this file



## How migrations are applied

**Two-database pattern** — always test on copy, then promote to main.

### 1. Prepare the copy (if not already live)

Restore the latest backup to the copy project:

```powershell
psql $env:COPY_DB_URL -v ON_ERROR_STOP=0 `
  -f "C:\sscmps-api\backup-public.sql" `
  2>&1 | Tee-Object -FilePath "C:\sscmps-api\restore-log.txt"
  
  Then verify row counts match main (members, loans, ledger_entries,
loan_repayment_schedule).

2. Apply on copy
Run the .sql file via psql:
psql $env:COPY_DB_URL -v ON_ERROR_STOP=0 -f db/migrations/<file>.sql

Or paste into Supabase SQL Editor for the copy project

Run the file's bottom-of-file verification queries; confirm all pass

Re-run the file once to confirm idempotency (no duplicates)

3. Apply on main
Snapshot or export affected rows first (Supabase Free plan has
no automated backups)

Run the identical file against main

Run the same verification queries

Confirm results match copy exactly (values may differ in UUIDs only)

4. Update MIGRATIONS.md
Record: file path, applied-to (copy/main), result, date, any caveats
(especially partial-payment cases, two-tier interest, or credit-limit
overrides).