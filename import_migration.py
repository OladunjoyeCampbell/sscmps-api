"""
import_migration.py — transactional loader for SSCMPS-Migration-v1-returned.xlsx

Reads the migration workbook, wipes existing test data, and inserts
all members, opening-balance ledger entries, loans, and repayment
schedules in a single transaction.

Any failure rolls back the entire import — the test data is preserved.

Run:  python import_migration.py
Env:  SUPABASE_DB_URL must be set

Cutover:  2026-10-24 (paper ledger frozen)
Launch:   2026-10-30
Tracking: compliance_tracking_from = 2026-11-01 for all migrated members

Connection notes
----------------
The URL is parsed with urllib.parse and its components passed to
psycopg2 as keyword arguments. This bypasses issues where psycopg2
misinterprets a connection string that has query parameters such as
?keepalives=1 appended.

SSL is enabled by default (Supabase requires it).
"""

import os
import sys
import re
import calendar
import urllib.parse
from datetime import datetime, date
from decimal import Decimal

from openpyxl import load_workbook
import psycopg2


# ---------------------------------------------------------------- config
WORKBOOK        = "SSCMPS-Migration-v1-returned.xlsx"
COMPLIANCE_FROM = date(2026, 11, 1)
CONTRIB_COUNT   = 6
OPENING_NOTE    = 'Historical savings brought forward from manual ledger at migration'
EXPECTED_MEMBERS = 74
EXPECTED_LOANS   = 36

DB_URL = os.environ.get("SUPABASE_DB_URL")
if not DB_URL:
    raise SystemExit("SUPABASE_DB_URL not set in environment")


# ---------------------------------------------------------------- helpers
def parse_date(v):
    if v is None or v == '':
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip()
    for fmt in ("%Y-%m-%d", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            pass
    return None


def add_months(d, months):
    """d + N calendar months, clamping day-of-month."""
    y = d.year + (d.month - 1 + months) // 12
    m = (d.month - 1 + months) % 12 + 1
    day = min(d.day, calendar.monthrange(y, m)[1])
    return date(y, m, day)


def connect(db_url):
    """
    Parse a Postgres connection URL and pass components explicitly to
    psycopg2. This avoids issues when the URL carries query params
    (e.g. ?keepalives=...) that psycopg2's URL parser mishandles.
    """
    p = urllib.parse.urlparse(db_url)
    return psycopg2.connect(
        host=p.hostname,
        port=p.port or 5432,
        dbname=(p.path or "/postgres").lstrip("/") or "postgres",
        user=p.username,
        password=p.password,
        sslmode="require",
        keepalives=1,
        keepalives_idle=20,
        keepalives_interval=5,
        keepalives_count=6,
    )


def read_members(ws):
    header = [c.value for c in ws[1]]
    H = {h: i for i, h in enumerate(header)}
    out = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if not row[H["registration_number *"]]:
            continue
        out.append({
            "reg":         str(row[H["registration_number *"]]).strip().zfill(4),
            "first_name":  str(row[H["first_name *"]] or "").strip(),
            "middle_name": (str(row[H["middle_name"]] or "").strip() or None),
            "last_name":   str(row[H["last_name *"]] or "").strip(),
            "email":       str(row[H["email *"]] or "").strip(),
            "phone":       (str(row[H["phone"]] or "").strip() or None),
            "admission_date":          parse_date(row[H["admission_date *"]]),
            "first_contribution_date": parse_date(row[H["first_contribution_date *"]]),
            "standing_contribution_amount": Decimal(str(row[H["standing_contribution_amount *"]])),
            "savings_balance":              Decimal(str(row[H["savings_balance *"]])),
            "status":      str(row[H["status *"]] or "").strip(),
        })
    return out


def read_loans(ws):
    header = [c.value for c in ws[1]]
    H = {h: i for i, h in enumerate(header)}
    out = []
    for row in ws.iter_rows(min_row=2, values_only=True):
        if not row[H["registration_number *"]]:
            continue
        out.append({
            "reg":  str(row[H["registration_number *"]]).strip().zfill(4),
            "ref":  str(row[H["loan_reference_manual *"]] or "").strip(),
            "product_type": str(row[H["product_type *"]] or "").strip(),
            "principal_amount":      Decimal(str(row[H["principal_amount *"]])),
            "disbursement_date":     parse_date(row[H["disbursement_date *"]]),
            "term_months":           int(row[H["term_months *"]]),
            "total_repayable":       Decimal(str(row[H["total_repayable *"]])),
            "total_repaid":          Decimal(str(row[H["total_repaid *"]])),
            "outstanding_balance":   Decimal(str(row[H["outstanding_balance *"]])),
            "monthly_instalment":    Decimal(str(row[H["monthly_instalment *"]])),
            "instalments_paid":      int(row[H["instalments_paid *"]]),
            "instalments_remaining": int(row[H["instalments_remaining *"]]),
            "status":      str(row[H["status *"]] or "").strip(),
        })
    return out


# ---------------------------------------------------------------- main
def main():
    print(f"Reading {WORKBOOK} ...")
    wb = load_workbook(WORKBOOK)
    members = read_members(wb["Members"])
    loans   = read_loans(wb["Loans"])
    print(f"  Members: {len(members)}")
    print(f"  Loans:   {len(loans)}")

    if len(members) != EXPECTED_MEMBERS:
        raise SystemExit(f"Expected {EXPECTED_MEMBERS} members, got {len(members)}")
    if len(loans) != EXPECTED_LOANS:
        raise SystemExit(f"Expected {EXPECTED_LOANS} loans, got {len(loans)}")

    # ---- pre-flight reconciliation
    print("Pre-flight checks ...")
    regs = {m["reg"] for m in members}
    for l in loans:
        if l["reg"] not in regs:
            raise SystemExit(f"Loan {l['ref']} references unknown member {l['reg']}")
        if l["total_repaid"] + l["outstanding_balance"] != l["total_repayable"]:
            raise SystemExit(
                f"Loan {l['ref']} does not reconcile: "
                f"{l['total_repaid']} + {l['outstanding_balance']} != {l['total_repayable']}"
            )
        if l["instalments_paid"] + l["instalments_remaining"] != l["term_months"]:
            raise SystemExit(f"Loan {l['ref']} instalments do not sum to term_months")
    print("  OK")

    # ---- connect
    print("Opening DB connection ...")
    host_display = urllib.parse.urlparse(DB_URL).hostname
    print(f"  host: {host_display}")
    conn = connect(DB_URL)
    conn.autocommit = False
    cur = conn.cursor()

    try:
        # ---- 1. Wipe
        print("Wiping existing test data ...")
        cur.execute("""
            truncate table
              public.loan_repayment_schedule,
              public.sureties,
              public.loans,
              public.ledger_entries,
              public.payment_allocations,
              public.payment_notifications,
              public.notification_queue,
              public.admission_votes,
              public.member_expulsion_recommendations,
              public.withdrawal_signoffs,
              public.withdrawal_requests,
              public.unidentified_deposits,
              public.bank_transactions,
              public.contribution_fine_events,
              public.login_attempts,
              public.audit_log,
              public.idempotency_keys,
              public.members
              restart identity cascade
        """)

        # ---- 2. Load loan_products map
        cur.execute("select id, name from public.loan_products")
        product_map = {name: pid for pid, name in cur.fetchall()}
        print(f"  Products: {sorted(product_map.keys())}")

        # ---- 3. Insert members + opening balances
        print("Inserting members and opening balances ...")
        reg_to_id = {}
        ledger_count = 0
        for m in members:
            cur.execute("""
                insert into public.members (
                  registration_number, first_name, middle_name, last_name,
                  email, phone, admission_date, first_contribution_date,
                  standing_contribution_amount, status, role,
                  contributions_count_historical, compliance_tracking_from
                ) values (
                  %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'Member', %s, %s
                )
                returning id
            """, (
                m["reg"], m["first_name"], m["middle_name"], m["last_name"],
                m["email"], m["phone"], m["admission_date"],
                m["first_contribution_date"],
                m["standing_contribution_amount"], m["status"],
                CONTRIB_COUNT, COMPLIANCE_FROM,
            ))
            member_id = cur.fetchone()[0]
            reg_to_id[m["reg"]] = member_id

            if m["savings_balance"] > 0:
                cur.execute("""
                    insert into public.ledger_entries (
                      member_id, transaction_type, amount, transaction_date,
                      source, status, allocation_notes
                    ) values (
                      %s, 'CONTRIBUTION', %s, %s, 'SYSTEM', 'Approved', %s
                    )
                """, (
                    member_id, m["savings_balance"],
                    m["first_contribution_date"], OPENING_NOTE
                ))
                ledger_count += 1
        print(f"  Members: {len(members)}, ledger entries: {ledger_count}")

        # ---- 4. Insert loans + schedules
        print("Inserting loans and schedules ...")
        schedule_count = 0
        for l in loans:
            member_id  = reg_to_id[l["reg"]]
            product_id = product_map.get(l["product_type"])
            if not product_id:
                raise SystemExit(f"Loan {l['ref']}: unknown product_type {l['product_type']!r}")

            # Derived monthly (used in place of the workbook value)
            derived_monthly = (l["total_repayable"] / l["term_months"]).quantize(Decimal("0.01"))
            if l["monthly_instalment"] > 0:
                diff_pct = abs(l["monthly_instalment"] - derived_monthly) / derived_monthly * 100
                if diff_pct > 1:
                    print(
                        f"  WARNING: {l['ref']} (member {l['reg']}) — "
                        f"workbook monthly {l['monthly_instalment']} vs derived {derived_monthly} "
                        f"({diff_pct:.1f}% off). Using derived value."
                    )

            normal_interest  = l["total_repayable"] - l["principal_amount"]
            surplus_interest = Decimal("0.00")
            total_interest   = normal_interest
            covered          = l["principal_amount"]
            surplus          = Decimal("0.00")
            application_fee  = Decimal("0.00")

            if l["instalments_paid"] < l["term_months"]:
                next_due = add_months(l["disbursement_date"], l["instalments_paid"] + 1)
            else:
                next_due = None

            cur.execute("""...same INSERT...""", (
                l["ref"], member_id, product_id,
                l["principal_amount"], l["principal_amount"],
                covered, surplus,
                normal_interest, surplus_interest, total_interest,
                application_fee, l["total_repayable"], derived_monthly,   # <-- here
                l["term_months"], l["total_repaid"], l["instalments_paid"],
                next_due, l["status"],
                l["disbursement_date"], l["disbursement_date"], l["disbursement_date"],
                l["disbursement_date"],
            ))
            loan_id = cur.fetchone()[0]

            paid_through = l["instalments_paid"]
            for i in range(1, l["term_months"] + 1):
                due_date = add_months(l["disbursement_date"], i)
                if i == l["term_months"]:
                    scheduled = l["total_repayable"] - derived_monthly * (l["term_months"] - 1)
                else:
                    scheduled = derived_monthly

                if i <= paid_through:
                    amount_paid = scheduled
                    status      = "Paid"
                    paid_at     = datetime.combine(due_date, datetime.min.time())
                else:
                    amount_paid = Decimal("0.00")
                    status      = "Pending"
                    paid_at     = None

                cur.execute("""
                    insert into public.loan_repayment_schedule (
                      loan_id, instalment_number, due_date, scheduled_amount,
                      amount_paid, status, paid_at
                    ) values (
                      %s, %s, %s, %s, %s, %s, %s
                    )
                """, (
                    loan_id, i, due_date, scheduled,
                    amount_paid, status, paid_at
                ))
                schedule_count += 1

        print(f"  Loans: {len(loans)}, schedule rows: {schedule_count}")

        # ---- 5. Migration audit entry
        cur.execute("""
            insert into public.audit_log (actor_role, action, details)
            values (
              'SYSTEM',
              'MIGRATION_IMPORT',
              jsonb_build_object(
                'workbook', %s,
                'cutover_date', %s,
                'compliance_tracking_from', %s,
                'members_imported', %s,
                'ledger_entries_created', %s,
                'loans_imported', %s,
                'schedule_rows_created', %s
              )
            )
        """, (
            WORKBOOK, date(2026, 10, 24).isoformat(),
            COMPLIANCE_FROM.isoformat(),
            len(members), ledger_count, len(loans), schedule_count,
        ))

        # ---- 6. Commit
        conn.commit()
        print("✓ Migration committed")

        # ---- 7. Summary read-back
        cur.execute("""
            select
              (select count(*) from public.members)                        as members,
              (select count(*) from public.ledger_entries)                 as ledger_entries,
              (select count(*) from public.loans)                          as loans,
              (select count(*) from public.loan_repayment_schedule)        as schedule_rows,
              (select count(*) from public.members where status='Active')  as active_members,
              (select sum(get_member_savings_balance(id)) from public.members) as total_savings,
              (select sum(get_member_total_outstanding_loans(id)) from public.members) as total_loans_outstanding
        """)
        row = cur.fetchone()
        print("  Read-back:")
        print(f"    members:            {row[0]}")
        print(f"    ledger_entries:     {row[1]}")
        print(f"    loans:              {row[2]}")
        print(f"    schedule rows:      {row[3]}")
        print(f"    active members:     {row[4]}")
        print(f"    total savings:      N{row[5]}")
        print(f"    total loans out:    N{row[6]}")

    except Exception as e:
        conn.rollback()
        print(f"\n✗ Migration FAILED — rolled back")
        print(f"  {type(e).__name__}: {e}")
        raise
    finally:
        cur.close()
        conn.close()


if __name__ == "__main__":
    main()