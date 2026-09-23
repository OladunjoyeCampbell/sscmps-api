-- ============================================================
-- Enforce surety acceptance before committee decision and
-- trustee sign-off. Bye-law Section 49: every loan requires
-- two sureties before it proceeds. Previously only the
-- disburse step checked this, allowing the loan to be
-- approved and signed off with pending sureties.
-- ============================================================

-- ------------------------------------------------------------
-- 1. record_committee_decision — require both sureties first
-- ------------------------------------------------------------
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
BEGIN
  SELECT id, status, loan_product_id INTO v_loan
  FROM public.loans WHERE id = p_loan_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
  END IF;

  IF v_loan.status <> 'Pending' THEN
    RETURN jsonb_build_object('success', false,
      'error', format('Loan status is %s; only Pending loans can be decided', v_loan.status));
  END IF;

  SELECT role INTO v_recorder_role
  FROM public.members WHERE id = p_recorded_by;

  IF v_recorder_role NOT IN ('LoanCommitteeChairman', 'SystemAdmin') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Only the Loan Committee Chairman may record a decision');
  END IF;

  -- NEW: require both sureties accepted before any committee decision
  SELECT * INTO v_product FROM public.loan_products WHERE id = v_loan.loan_product_id;

  IF v_product.requires_sureties THEN
    SELECT count(*) INTO v_accepted_sureties
    FROM public.sureties
    WHERE loan_id = p_loan_id AND status = 'Accepted';

    IF v_accepted_sureties <> v_product.number_of_sureties_required THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format(
          'Both sureties must accept before the committee can decide (Bye-law §49). Currently %s of %s accepted.',
          v_accepted_sureties, v_product.number_of_sureties_required
        )
      );
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
    IF p_interest_rate IS NULL THEN
      RETURN jsonb_build_object('success', false,
        'error', 'interest_rate required for approved loans');
    END IF;
    IF p_interest_rate > 10 THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Interest rate cannot exceed 10% p.a. (Section 43(a))');
    END IF;
    IF p_repayment_months IS NULL OR p_repayment_months <= 0 THEN
      RETURN jsonb_build_object('success', false,
        'error', 'repayment_months required for approved loans');
    END IF;
    IF p_repayment_months > 24 THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Repayment cannot exceed 24 months (Section 48)');
    END IF;
  END IF;

  INSERT INTO public.loan_committee_decisions (
    loan_id, decision, decision_reason, notes,
    amount_approved, interest_rate, repayment_months,
    committee_members_present, quorum_met, recorded_by
  ) VALUES (
    p_loan_id, p_decision, p_decision_reason, p_notes,
    p_amount_approved, p_interest_rate, p_repayment_months,
    p_committee_members_present, true, p_recorded_by
  ) RETURNING id INTO v_decision_id;

  IF p_decision = 'Approved' THEN
    UPDATE public.loans
    SET status = 'Approved',
        approved_at = now(),
        approved_by = p_recorded_by,
        updated_at = now()
    WHERE id = p_loan_id;
  ELSIF p_decision = 'Rejected' THEN
    UPDATE public.loans
    SET status = 'Closed',
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

-- ------------------------------------------------------------
-- 2. record_loan_trustee_signoff — require both sureties first
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_loan_trustee_signoff(
  p_loan_id uuid,
  p_trustee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_loan record;
  v_product loan_products%ROWTYPE;
  v_trustee_role text;
  v_slot integer;
  v_accepted_sureties integer;
BEGIN
  SELECT id, status, trustee_signoff_1, trustee_signoff_2, loan_product_id
  INTO v_loan FROM public.loans WHERE id = p_loan_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
  END IF;

  IF v_loan.status <> 'Approved' THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Loan must be Approved by the Committee first');
  END IF;

  -- NEW: defence in depth — sureties must still be in place
  SELECT * INTO v_product FROM public.loan_products WHERE id = v_loan.loan_product_id;

  IF v_product.requires_sureties THEN
    SELECT count(*) INTO v_accepted_sureties
    FROM public.sureties
    WHERE loan_id = p_loan_id AND status = 'Accepted';

    IF v_accepted_sureties <> v_product.number_of_sureties_required THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', format(
          'Both sureties must accept before trustee sign-off (Bye-law §49). Currently %s of %s accepted.',
          v_accepted_sureties, v_product.number_of_sureties_required
        )
      );
    END IF;
  END IF;

  SELECT role INTO v_trustee_role
  FROM public.members WHERE id = p_trustee_id;

  IF v_trustee_role NOT IN ('Chairman', 'Secretary', 'Treasurer') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Only Chairman, Secretary, or Treasurer may sign off (Section 27)');
  END IF;

  IF v_loan.trustee_signoff_1 = p_trustee_id
     OR v_loan.trustee_signoff_2 = p_trustee_id THEN
    RETURN jsonb_build_object('success', false,
      'error', 'You have already signed off on this loan');
  END IF;

  IF v_loan.trustee_signoff_1 IS NULL THEN
    v_slot := 1;
    UPDATE public.loans
    SET trustee_signoff_1 = p_trustee_id,
        trustee_signoff_1_at = now(),
        updated_at = now()
    WHERE id = p_loan_id;
  ELSIF v_loan.trustee_signoff_2 IS NULL THEN
    v_slot := 2;
    UPDATE public.loans
    SET trustee_signoff_2 = p_trustee_id,
        trustee_signoff_2_at = now(),
        updated_at = now()
    WHERE id = p_loan_id;
  ELSE
    RETURN jsonb_build_object('success', false,
      'error', 'Both trustee signatures are already recorded');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'slot', v_slot,
    'trustee_id', p_trustee_id,
    'trustee_role', v_trustee_role
  );
END;
$function$;