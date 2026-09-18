-- ============================================================
-- Loan Committee Decisions + Trustee Sign-off workflow
-- ============================================================
-- Adds:
--   1. loan_committee_decisions table (append-only)
--   2. record_committee_decision() RPC
--   3. Replacement record_loan_trustee_signoff() RPC with
--      server-derived slot (no client-supplied signoff_number)
--
-- Bye-laws referenced:
--   Section 27    Trustees
--   Section 33-34 Loan Committee composition and duties
--   Section 43(a) Interest rate cap (<= 10% p.a.)
--   Section 48    Long-term repayment period cap (<= 24 months)
--   Section 55(d) Trustee sign-off on disbursements
-- ============================================================

-- ---------- 1. Committee decisions table ----------

CREATE TABLE IF NOT EXISTS public.loan_committee_decisions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id uuid NOT NULL REFERENCES public.loans(id) ON DELETE RESTRICT,

  decision text NOT NULL CHECK (decision IN ('Approved', 'Rejected', 'Deferred')),
  decision_reason text,
  notes text,

  amount_approved numeric(14,2)
    CHECK (amount_approved IS NULL OR amount_approved > 0),
  interest_rate numeric(5,2)
    CHECK (interest_rate IS NULL OR (interest_rate >= 0 AND interest_rate <= 10)),
  repayment_months integer
    CHECK (repayment_months IS NULL OR (repayment_months > 0 AND repayment_months <= 24)),

  committee_members_present uuid[] NOT NULL
    CHECK (array_length(committee_members_present, 1) >= 3),
  quorum_met boolean NOT NULL DEFAULT true,

  recorded_by uuid NOT NULL REFERENCES public.members(id),
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_committee_decisions_loan_id
  ON public.loan_committee_decisions (loan_id);

CREATE INDEX IF NOT EXISTS idx_committee_decisions_recorded_at
  ON public.loan_committee_decisions (recorded_at DESC);

-- A loan can only have one terminal decision. Deferred can stack.
CREATE UNIQUE INDEX IF NOT EXISTS uniq_committee_decision_terminal
  ON public.loan_committee_decisions (loan_id)
  WHERE decision IN ('Approved', 'Rejected');

COMMENT ON TABLE public.loan_committee_decisions IS
  'Append-only record of Loan Committee decisions. Bye-law Sections 33-34.';

-- ---------- 2. record_committee_decision RPC ----------

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
AS $$
DECLARE
  v_loan record;
  v_recorder_role text;
  v_decision_id uuid;
  v_member_count integer;
BEGIN
  SELECT id, status INTO v_loan
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
$$;

GRANT EXECUTE ON FUNCTION public.record_committee_decision(
  uuid, uuid, text, numeric, numeric, integer, uuid[], text, text
) TO authenticated;

-- ---------- 3. record_loan_trustee_signoff (replacement) ----------

-- Drop the old two-argument signature (client-supplied signoff_number).
DROP FUNCTION IF EXISTS public.record_loan_trustee_signoff(uuid, integer);

CREATE OR REPLACE FUNCTION public.record_loan_trustee_signoff(
  p_loan_id uuid,
  p_trustee_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_loan record;
  v_trustee_role text;
  v_slot integer;
BEGIN
  SELECT id, status, trustee_signoff_1, trustee_signoff_2
  INTO v_loan FROM public.loans WHERE id = p_loan_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Loan not found');
  END IF;

  IF v_loan.status <> 'Approved' THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Loan must be Approved by the Committee first');
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
$$;

GRANT EXECUTE ON FUNCTION public.record_loan_trustee_signoff(uuid, uuid)
  TO authenticated;

COMMENT ON FUNCTION public.record_loan_trustee_signoff(uuid, uuid) IS
  'Records one trustee sign-off on an Approved loan. Slot is server-derived. Bye-law Sections 27, 55(d).';