-- ============================================================
-- Loan repayment schedule — due dates on 10th of following month
-- ============================================================
-- Rule (Option A, ratified by Committee):
--   Loan disbursed in month M → instalment 1 covers M and is due
--   on the 10th of month M+1. Subsequent instalments fall on the
--   10th of each following month.
--
-- Example: disbursed 2026-09-18, term 3
--   Inst 1 → 2026-10-10
--   Inst 2 → 2026-11-10
--   Inst 3 → 2026-12-10
-- ============================================================

CREATE OR REPLACE FUNCTION public.disburse_loan(
  p_loan_id uuid,
  p_recorder_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  l loans%ROWTYPE;
  p loan_products%ROWTYPE;
  v_savings numeric(12,2);
  v_covered numeric(12,2);
  v_surplus numeric(12,2);
  v_i1 numeric(12,2);
  v_i2 numeric(12,2);
  v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
  v_recorder uuid := COALESCE(p_recorder_id, app_member_id());
  v_sign1 uuid;
  v_sign2 uuid;
  i integer;
  v_due date;
  v_first_due date;
  v_amount numeric(12,2);
  v_last numeric(12,2);
  v_ledger uuid;
BEGIN
  IF app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Only Treasurer/SystemAdmin may execute loan disbursement';
  END IF;

  SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Loan not found';
  END IF;

  IF l.status <> 'Approved' THEN
    RAISE EXCEPTION 'Only approved loans may be disbursed';
  END IF;

  SELECT * INTO p FROM loan_products WHERE id = l.loan_product_id;

  IF p.requires_sureties
     AND (SELECT count(*) FROM sureties WHERE loan_id = l.id AND status = 'Accepted') <> p.number_of_sureties_required THEN
    RAISE EXCEPTION 'Exactly % accepted sureties are required', p.number_of_sureties_required;
  END IF;

  v_sign1 := l.trustee_signoff_1;
  v_sign2 := l.trustee_signoff_2;

  IF v_sign1 IS NULL OR v_sign2 IS NULL OR v_sign1 = v_sign2 THEN
    RAISE EXCEPTION 'Two different trustee sign-offs are required';
  END IF;

  IF NOT is_trustee(v_sign1) OR NOT is_trustee(v_sign2) THEN
    RAISE EXCEPTION 'Signatories must be Chairman, Secretary or Treasurer';
  END IF;

  IF v_recorder IS NULL THEN
    RAISE EXCEPTION 'Recorder is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM members WHERE id = v_recorder) THEN
    RAISE EXCEPTION 'Recorder must be a valid member';
  END IF;

  PERFORM 1 FROM members WHERE id = l.member_id FOR UPDATE;

  v_savings := get_member_savings_balance(l.member_id);

  v_covered := LEAST(l.principal_amount, v_savings);
  v_surplus := GREATEST(0, l.principal_amount - v_savings);
  v_i1 := ROUND(v_covered * (p.normal_interest_rate / 100) * (l.term_months / 12.0), 2);
  v_i2 := ROUND(v_surplus * (p.surplus_interest_rate / 100) * (l.term_months / 12.0), 2);
  v_total_i := v_i1 + v_i2;
  v_total := l.principal_amount + v_total_i + p.application_fee;
  v_monthly := ROUND(v_total / l.term_months, 2);

  v_first_due := (
    date_trunc('month', current_date)
    + interval '1 month'
    + interval '9 days'
  )::date;

  UPDATE loans SET
    member_savings_at_disbursement = v_savings,
    covered_principal = v_covered,
    surplus_principal = v_surplus,
    normal_interest_applied = v_i1,
    surplus_interest_applied = v_i2,
    total_interest = v_total_i,
    application_fee_charged = p.application_fee,
    total_repayable = v_total,
    monthly_instalment = v_monthly,
    total_repaid = 0,
    instalments_paid = 0,
    next_payment_due_date = v_first_due,
    status = 'Active',
    recorder_id = v_recorder,
    disbursed_by = v_recorder,
    disbursed_at = now()
  WHERE id = l.id;

  v_last := ROUND(v_total - v_monthly * (l.term_months - 1), 2);
  FOR i IN 1..l.term_months LOOP
    v_due := (
      date_trunc('month', current_date)
      + (i || ' month')::interval
      + interval '9 days'
    )::date;
    v_amount := CASE WHEN i = l.term_months THEN v_last ELSE v_monthly END;
    INSERT INTO loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount)
    VALUES (l.id, i, v_due, v_amount);
  END LOOP;

  INSERT INTO ledger_entries (
    member_id, loan_id, transaction_type, amount, source, status,
    approved_by, approved_at, allocation_notes
  )
  VALUES (
    l.member_id, l.id, 'LOAN_DISBURSEMENT', l.principal_amount,
    'SYSTEM', 'Approved', v_recorder, now(),
    'Loan principal disbursed; interest and application fee capitalised into total repayable'
  )
  RETURNING id INTO v_ledger;

  PERFORM write_audit('DISBURSE_LOAN', 'loan', l.id, jsonb_build_object(
    'principal', l.principal_amount,
    'savings_at_disbursement', v_savings,
    'covered_principal', v_covered,
    'surplus_principal', v_surplus,
    'interest_covered', v_i1,
    'interest_surplus', v_i2,
    'total_repayable', v_total,
    'monthly_instalment', v_monthly,
    'first_due_date', v_first_due,
    'signatory_1', v_sign1,
    'signatory_2', v_sign2,
    'recorder', v_recorder,
    'ledger_entry', v_ledger
  ));

  PERFORM queue_notification(
    l.member_id,
    'LOAN_DISBURSEMENT',
    'Loan disbursed',
    'Your loan has been disbursed. Fixed monthly instalment: N' ||
      to_char(v_monthly, 'FM999,999,990.00') || '. Term: ' || l.term_months ||
      ' months. First payment due ' || to_char(v_first_due, 'DD Mon YYYY') || '.',
    jsonb_build_object(
      'loan_id', l.id,
      'monthly_instalment', v_monthly,
      'term_months', l.term_months,
      'first_due_date', v_first_due,
      'schedule', (
        SELECT jsonb_agg(
          jsonb_build_object(
            'instalment_number', s.instalment_number,
            'due_date', s.due_date,
            'amount', s.scheduled_amount
          ) ORDER BY s.instalment_number
        )
        FROM loan_repayment_schedule s WHERE s.loan_id = l.id
      )
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'loan_id', l.id,
    'total_repayable', v_total,
    'monthly_instalment', v_monthly,
    'first_due_date', v_first_due
  );
END;
$function$;