-- ============================================================
-- Payment submissions: optional bank_reference support
-- ============================================================
-- Adds optional bank_reference to member payment submissions.
-- Members can now record the reference from their bank transfer
-- statement, which helps the Treasurer match payments.
--
-- Design decisions:
--
-- 1. bank_reference is OPTIONAL. Many Nigerian payment methods
--    (cash deposit, payroll batch, POS transfer, lost receipts)
--    have no clean reference. Members can submit without it.
--
-- 2. No UNIQUE constraint on bank_reference. Two members might
--    legitimately submit the same reference (e.g. one payroll
--    batch reference covers multiple member transfers). Enforcing
--    uniqueness across members would break real workflows.
--
-- 3. Duplicate check is SCOPED TO THE SAME MEMBER. If a member
--    submits the same reference twice, the second is rejected.
--    This catches accidental re-submissions without penalising
--    two members who happen to share a reference.
--
-- 4. Values are NORMALISED (uppercase, non-alphanumeric stripped)
--    so "TRF/2026/12345", "trf-2026-12345", and "TRF 2026 12345"
--    all normalise to "TRF202612345" and are treated as duplicates.
--
-- 5. The parameter has a DEFAULT of NULL, so the OLD Worker code
--    that calls with 6 arguments continues to work without a
--    bank_reference. Once the Worker is updated to pass the 7th
--    argument, references will be captured.
--
-- DEPLOYMENT ORDER:
--   Step 1 — Apply this migration (existing Worker calls with 6
--            args still work, using default NULL for the 7th).
--   Step 2 — Update Worker route to pass p_bank_reference.
--   Step 3 — Deploy updated frontend.
--
-- Reversal:
--   DROP FUNCTION submit_payment_notification(uuid, numeric, text,
--     text, numeric, jsonb, text);
--   Then re-create the previous 6-argument signature from
--   migration 20260715000000_initial_schema.sql if needed.
-- ============================================================

BEGIN;

-- ---------- 1. Drop the previous signature ----------
-- The Worker and frontend must be updated after this runs so
-- future calls pass p_bank_reference. Until then, calls without
-- the 7th argument still work via the DEFAULT clause below.

DROP FUNCTION IF EXISTS public.submit_payment_notification(
  uuid, numeric, text, text, numeric, jsonb
);

-- ---------- 2. Create the updated function ----------

CREATE OR REPLACE FUNCTION public.submit_payment_notification(
  p_member_id         uuid,
  p_amount            numeric,
  p_payment_reference text    DEFAULT NULL,
  p_evidence_url      text    DEFAULT NULL,
  p_proposed_savings  numeric DEFAULT 0,
  p_proposed_loans    jsonb   DEFAULT '[]'::jsonb,
  p_bank_reference    text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_id                 uuid;
  r                    record;
  v_sum                numeric(12,2) := COALESCE(p_proposed_savings, 0);
  v_status             text;
  v_reference          text;
  v_bank_reference     text;
  v_duplicate_count    integer;
BEGIN
  -- Authorisation: only the member themselves, or Treasurer/SystemAdmin
  IF app_member_id() IS DISTINCT FROM p_member_id
     AND app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;

  -- Member must be Active, or Applicant with committee approval
  SELECT status INTO v_status FROM members WHERE id = p_member_id;
  IF v_status NOT IN ('Active','Applicant') THEN
    RAISE EXCEPTION 'Only Active members or approved Applicants may submit payments';
  END IF;
  IF v_status = 'Applicant'
     AND (SELECT admission_decision_at FROM members WHERE id = p_member_id) IS NULL THEN
    RAISE EXCEPTION 'Membership application must be approved before first contribution';
  END IF;

  -- Validate amounts
  IF p_amount <= 0 OR p_proposed_savings < 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;

  -- Validate loan allocations
  FOR r IN
    SELECT *
    FROM jsonb_to_recordset(COALESCE(p_proposed_loans, '[]'::jsonb))
      x(loan_id uuid, amount numeric(12,2))
  LOOP
    IF r.amount <= 0 THEN
      RAISE EXCEPTION 'Loan allocation must be positive';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM loans
      WHERE id = r.loan_id
        AND member_id = p_member_id
        AND status IN ('Active', 'Disbursed')
    ) THEN
      RAISE EXCEPTION 'Selected loan does not belong to member or is not active';
    END IF;
    v_sum := v_sum + r.amount;
  END LOOP;

  IF v_sum <> p_amount THEN
    RAISE EXCEPTION 'Proposed allocation total % must equal payment amount %',
      v_sum, p_amount;
  END IF;

  -- Generate or use provided tracking reference
  v_reference := COALESCE(
    NULLIF(trim(p_payment_reference), ''),
    public.generate_payment_reference()
  );

  -- Normalise bank reference: uppercase, strip non-alphanumeric
  -- "TRF/2026/12345" → "TRF202612345"
  -- "trf 2026 12345" → "TRF202612345"
  v_bank_reference := NULLIF(
    UPPER(REGEXP_REPLACE(
      COALESCE(trim(p_bank_reference), ''),
      '[^A-Za-z0-9]',
      '',
      'g'
    )),
    ''
  );

  -- Optional duplicate check (only when reference was provided)
  IF v_bank_reference IS NOT NULL THEN
    SELECT COUNT(*) INTO v_duplicate_count
    FROM public.payment_notifications
    WHERE member_id = p_member_id
      AND bank_reference = v_bank_reference
      AND status != 'Declined';

    IF v_duplicate_count > 0 THEN
      RAISE EXCEPTION
        'You have already submitted a payment with this bank reference. '
        'If this is the same payment, do not submit again — check your Payment History. '
        'If it is a different payment, use the correct reference from your bank statement '
        'for that specific transfer.';
    END IF;
  END IF;

  -- Insert the notification
  INSERT INTO public.payment_notifications (
    member_id,
    amount,
    payment_reference,
    bank_reference,
    evidence_url,
    source,
    match_confidence,
    proposed_savings_amount,
    proposed_loan_allocations,
    created_by
  ) VALUES (
    p_member_id,
    p_amount,
    v_reference,
    v_bank_reference,
    p_evidence_url,
    'MANUAL',
    'NONE',
    p_proposed_savings,
    COALESCE(p_proposed_loans, '[]'::jsonb),
    app_member_id()
  )
  RETURNING id INTO v_id;

  -- Audit entry (extra field records whether bank reference was captured)
  PERFORM write_audit(
    'CREATE_PAYMENT_NOTIFICATION',
    'payment_notification',
    v_id,
    jsonb_build_object(
      'amount', p_amount,
      'source', 'MANUAL',
      'reference', v_reference,
      'bank_reference', v_bank_reference,
      'bank_reference_provided', v_bank_reference IS NOT NULL
    )
  );

  -- Notify the member
  PERFORM queue_notification(
    p_member_id,
    'PENDING_QUEUE',
    'Payment submitted',
    'Your payment of N' || to_char(p_amount, 'FM999,999,990.00') ||
      ' has been submitted (Ref: ' || v_reference ||
      ') and is awaiting Treasurer approval.',
    jsonb_build_object(
      'payment_notification_id', v_id,
      'reference', v_reference
    )
  );

  RETURN v_id;
END;
$$;

-- ---------- 3. Grant permissions ----------

GRANT EXECUTE ON FUNCTION public.submit_payment_notification(
  uuid, numeric, text, text, numeric, jsonb, text
) TO authenticated;

-- ---------- 4. Reload PostgREST cache ----------

NOTIFY pgrst, 'reload schema';

COMMIT;