-- ============================================================
-- Loan interest: two-tier flat rates, fee in first instalment
-- ============================================================
-- Committee rules (confirmed 2026-09-23):
--   1. Two-tier interest retained (Bye-law §43, SRS FR-4.4):
--        covered portion (≤ savings) × normal_rate ÷ 100
--        surplus portion (> savings) × surplus_rate ÷ 100
--      Rates are FLAT charges, not annualised.
--   2. Total Repayable = Principal + Interest   (fee excluded)
--   3. Application fee (N2,000) is added to the FIRST instalment only
--   4. Terms follow the bye-laws:
--        Long-Term            -> 24 months
--        Short-Term           ->  6 months (10 if > N300,000)  (§46a, §46e)
--        Emergency            ->  6 months (10 if > N300,000)  (§46b, §46e)
--        Essential Commodity  -> 10 months                     (§47)
-- ============================================================

-- ---------- 1. Term derivation (unchanged) ----------
CREATE OR REPLACE FUNCTION public.derive_loan_term(
  p_product_name text,
  p_principal numeric
) RETURNS integer
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_product_name = 'Long-Term' THEN 24
    WHEN p_product_name IN ('Short-Term', 'Emergency') THEN
      CASE WHEN p_principal > 300000 THEN 10 ELSE 6 END
    WHEN p_product_name = 'Essential Commodity' THEN 10
    ELSE 12
  END;
$$;

-- ---------- 2. calculate_loan_terms ----------
DROP FUNCTION IF EXISTS public.calculate_loan_terms(uuid, uuid, numeric, integer);
DROP FUNCTION IF EXISTS public.calculate_loan_terms(uuid, uuid, numeric);

CREATE OR REPLACE FUNCTION public.calculate_loan_terms(
  p_member_id uuid,
  p_loan_product_id uuid,
  p_principal numeric
) RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_savings numeric(12,2);
  v_normal numeric(5,2); v_surplus_rate numeric(5,2); v_fee numeric(12,2);
  v_name text;
  v_term integer;
  v_covered numeric(12,2); v_surplus_pr numeric(12,2);
  v_i1 numeric(12,2); v_i2 numeric(12,2); v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
  v_first_instalment numeric(12,2);
BEGIN
  IF app_member_id() IS DISTINCT FROM p_member_id
     AND app_role() NOT IN ('Treasurer','Chairman','Secretary','LoanCommittee','ManagementCommittee','SystemAdmin') THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;
  IF p_principal <= 0 THEN RAISE EXCEPTION 'Principal must be greater than zero'; END IF;

  SELECT get_member_savings_balance(p_member_id) INTO v_savings;

  SELECT name, normal_interest_rate, surplus_interest_rate, application_fee
  INTO v_name, v_normal, v_surplus_rate, v_fee
  FROM loan_products WHERE id = p_loan_product_id AND is_active = true;

  IF v_name IS NULL THEN RAISE EXCEPTION 'Loan product not found or inactive'; END IF;

  v_term := public.derive_loan_term(v_name, p_principal);

  -- Two-tier split
  v_covered := least(p_principal, v_savings);
  v_surplus_pr := greatest(0, p_principal - v_savings);

  -- Flat rates on each tier (no /12 multiplication)
  v_i1 := round(v_covered * (v_normal / 100), 2);
  v_i2 := round(v_surplus_pr * (v_surplus_rate / 100), 2);
  v_total_i := v_i1 + v_i2;

  -- Total repayable excludes fee
  v_total := p_principal + v_total_i;
  v_monthly := round(v_total / v_term, 2);
  v_first_instalment := v_monthly + v_fee;

  RETURN jsonb_build_object(
    'product', v_name,
    'savings_balance', v_savings,
    'covered_principal', v_covered,
    'surplus_principal', v_surplus_pr,
    'normal_rate', v_normal,
    'surplus_rate', v_surplus_rate,
    'interest_covered', v_i1,
    'interest_surplus', v_i2,
    'total_interest', v_total_i,
    'application_fee', v_fee,
    'total_repayable', v_total,
    'monthly_instalment', v_monthly,
    'first_instalment', v_first_instalment,
    'term_months', v_term
  );
END;
$function$;

-- ---------- 3. submit_loan_application ----------
DROP FUNCTION IF EXISTS public.submit_loan_application(uuid, uuid, numeric, integer, text, text);
DROP FUNCTION IF EXISTS public.submit_loan_application(uuid, uuid, numeric, text, text);

CREATE OR REPLACE FUNCTION public.submit_loan_application(
  p_member_id uuid,
  p_loan_product_id uuid,
  p_principal numeric,
  p_purpose text DEFAULT NULL::text,
  p_application_notes text DEFAULT NULL::text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_status text;
  v_id uuid;
  v_product loan_products%ROWTYPE;
  v_savings numeric(12,2);
  v_covered numeric(12,2);
  v_surplus numeric(12,2);
  v_i1 numeric(12,2);
  v_i2 numeric(12,2);
  v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
  v_term integer;
BEGIN
  IF p_member_id IS NULL THEN RAISE EXCEPTION 'Member ID is required'; END IF;

  SELECT status INTO v_status FROM members WHERE id = p_member_id;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;
  IF v_status <> 'Active' THEN
    RAISE EXCEPTION 'Only Active members may apply for loans. Current status: %', v_status;
  END IF;

  SELECT * INTO v_product FROM loan_products
  WHERE id = p_loan_product_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loan product not found or inactive'; END IF;

  IF p_principal <= 0 THEN RAISE EXCEPTION 'Principal must be greater than zero'; END IF;

  v_term := public.derive_loan_term(v_product.name, p_principal);

  -- Frozen savings snapshot taken at application
  v_savings := get_member_savings_balance(p_member_id);
  v_covered := LEAST(p_principal, v_savings);
  v_surplus := GREATEST(p_principal - v_savings, 0);

  -- Flat rate on each tier
  v_i1 := ROUND(v_covered * (v_product.normal_interest_rate / 100), 2);
  v_i2 := ROUND(v_surplus * (v_product.surplus_interest_rate / 100), 2);
  v_total_i := v_i1 + v_i2;
  v_total := p_principal + v_total_i;
  v_monthly := ROUND(v_total / v_term, 2);

  INSERT INTO loans(
    member_id, loan_product_id, principal_amount,
    member_savings_at_disbursement,
    covered_principal, surplus_principal,
    normal_interest_applied, surplus_interest_applied, total_interest,
    application_fee_charged, total_repayable, monthly_instalment,
    term_months, application_notes, purpose, status
  ) VALUES (
    p_member_id, p_loan_product_id, p_principal,
    v_savings,
    v_covered, v_surplus,
    v_i1, v_i2, v_total_i,
    v_product.application_fee, v_total, v_monthly,
    v_term, p_application_notes, p_purpose, 'Pending'
  )
  RETURNING id INTO v_id;

  PERFORM write_audit('SUBMIT_LOAN_APPLICATION','loan',v_id,
    jsonb_build_object(
      'principal', p_principal,
      'term_months', v_term,
      'savings_snapshot', v_savings,
      'covered_principal', v_covered,
      'surplus_principal', v_surplus,
      'interest_covered', v_i1,
      'interest_surplus', v_i2,
      'total_interest', v_total_i,
      'total_repayable', v_total,
      'monthly_instalment', v_monthly
    ));

  PERFORM queue_notification(
    p_member_id, 'PENDING_QUEUE',
    'Loan application submitted',
    'Your loan application has been submitted to the Loan Committee for review.',
    jsonb_build_object('loan_id', v_id)
  );

  RETURN v_id;
END;
$function$;

-- ---------- 4. record_committee_decision ----------
CREATE OR REPLACE FUNCTION public.record_committee_decision(
  p_loan_id uuid,
  p_recorded_by uuid,
  p_decision text,
  p_amount_approved numeric,
  p_interest_rate numeric,
  p_repayment_months integer,
  p_committee_members_present uuid[],
  p_decision_reason text,
  p_notes text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_loan record;
  v_product loan_products%ROWTYPE;
  v_recorder_role text;
  v_decision_id uuid;
  v_member_count integer;
  v_accepted_sureties integer;
  v_savings_snapshot numeric(12,2);
  v_term integer;
  v_covered numeric(12,2);
  v_surplus numeric(12,2);
  v_i1 numeric(12,2);
  v_i2 numeric(12,2);
  v_total_i numeric(12,2);
  v_total numeric(12,2);
  v_monthly numeric(12,2);
BEGIN
  SELECT id, status, loan_product_id, member_savings_at_disbursement
  INTO v_loan FROM public.loans WHERE id = p_loan_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
  END IF;

  IF v_loan.status <> 'Pending' THEN
    RETURN jsonb_build_object('success', false,
      'error', format('Loan status is %s; only Pending loans can be decided', v_loan.status));
  END IF;

  SELECT role INTO v_recorder_role FROM public.members WHERE id = p_recorded_by;
  IF v_recorder_role NOT IN ('LoanCommitteeChairman', 'SystemAdmin') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Only the Loan Committee Chairman may record a decision');
  END IF;

  SELECT * INTO v_product FROM public.loan_products WHERE id = v_loan.loan_product_id;

  -- §49 sureties must be accepted before deciding
  IF v_product.requires_sureties THEN
    SELECT count(*) INTO v_accepted_sureties
    FROM public.sureties WHERE loan_id = p_loan_id AND status = 'Accepted';
    IF v_accepted_sureties <> v_product.number_of_sureties_required THEN
      RETURN jsonb_build_object('success', false,
        'error', format(
          'Both sureties must accept before the committee can decide (Bye-law §49). Currently %s of %s accepted.',
          v_accepted_sureties, v_product.number_of_sureties_required));
    END IF;
  END IF;

  IF p_decision NOT IN ('Approved', 'Rejected', 'Deferred') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'decision must be Approved, Rejected, or Deferred');
  END IF;

  IF p_committee_members_present IS NULL
     OR array_length(p_committee_members_present, 1) < 3 THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Quorum not met: at least 3 committee members required (Section 33)');
  END IF;
  v_member_count := array_length(p_committee_members_present, 1);

  IF p_decision = 'Approved' THEN
    IF p_amount_approved IS NULL OR p_amount_approved <= 0 THEN
      RETURN jsonb_build_object('success', false,
        'error', 'amount_approved required for approved loans');
    END IF;
    IF p_interest_rate IS NULL OR p_interest_rate > 10 THEN
      RETURN jsonb_build_object('success', false,
        'error', 'interest_rate required and must not exceed 10% p.a. (Section 43a)');
    END IF;
  END IF;

  INSERT INTO public.loan_committee_decisions (
    loan_id, decision, decision_reason, notes,
    amount_approved, interest_rate, repayment_months,
    committee_members_present, quorum_met, recorded_by
  ) VALUES (
    p_loan_id, p_decision, p_decision_reason, p_notes,
    p_amount_approved, p_interest_rate,
    CASE WHEN p_decision = 'Approved'
         THEN public.derive_loan_term(v_product.name, p_amount_approved)
         ELSE NULL END,
    p_committee_members_present, true, p_recorded_by
  ) RETURNING id INTO v_decision_id;

  IF p_decision = 'Approved' THEN
    -- Recalculate using the FROZEN savings snapshot
    v_savings_snapshot := v_loan.member_savings_at_disbursement;
    v_term := public.derive_loan_term(v_product.name, p_amount_approved);

    v_covered := LEAST(p_amount_approved, v_savings_snapshot);
    v_surplus := GREATEST(p_amount_approved - v_savings_snapshot, 0);

    -- Two-tier flat interest at the committee-approved rate
    v_i1 := ROUND(v_covered * (p_interest_rate / 100), 2);
    v_i2 := ROUND(v_surplus * (v_product.surplus_interest_rate / 100), 2);
    v_total_i := v_i1 + v_i2;
    v_total := p_amount_approved + v_total_i;
    v_monthly := ROUND(v_total / v_term, 2);

    UPDATE public.loans SET
      principal_amount = p_amount_approved,
      covered_principal = v_covered,
      surplus_principal = v_surplus,
      normal_interest_applied = v_i1,
      surplus_interest_applied = v_i2,
      total_interest = v_total_i,
      total_repayable = v_total,
      monthly_instalment = v_monthly,
      term_months = v_term,
      application_fee_charged = v_product.application_fee,
      status = 'Approved',
      approved_at = now(),
      approved_by = p_recorded_by,
      updated_at = now()
    WHERE id = p_loan_id;

  ELSIF p_decision = 'Rejected' THEN
    UPDATE public.loans SET
      status = 'Closed',
      closed_at = now(),
      closed_reason = COALESCE(p_decision_reason, 'Rejected by Loan Committee'),
      approved_by = p_recorded_by,
      approved_at = now(),
      updated_at = now()
    WHERE id = p_loan_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'decision_id', v_decision_id,
    'decision', p_decision,
    'quorum_met', true,
    'committee_members_count', v_member_count
  );
END;
$function$;

-- ---------- 5. disburse_loan (fee in first instalment) ----------
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
  v_recorder uuid := COALESCE(p_recorder_id, app_member_id());
  v_sign1 uuid;
  v_sign2 uuid;
  i integer;
  v_due date;
  v_first_due date;
  v_last numeric(12,2);
  v_first_amount numeric(12,2);
  v_ledger uuid;
  v_fee numeric(12,2);
BEGIN
  IF app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Only Treasurer/SystemAdmin may execute loan disbursement';
  END IF;

  SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loan not found'; END IF;
  IF l.status <> 'Approved' THEN RAISE EXCEPTION 'Only approved loans may be disbursed'; END IF;

  SELECT * INTO p FROM loan_products WHERE id = l.loan_product_id;

  IF p.requires_sureties
     AND (SELECT count(*) FROM sureties WHERE loan_id = l.id AND status = 'Accepted')
         <> p.number_of_sureties_required THEN
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

  IF v_recorder IS NULL THEN RAISE EXCEPTION 'Recorder is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM members WHERE id = v_recorder) THEN
    RAISE EXCEPTION 'Recorder must be a valid member';
  END IF;

  PERFORM 1 FROM members WHERE id = l.member_id FOR UPDATE;

  v_first_due := (
    date_trunc('month', current_date) + interval '1 month' + interval '9 days'
  )::date;

  UPDATE loans SET
    next_payment_due_date = v_first_due,
    status = 'Active',
    recorder_id = v_recorder,
    disbursed_by = v_recorder,
    disbursed_at = now(),
    updated_at = now()
  WHERE id = l.id;

  v_fee := l.application_fee_charged;
  v_first_amount := l.monthly_instalment + v_fee;

  v_last := ROUND(l.total_repayable - l.monthly_instalment * (l.term_months - 1), 2);

  FOR i IN 1..l.term_months LOOP
    v_due := (
      date_trunc('month', current_date)
      + (i || ' month')::interval
      + interval '9 days'
    )::date;

    INSERT INTO loan_repayment_schedule (loan_id, instalment_number, due_date, scheduled_amount)
    VALUES (
      l.id,
      i,
      v_due,
      CASE
        WHEN i = 1 THEN v_first_amount
        WHEN i = l.term_months THEN v_last
        ELSE l.monthly_instalment
      END
    );
  END LOOP;

  INSERT INTO ledger_entries (
    member_id, loan_id, transaction_type, amount, source, status,
    approved_by, approved_at, allocation_notes
  ) VALUES (
    l.member_id, l.id, 'LOAN_DISBURSEMENT', l.principal_amount,
    'SYSTEM', 'Approved', v_recorder, now(),
    'Loan principal disbursed; two-tier interest capitalised; application fee collected with first instalment'
  ) RETURNING id INTO v_ledger;

  PERFORM write_audit('DISBURSE_LOAN', 'loan', l.id, jsonb_build_object(
    'principal', l.principal_amount,
    'savings_snapshot', l.member_savings_at_disbursement,
    'covered_principal', l.covered_principal,
    'surplus_principal', l.surplus_principal,
    'interest_covered', l.normal_interest_applied,
    'interest_surplus', l.surplus_interest_applied,
    'total_interest', l.total_interest,
    'total_repayable', l.total_repayable,
    'monthly_instalment', l.monthly_instalment,
    'first_instalment_amount', v_first_amount,
    'application_fee', v_fee,
    'term_months', l.term_months,
    'first_due_date', v_first_due,
    'signatory_1', v_sign1,
    'signatory_2', v_sign2,
    'recorder', v_recorder,
    'ledger_entry', v_ledger
  ));

  PERFORM queue_notification(
    l.member_id, 'LOAN_DISBURSEMENT', 'Loan disbursed',
    'Your loan has been disbursed. Monthly instalment: N' ||
      to_char(l.monthly_instalment, 'FM999,999,990.00') ||
      ' for ' || l.term_months || ' months. ' ||
      'First payment of N' || to_char(v_first_amount, 'FM999,999,990.00') ||
      ' (includes N' || to_char(v_fee, 'FM999,999,990.00') ||
      ' application fee) is due ' || to_char(v_first_due, 'DD Mon YYYY') || '.',
    jsonb_build_object(
      'loan_id', l.id,
      'monthly_instalment', l.monthly_instalment,
      'first_instalment', v_first_amount,
      'application_fee', v_fee,
      'term_months', l.term_months,
      'first_due_date', v_first_due
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'loan_id', l.id,
    'total_repayable', l.total_repayable,
    'monthly_instalment', l.monthly_instalment,
    'first_instalment', v_first_amount,
    'first_due_date', v_first_due
  );
END;
$function$;

NOTIFY pgrst, 'reload schema';