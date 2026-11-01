-- ============================================================
-- Phase 2 — Eight additional loans with repayment schedules
-- Date applied: 2026-11-01
-- Source: Treasurer correction letter 2026-10-31 + ADDITIONAL LOANS2.xlsx
-- Applied to: copy DB (verified) then main DB (verified)
-- Idempotent: yes (IF EXISTS guard skips existing loan references)
-- ============================================================
-- References (verified free against live DB before execution):
--   EM max = 009 → EM/010 free
--   LT max = 027 → LT/028..033 free
--   ST max = 002 → ST/003 free
--
-- Loans inserted:
--   LOAN/EM/010 — Enoch N Gana (0003)    Emergency  ₦500,000
--   LOAN/LT/028 — Elijah Santali (0004)  Long-Term  ₦500,000
--   LOAN/LT/029 — James B Kolo (0007)    Long-Term  ₦2,500,000
--   LOAN/LT/030 — Hassan Ndafatima (0027) Long-Term ₦1,000,000 (§43 two-tier)
--   LOAN/LT/031 — Peter Bake (0032)      Long-Term  ₦1,250,000 (second loan)
--   LOAN/LT/032 — Enoch Adama (0045)     Long-Term  ₦2,000,000
--   LOAN/ST/003 — Grace Gajere (0062)    Short-Term ₦100,000
--   LOAN/LT/033 — James Jibrin (0069)    Long-Term  ₦200,000 (§43 two-tier, 15mo)
--
-- Partial-payment cases (Treasurer confirmed):
--   EM/010: 7th instalment partial — ₦30,000 of ₦55,000
--   LT/031: 17th instalment partial — ₦53,700 of ₦54,700
--   LT/033: 1st instalment partial — ₦13,000 of ₦15,625
--
-- Interest treatment: all interest stored in normal_interest_applied,
-- surplus_interest_applied = 0. For Hassan (LT/030) and James Jibrin
-- (LT/033), this represents the §43 two-tier blended amount; the split
-- is documented in each loan's application_notes.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_treasurer_id uuid;
  v_member_id    uuid;
  v_product_id   uuid;
  v_loan_id      uuid;
  v_spec         record;
  v_i            int;
  v_due          date;
  v_monthly      numeric(14,2);
  v_savings      numeric(12,2);
  v_interest     numeric(12,2);
  v_repayable    numeric(14,2);
  v_paid_count   int;
  v_pend_count   int;
  v_row_sched    numeric(14,2);
  v_row_paid     numeric(14,2);
  v_partial_row  int;
  v_partial_paid numeric(14,2);

  v_loan_specs jsonb := '[
    {"reg":"0003","ref":"LOAN/EM/010","product":"Emergency","disbursed":"2026-02-02","term":10,
     "principal":500000,"interest":50000,"repayable":550000,"monthly_sheet":55000,
     "paid":7,"repaid":360000,"partial_row":7,"partial_amount":30000,
     "notes":"Historical loan (round 2). Emergency 10%% on N500,000 = N50,000. Principal corrected to N500,000; monthly N55,000. 7th instalment partial (N30,000 of N55,000), repaid N360,000, outstanding N190,000."},
    {"reg":"0004","ref":"LOAN/LT/028","product":"Long-Term","disbursed":"2026-10-10","term":24,
     "principal":500000,"interest":25000,"repayable":525000,"monthly_sheet":21875,
     "paid":0,"repaid":0,"partial_row":0,"partial_amount":0,
     "notes":"Historical loan (round 2). 5%% flat on N500,000 = N25,000. Principal corrected to N500,000; rate standard 5%%. 24 x N21,875 = N525,000 exact."},
    {"reg":"0007","ref":"LOAN/LT/029","product":"Long-Term","disbursed":"2026-10-10","term":24,
     "principal":2500000,"interest":125000,"repayable":2625000,"monthly_sheet":109375,
     "paid":0,"repaid":0,"partial_row":0,"partial_amount":0,
     "notes":"Historical loan (round 2). 5%% flat on N2,500,000 = N125,000. Sheet monthly N105,250 was typo; recorded N109,375 = N2,625,000/24 exact per Treasurer."},
    {"reg":"0027","ref":"LOAN/LT/030","product":"Long-Term","disbursed":"2026-10-30","term":24,
     "principal":1000000,"interest":57348.50,"repayable":1057348.50,"monthly_sheet":44056.19,
     "paid":0,"repaid":0,"partial_row":0,"partial_amount":0,
     "notes":"Historical loan (round 2). Bye-Law 43 two-tier: normal 5%% on N951,010 = N47,550.50; surplus 20%% on N48,990 = N9,798; total N57,348.50. Stored in normal_interest_applied; split documented here. Monthly N44,056.19; last row absorbs N0.06."},
    {"reg":"0032","ref":"LOAN/LT/031","product":"Long-Term","disbursed":"2024-10-30","term":24,
     "principal":1250000,"interest":62500,"repayable":1312500,"monthly_sheet":54700,
     "paid":17,"repaid":928900,"partial_row":17,"partial_amount":53700,
     "notes":"SECOND loan for Peter Bake (holds LOAN/LT/017). 5%% flat on N1,250,000 = N62,500 (single-tier; savings N1,441,355 > principal). 17th instalment partial (N53,700 of N54,700), repaid N928,900, outstanding N383,600. Last row N54,400 absorbs N300 rounding."},
    {"reg":"0045","ref":"LOAN/LT/032","product":"Long-Term","disbursed":"2026-10-30","term":24,
     "principal":2000000,"interest":100000,"repayable":2100000,"monthly_sheet":87500,
     "paid":0,"repaid":0,"partial_row":0,"partial_amount":0,
     "notes":"Historical loan (round 2). 5%% flat on N2,000,000 = N100,000. 24 x N87,500 = N2,100,000 exact."},
    {"reg":"0062","ref":"LOAN/ST/003","product":"Short-Term","disbursed":"2026-10-30","term":6,
     "principal":100000,"interest":10000,"repayable":110000,"monthly_sheet":18334,
     "paid":0,"repaid":0,"partial_row":0,"partial_amount":0,
     "notes":"Historical loan (round 2). 10%% flat on N100,000 = N10,000. Monthly N18,334; last row N18,330 absorbs N4 rounding."},
    {"reg":"0069","ref":"LOAN/LT/033","product":"Long-Term","disbursed":"2026-10-10","term":15,
     "principal":200000,"interest":34375,"repayable":234375,"monthly_sheet":15625,
     "paid":1,"repaid":13000,"partial_row":1,"partial_amount":13000,
     "notes":"Historical loan (round 2). Bye-Law 43 two-tier: normal 5%% on N37,500 = N1,875; surplus 20%% on N162,500 = N32,500; total N34,375. Stored in normal_interest_applied; split documented here. 15-month term (member request). 1st instalment partial (N13,000 of N15,625), outstanding N221,375."}
  ]'::jsonb;
BEGIN
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';
  IF v_treasurer_id IS NULL THEN
    RAISE EXCEPTION 'Treasurer account (0004) not found';
  END IF;

  FOR v_spec IN
    SELECT * FROM jsonb_to_recordset(v_loan_specs) AS x(
      reg text, ref text, product text, disbursed text, term int,
      principal numeric, interest numeric, repayable numeric,
      monthly_sheet numeric, paid int, repaid numeric,
      partial_row int, partial_amount numeric, notes text
    )
  LOOP
    IF EXISTS (SELECT 1 FROM loans WHERE loan_reference = v_spec.ref) THEN
      RAISE NOTICE 'Loan % already exists — skipping', v_spec.ref;
      CONTINUE;
    END IF;

    SELECT id INTO v_member_id FROM members WHERE registration_number = v_spec.reg;
    IF v_member_id IS NULL THEN RAISE EXCEPTION 'Member % not found', v_spec.reg; END IF;

    SELECT id INTO v_product_id FROM loan_products WHERE name = v_spec.product;
    IF v_product_id IS NULL THEN RAISE EXCEPTION 'Product not found: %', v_spec.product; END IF;

    v_monthly      := v_spec.monthly_sheet;
    v_savings      := COALESCE(get_member_savings_balance(v_member_id), 0);
    v_interest     := v_spec.interest;
    v_repayable    := v_spec.repayable;
    v_paid_count   := v_spec.paid;
    v_pend_count   := v_spec.term - v_spec.paid;
    v_partial_row  := COALESCE(v_spec.partial_row, 0);
    v_partial_paid := COALESCE(v_spec.partial_amount, 0);

    INSERT INTO loans (
      loan_reference, member_id, loan_product_id,
      principal_amount, member_savings_at_disbursement,
      covered_principal, surplus_principal,
      normal_interest_applied, surplus_interest_applied, total_interest,
      application_fee_charged, total_repayable, monthly_instalment,
      term_months, total_repaid, instalments_paid,
      next_payment_due_date, status,
      application_date, disbursed_at, approved_at, created_at, updated_at,
      application_notes
    ) VALUES (
      v_spec.ref, v_member_id, v_product_id,
      v_spec.principal, v_savings,
      v_spec.principal, 0,
      v_interest, 0, v_interest,
      0, v_repayable, v_monthly,
      v_spec.term, v_spec.repaid, v_spec.paid,
      NULL, 'Active',
      v_spec.disbursed::date, v_spec.disbursed::timestamptz, v_spec.disbursed::timestamptz,
      v_spec.disbursed::timestamptz, now(),
      v_spec.notes
    ) RETURNING id INTO v_loan_id;

    FOR v_i IN 1..v_spec.term LOOP
      v_due := (v_spec.disbursed::date + (v_i || ' months')::interval)::date;

      IF v_i > v_paid_count THEN
        IF v_i = v_spec.term THEN
          v_row_sched := v_repayable - (v_monthly * (v_spec.term - 1));
        ELSE
          v_row_sched := v_monthly;
        END IF;
        INSERT INTO loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount, amount_paid, status, paid_at)
        VALUES (v_loan_id, v_i, v_due, v_row_sched, 0, 'Pending', NULL);
      ELSE
        v_row_sched := v_monthly;
        IF v_i = v_partial_row THEN
          v_row_paid := v_partial_paid;
        ELSE
          v_row_paid := v_row_sched;
        END IF;
        INSERT INTO loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount, amount_paid, status, paid_at)
        VALUES (v_loan_id, v_i, v_due, v_row_sched, v_row_paid,
                CASE WHEN v_i = v_partial_row AND v_row_paid < v_row_sched
                     THEN 'Partially Paid' ELSE 'Paid' END,
                v_due::timestamptz);
      END IF;
    END LOOP;

    UPDATE loans SET
      next_payment_due_date = (SELECT min(due_date) FROM loan_repayment_schedule
                               WHERE loan_id = v_loan_id AND amount_paid < scheduled_amount),
      updated_at = now()
    WHERE id = v_loan_id;

    INSERT INTO ledger_entries (member_id, loan_id, transaction_type, amount, transaction_date, source, status, approved_by, approved_at, allocation_notes)
    VALUES (v_member_id, v_loan_id, 'LOAN_DISBURSEMENT', v_spec.principal, v_spec.disbursed::date,
            'SYSTEM', 'Approved', v_treasurer_id, now(),
            'Historical loan disbursement (round 2 correction, Treasurer 2026-10-31)');

    IF v_spec.repaid > 0 THEN
      INSERT INTO ledger_entries (member_id, loan_id, transaction_type, amount, transaction_date, source, status, approved_by, approved_at, allocation_notes)
      VALUES (v_member_id, v_loan_id, 'LOAN_REPAYMENT', v_spec.repaid,
              (v_spec.disbursed::date + (v_spec.paid || ' months')::interval)::date,
              'SYSTEM', 'Approved', v_treasurer_id, now(),
              format('Historical repayment aggregate: %s instalments totalling N%s', v_spec.paid, v_spec.repaid));
    END IF;

    PERFORM write_audit(
      'MIGRATION_LOAN_ADDED_ROUND2', 'loan', v_loan_id,
      jsonb_build_object(
        'loan_reference', v_spec.ref, 'member_registration', v_spec.reg,
        'principal', v_spec.principal, 'interest', v_interest,
        'repayable', v_repayable, 'repaid', v_spec.repaid,
        'term_months', v_spec.term, 'monthly', v_monthly,
        'partial_row', v_partial_row, 'partial_amount', v_partial_paid
      ),
      v_treasurer_id
    );

    RAISE NOTICE 'Inserted % — term %, monthly %, repaid %, partial row %',
      v_spec.ref, v_spec.term, v_monthly, v_spec.repaid, v_partial_row;
  END LOOP;
END $$;

COMMIT;

-- ============================================================
-- VERIFICATION (run after applying)
-- ============================================================
-- V1. Loans present with correct arithmetic (8 rows expected)
-- SELECT loan_reference, principal_amount, total_interest, total_repayable,
--        total_repaid, (total_repayable - total_repaid) AS outstanding,
--        monthly_instalment, term_months, instalments_paid, status
-- FROM loans
-- WHERE loan_reference IN (
--   'LOAN/EM/010','LOAN/LT/028','LOAN/LT/029','LOAN/LT/030',
--   'LOAN/LT/031','LOAN/LT/032','LOAN/ST/003','LOAN/LT/033')
-- ORDER BY loan_reference;
--
-- V2. Schedule sums = repayable (DECISIVE — all 8 must pass)
-- SELECT l.loan_reference, l.total_repayable,
--        SUM(s.scheduled_amount) AS schedule_sum,
--        SUM(s.amount_paid)      AS paid_sum,
--        l.total_repaid,
--        COUNT(*) FILTER (WHERE s.status='Paid')           AS paid_rows,
--        COUNT(*) FILTER (WHERE s.status='Partially Paid') AS partial_rows,
--        COUNT(*) FILTER (WHERE s.status='Pending')        AS pending_rows
-- FROM loans l
-- JOIN loan_repayment_schedule s ON s.loan_id = l.id
-- WHERE l.loan_reference IN (
--   'LOAN/EM/010','LOAN/LT/028','LOAN/LT/029','LOAN/LT/030',
--   'LOAN/LT/031','LOAN/LT/032','LOAN/ST/003','LOAN/LT/033')
-- GROUP BY l.loan_reference, l.total_repayable, l.total_repaid
-- ORDER BY l.loan_reference;
-- Expected: schedule_sum = total_repayable for all 8;
--           paid_sum = total_repaid for all 8;
--           partial_rows = 1 for EM/010, LT/031, LT/033; 0 otherwise.
--
-- V3. Ledger entries (8 disb + 3 rep = 11 total)
-- SELECT l.loan_reference,
--        COUNT(*) FILTER (WHERE le.transaction_type='LOAN_DISBURSEMENT') AS disb_rows,
--        COUNT(*) FILTER (WHERE le.transaction_type='LOAN_REPAYMENT')    AS rep_rows
-- FROM loans l
-- JOIN ledger_entries le ON le.loan_id = l.id
-- WHERE l.loan_reference IN (
--   'LOAN/EM/010','LOAN/LT/028','LOAN/LT/029','LOAN/LT/030',
--   'LOAN/LT/031','LOAN/LT/032','LOAN/ST/003','LOAN/LT/033')
-- GROUP BY l.loan_reference
-- ORDER BY l.loan_reference;
--
-- V4. Peter has two loans
-- SELECT loan_reference, principal_amount, total_repayable, total_repaid,
--        (total_repayable - total_repaid) AS outstanding
-- FROM loans WHERE member_id = (SELECT id FROM members WHERE registration_number='0032')
-- ORDER BY disbursed_at;
--
-- V5. Total counts
-- SELECT 'loans' AS tbl, COUNT(*) FROM loans
-- UNION ALL SELECT 'schedule', COUNT(*) FROM loan_repayment_schedule
-- ORDER BY tbl;
-- Expected: loans = 46, schedule = 909
-- ============================================================