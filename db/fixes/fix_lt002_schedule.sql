-- Correct LT/002 schedule to reconcile with loans.total_repaid.
-- The main migration flipped row 17 to Paid but the resulting schedule
-- sum exceeded total_repaid by N3,262.50. Rebuild the schedule cleanly.

DO $$
DECLARE
  v_loan        loans%ROWTYPE;
  v_derived     numeric(12,2);
  v_paid_full   int;
  v_remainder   numeric(12,2);
  v_i           int;
BEGIN
  SELECT * INTO v_loan FROM loans WHERE loan_reference='LOAN/LT/002' FOR UPDATE;
  IF v_loan.id IS NULL THEN RAISE EXCEPTION 'LOAN/LT/002 not found'; END IF;

  v_derived   := (v_loan.total_repayable / v_loan.term_months)::numeric(12,2);
  v_paid_full := floor(v_loan.total_repaid / v_derived);
  v_remainder := v_loan.total_repaid - (v_paid_full * v_derived);

  -- Reset all schedule rows
  UPDATE loan_repayment_schedule
  SET amount_paid = 0, status = 'Pending', paid_at = NULL, updated_at = now()
  WHERE loan_id = v_loan.id;

  -- Restore full-paid rows
  FOR v_i IN 1..v_paid_full LOOP
    UPDATE loan_repayment_schedule
    SET amount_paid = scheduled_amount,
        status = 'Paid',
        paid_at = due_date::timestamptz,
        updated_at = now()
    WHERE loan_id = v_loan.id AND instalment_number = v_i;
  END LOOP;

  -- Restore the partially-paid row
  IF v_remainder > 0.005 THEN
    UPDATE loan_repayment_schedule
    SET amount_paid = v_remainder,
        status = 'Partially Paid',
        updated_at = now()
    WHERE loan_id = v_loan.id AND instalment_number = v_paid_full + 1;
  END IF;

  -- Recompute instalments_paid and next due
  UPDATE loans
  SET instalments_paid = v_paid_full,
      next_payment_due_date = (
        SELECT min(due_date) FROM loan_repayment_schedule
        WHERE loan_id = v_loan.id AND amount_paid < scheduled_amount
      ),
      updated_at = now()
  WHERE id = v_loan.id;

  PERFORM write_audit(
    'RECONCILE_SCHEDULE', 'loan', v_loan.id,
    jsonb_build_object(
      'loan_reference', 'LOAN/LT/002',
      'reason', 'Correct schedule sum vs total_repaid mismatch (N3,262.50)',
      'paid_full', v_paid_full,
      'partial_amount', v_remainder
    )
  );
END $$;