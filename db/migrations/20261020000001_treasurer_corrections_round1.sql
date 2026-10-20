-- ============================================================
-- Treasurer corrections — round 1
-- ============================================================
-- Applied per Treasurer email, 2026-10-20:
--   1. Savings corrections (Olusola, Lucy, Ruth) via
--      reversal-and-reinsert (ledger_entries is append-only)
--   2. Loan repayment corrections for LT/002 and LT/024
--   3. Two missed loans for Maryam Sulaiman (Emergency + Short-term)
--
-- All changes audited via write_audit. Approved by Treasurer member 0004.
-- ============================================================

BEGIN;

-- ---------- A. Savings corrections ----------
-- For each member: reverse the original opening balance, then
-- re-insert a corrected opening balance. The original entry remains
-- visible in the ledger for the audit trail.

DO $$
DECLARE
  v_member_id     uuid;
  v_treasurer_id  uuid;
  v_original      ledger_entries%ROWTYPE;
  v_reg           text;
  v_old_amount    numeric(12,2);
  v_new_amount    numeric(12,2);
  v_corrections   jsonb := '[
    {"reg":"0008","new":4129109.00},
    {"reg":"0029","new":2424825.00},
    {"reg":"0050","new":455500.00}
  ]'::jsonb;
  c               jsonb;
BEGIN
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';

  FOR c IN SELECT * FROM jsonb_array_elements(v_corrections) LOOP
    v_reg := c->>'reg';
    v_new_amount := (c->>'new')::numeric;

    SELECT id INTO v_member_id FROM members WHERE registration_number = v_reg;

    SELECT * INTO v_original
    FROM ledger_entries
    WHERE member_id = v_member_id
      AND transaction_type = 'CONTRIBUTION'
      AND allocation_notes LIKE 'Historical savings brought forward%'
      AND parent_ledger_entry_id IS NULL
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_original.id IS NULL THEN
      RAISE EXCEPTION 'No opening balance found for member %', v_reg;
    END IF;

    v_old_amount := v_original.amount;

    -- REVERSAL of the original opening
    INSERT INTO ledger_entries (
      member_id, transaction_type, amount, source, status,
      approved_by, approved_at, parent_ledger_entry_id,
      reversal_reason, reversal_approved_by, allocation_notes
    ) VALUES (
      v_member_id, 'REVERSAL', v_old_amount, 'SYSTEM', 'Approved',
      v_treasurer_id, now(), v_original.id,
      format('Treasurer correction 2026-10-20: historical savings discrepancy (reg %s)', v_reg),
      v_treasurer_id,
      format('Reversal of original opening balance N%s', v_old_amount)
    );

    -- New CORRECTED opening
    INSERT INTO ledger_entries (
      member_id, transaction_type, amount, source, status,
      approved_by, approved_at, allocation_notes
    ) VALUES (
      v_member_id, 'CONTRIBUTION', v_new_amount, 'SYSTEM', 'Approved',
      v_treasurer_id, now(),
      format('Historical savings brought forward — correction (Treasurer, 2026-10-20): was N%s, now N%s',
             v_old_amount, v_new_amount)
    );

    PERFORM write_audit(
      'TREASURER_CORRECTION_SAVINGS',
      'member', v_member_id,
      jsonb_build_object(
        'registration_number', v_reg,
        'old_savings', v_old_amount,
        'new_savings', v_new_amount,
        'delta', v_new_amount - v_old_amount,
        'reason', 'Treasurer email 2026-10-20'
      ),
      v_treasurer_id
    );
  END LOOP;
END $$;

-- ---------- B. Loan corrections: LT/002 and LT/024 ----------

-- B1. LT/002 — additional ₦100,000 repaid
DO $$
DECLARE
  v_loan          loans%ROWTYPE;
  v_treasurer_id  uuid;
  v_delta         numeric(12,2) := 100000.00;
  v_new_repaid    numeric(12,2);
  v_derived       numeric(12,2);
  v_paid_full     int;
  v_remainder     numeric(12,2);
  v_i             int;
BEGIN
  SELECT * INTO v_loan FROM loans WHERE loan_reference='LOAN/LT/002' FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'LOAN/LT/002 not found'; END IF;
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';

  v_new_repaid := v_loan.total_repaid + v_delta;
  v_derived    := (v_loan.total_repayable / v_loan.term_months)::numeric(12,2);
  v_paid_full  := floor(v_new_repaid / v_derived);
  v_remainder  := v_new_repaid - (v_paid_full * v_derived);

  -- Ledger entry for the additional repayment
  INSERT INTO ledger_entries (
    member_id, loan_id, transaction_type, amount, transaction_date,
    source, status, approved_by, approved_at, allocation_notes
  ) VALUES (
    v_loan.member_id, v_loan.id, 'LOAN_REPAYMENT', v_delta, CURRENT_DATE,
    'SYSTEM', 'Approved', v_treasurer_id, now(),
    format('Historical repayment correction (Treasurer, 2026-10-20): bringing total_repaid from N%s to N%s',
           v_loan.total_repaid, v_new_repaid)
  );

  -- Reset schedule, then rebuild from new_repaid
  UPDATE loan_repayment_schedule
  SET amount_paid = 0, status = 'Pending', paid_at = NULL, updated_at = now()
  WHERE loan_id = v_loan.id;

  FOR v_i IN 1..v_paid_full LOOP
    UPDATE loan_repayment_schedule
    SET amount_paid = scheduled_amount,
        status = 'Paid',
        paid_at = due_date::timestamptz,
        updated_at = now()
    WHERE loan_id = v_loan.id AND instalment_number = v_i;
  END LOOP;

  IF v_remainder > 0.005 THEN
    UPDATE loan_repayment_schedule
    SET amount_paid = v_remainder,
        status = 'Partially Paid',
        updated_at = now()
    WHERE loan_id = v_loan.id AND instalment_number = v_paid_full + 1;
  END IF;

  UPDATE loans
  SET total_repaid = v_new_repaid,
      instalments_paid = v_paid_full,
      next_payment_due_date = (
        SELECT min(due_date) FROM loan_repayment_schedule
        WHERE loan_id = v_loan.id AND amount_paid < scheduled_amount
      ),
      updated_at = now()
  WHERE id = v_loan.id;

  PERFORM write_audit(
    'TREASURER_CORRECTION_LOAN_REPAID', 'loan', v_loan.id,
    jsonb_build_object(
      'loan_reference', 'LOAN/LT/002',
      'old_repaid', v_loan.total_repaid,
      'new_repaid', v_new_repaid,
      'delta', v_delta,
      'paid_full_after', v_paid_full,
      'partial_after', v_remainder,
      'reason', 'Treasurer email 2026-10-20'
    ),
    v_treasurer_id
  );
END $$;

-- B2. LT/024 — additional ₦21,875 repaid (exactly one more instalment)
DO $$
DECLARE
  v_loan          loans%ROWTYPE;
  v_treasurer_id  uuid;
  v_delta         numeric(12,2) := 21875.00;
  v_new_repaid    numeric(12,2);
  v_row           loan_repayment_schedule%ROWTYPE;
BEGIN
  SELECT * INTO v_loan FROM loans WHERE loan_reference='LOAN/LT/024' FOR UPDATE;
  IF v_loan.id IS NULL THEN
    RAISE EXCEPTION 'LOAN/LT/024 not found';
  END IF;
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';

  v_new_repaid := v_loan.total_repaid + v_delta;

  INSERT INTO ledger_entries (
    member_id, loan_id, transaction_type, amount, transaction_date,
    source, status, approved_by, approved_at, allocation_notes
  ) VALUES (
    v_loan.member_id, v_loan.id, 'LOAN_REPAYMENT', v_delta, CURRENT_DATE,
    'SYSTEM', 'Approved', v_treasurer_id, now(),
    format('Historical repayment correction (Treasurer, 2026-10-20): bringing total_repaid from N%s to N%s',
           v_loan.total_repaid, v_new_repaid)
  );

  SELECT * INTO v_row FROM loan_repayment_schedule
  WHERE loan_id = v_loan.id AND amount_paid < scheduled_amount
  ORDER BY instalment_number ASC LIMIT 1 FOR UPDATE;

  IF v_row.id IS NOT NULL THEN
    UPDATE loan_repayment_schedule
    SET amount_paid = v_row.scheduled_amount,
        status = 'Paid',
        paid_at = v_row.due_date::timestamptz,
        updated_at = now()
    WHERE id = v_row.id;
  END IF;

  UPDATE loans
  SET total_repaid = v_new_repaid,
      instalments_paid = (SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=v_loan.id AND status='Paid'),
      next_payment_due_date = (SELECT min(due_date) FROM loan_repayment_schedule WHERE loan_id=v_loan.id AND amount_paid<scheduled_amount),
      updated_at = now()
  WHERE id = v_loan.id;

  PERFORM write_audit(
    'TREASURER_CORRECTION_LOAN_REPAID',
    'loan', v_loan.id,
    jsonb_build_object(
      'loan_reference', 'LOAN/LT/024',
      'old_repaid', v_loan.total_repaid,
      'new_repaid', v_new_repaid,
      'delta', v_delta,
      'reason', 'Treasurer email 2026-10-20'
    ),
    v_treasurer_id
  );
END $$;

-- ---------- C. Maryam Sulaiman — insert 2 missed loans ----------

DO $$
DECLARE
  v_member_id     uuid;
  v_treasurer_id  uuid;
  v_loan_id       uuid;
  v_product_id    uuid;
  v_disbursement  date;
  v_principal     numeric(12,2);
  v_interest      numeric(12,2);
  v_repayable     numeric(12,2);
  v_monthly       numeric(12,2);
  v_paid_total    numeric(12,2);
  v_paid_full     int;
  v_partial       numeric(12,2);
  v_i             int;
  v_due           date;
  v_loan_specs    jsonb := '[
    {"ref":"LOAN/EM/009","product":"Emergency","disbursement":"2024-10-10","principal":150000,"interest":15000,"repayable":165000,"monthly":16500,"paid_total":149500,"paid_full":9,"partial":1000},
    {"ref":"LOAN/ST/002","product":"Short-Term","disbursement":"2025-05-30","principal":150000,"interest":15000,"repayable":165000,"monthly":16500,"paid_total":66000,"paid_full":4,"partial":0}
  ]'::jsonb;
  c               jsonb;
BEGIN
  SELECT id INTO v_member_id FROM members WHERE registration_number='0040';
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';

  FOR c IN SELECT * FROM jsonb_array_elements(v_loan_specs) LOOP
    v_disbursement := (c->>'disbursement')::date;
    v_principal    := (c->>'principal')::numeric;
    v_interest     := (c->>'interest')::numeric;
    v_repayable    := (c->>'repayable')::numeric;
    v_monthly      := (c->>'monthly')::numeric;
    v_paid_total   := (c->>'paid_total')::numeric;
    v_paid_full    := (c->>'paid_full')::int;
    v_partial      := COALESCE((c->>'partial')::numeric, 0);

    SELECT id INTO v_product_id FROM loan_products WHERE name = (c->>'product');

    IF v_product_id IS NULL THEN
      RAISE EXCEPTION 'Loan product not found: % (check exact name/casing)',
        (c->>'product');
    END IF;


    -- Insert loan
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
      c->>'ref', v_member_id, v_product_id,
      v_principal, 0,
      v_principal, 0,
      v_interest, 0, v_interest,
      0, v_repayable, v_monthly,
      10, v_paid_total, v_paid_full,
      NULL, 'Active',
      v_disbursement, v_disbursement::timestamptz, v_disbursement::timestamptz,
      v_disbursement::timestamptz, now(),
      'Missed during initial migration; added per Treasurer email 2026-10-20'
    ) RETURNING id INTO v_loan_id;

    -- Insert 10-row schedule
    FOR v_i IN 1..10 LOOP
      v_due := (v_disbursement + (v_i || ' months')::interval)::date;

      INSERT INTO loan_repayment_schedule (
        loan_id, instalment_number, due_date, scheduled_amount,
        amount_paid, status, paid_at
      ) VALUES (
        v_loan_id, v_i, v_due, v_monthly,
        CASE
          WHEN v_i <= v_paid_full THEN v_monthly
          WHEN v_i = v_paid_full + 1 AND v_partial > 0 THEN v_partial
          ELSE 0
        END,
        CASE
          WHEN v_i <= v_paid_full THEN 'Paid'
          WHEN v_i = v_paid_full + 1 AND v_partial > 0 THEN 'Partially Paid'
          ELSE 'Pending'
        END,
        CASE
          WHEN v_i <= v_paid_full THEN v_due::timestamptz
          ELSE NULL
        END
      );
    END LOOP;

    -- Set next_payment_due_date from schedule
    UPDATE loans SET
      next_payment_due_date = (SELECT min(due_date) FROM loan_repayment_schedule WHERE loan_id=v_loan_id AND amount_paid<scheduled_amount),
      updated_at = now()
    WHERE id = v_loan_id;

    -- Historical LOAN_DISBURSEMENT ledger entry
    INSERT INTO ledger_entries (
      member_id, loan_id, transaction_type, amount, transaction_date,
      source, status, approved_by, approved_at, allocation_notes
    ) VALUES (
      v_member_id, v_loan_id, 'LOAN_DISBURSEMENT', v_principal, v_disbursement,
      'SYSTEM', 'Approved', v_treasurer_id, now(),
      'Historical loan disbursement (migrated from paper ledger, Treasurer email 2026-10-20)'
    );

    -- Historical LOAN_REPAYMENT aggregate ledger entry
    INSERT INTO ledger_entries (
      member_id, loan_id, transaction_type, amount, transaction_date,
      source, status, approved_by, approved_at, allocation_notes
    ) VALUES (
      v_member_id, v_loan_id, 'LOAN_REPAYMENT', v_paid_total,
      (v_disbursement + interval '9 months')::date,
      'SYSTEM', 'Approved', v_treasurer_id, now(),
      format('Historical repayment aggregate (migrated): %s full + N%s partial', v_paid_full, v_partial)
    );

    PERFORM write_audit(
      'MIGRATION_LOAN_ADDED',
      'loan', v_loan_id,
      jsonb_build_object(
        'loan_reference', c->>'ref',
        'member_registration', '0040',
        'product', c->>'product',
        'disbursement_date', v_disbursement,
        'principal', v_principal,
        'repayable', v_repayable,
        'repaid', v_paid_total,
        'reason', 'Missed during initial migration (Treasurer email 2026-10-20)'
      ),
      v_treasurer_id
    );
  END LOOP;
END $$;

COMMIT;