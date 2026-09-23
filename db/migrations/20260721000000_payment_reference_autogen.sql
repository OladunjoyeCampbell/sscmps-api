-- ============================================================
-- Auto-generated payment references
-- ============================================================
-- Format: PMT-YYYYMMDD-NNNNNN
--   PMT       = payment prefix
--   YYYYMMDD  = date the notification is created
--   NNNNNN    = zero-padded global sequence
--
-- Example: PMT-20260918-000042
--
-- Existing rows keep their manually-typed references (all unique,
-- verified before applying). New rows get the generated value
-- unless the caller passes an explicit override.
-- ============================================================

-- 1. Sequence
CREATE SEQUENCE IF NOT EXISTS public.payment_reference_seq START 1;

-- 2. Generator function
CREATE OR REPLACE FUNCTION public.generate_payment_reference()
RETURNS text
LANGUAGE sql
VOLATILE
AS $function$
  SELECT 'PMT-' || to_char(current_date, 'YYYYMMDD') || '-' ||
         lpad(nextval('public.payment_reference_seq')::text, 6, '0');
$function$;

COMMENT ON FUNCTION public.generate_payment_reference() IS
  'Generates a unique payment reference: PMT-YYYYMMDD-NNNNNN';

-- 3. Column default — fires on direct inserts that omit the column
ALTER TABLE public.payment_notifications
  ALTER COLUMN payment_reference SET DEFAULT public.generate_payment_reference();

-- 4. Unique constraint (existing data verified duplicate-free)
ALTER TABLE public.payment_notifications
  ADD CONSTRAINT payment_notifications_payment_reference_key
  UNIQUE (payment_reference);

-- 5. Replace the RPC so it generates a reference when none is supplied
CREATE OR REPLACE FUNCTION public.submit_payment_notification(
  p_member_id uuid,
  p_amount numeric,
  p_payment_reference text DEFAULT NULL::text,
  p_evidence_url text DEFAULT NULL::text,
  p_proposed_savings numeric DEFAULT 0,
  p_proposed_loans jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id uuid;
  r record;
  v_sum numeric(12,2) := COALESCE(p_proposed_savings, 0);
  v_status text;
  v_reference text;
BEGIN
  IF app_member_id() IS DISTINCT FROM p_member_id AND app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;

  SELECT status INTO v_status FROM members WHERE id = p_member_id;
  IF v_status NOT IN ('Active','Applicant') THEN
    RAISE EXCEPTION 'Only Active members or Management-Committee-approved Applicants may submit payments';
  END IF;
  IF v_status = 'Applicant' AND (SELECT admission_decision_at FROM members WHERE id = p_member_id) IS NULL THEN
    RAISE EXCEPTION 'Membership application must be approved before the first contribution is submitted';
  END IF;

  IF p_amount <= 0 OR p_proposed_savings < 0 THEN
    RAISE EXCEPTION 'Invalid amount';
  END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(COALESCE(p_proposed_loans,'[]'::jsonb)) x(loan_id uuid, amount numeric(12,2)) LOOP
    IF r.amount <= 0 THEN
      RAISE EXCEPTION 'Loan allocation must be positive';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM loans WHERE id = r.loan_id AND member_id = p_member_id AND status IN ('Active','Disbursed')) THEN
      RAISE EXCEPTION 'Selected loan does not belong to member or is not active';
    END IF;
    v_sum := v_sum + r.amount;
  END LOOP;

  IF v_sum <> p_amount THEN
    RAISE EXCEPTION 'Proposed allocation total % must equal payment amount %', v_sum, p_amount;
  END IF;

  -- Caller-supplied reference wins; otherwise generate one.
  -- NULLIF + trim guards against empty strings.
  v_reference := COALESCE(NULLIF(trim(p_payment_reference), ''), public.generate_payment_reference());

  INSERT INTO payment_notifications(
    member_id, amount, payment_reference, evidence_url, source,
    match_confidence, proposed_savings_amount, proposed_loan_allocations, created_by
  )
  VALUES(
    p_member_id, p_amount, v_reference, p_evidence_url, 'MANUAL',
    'NONE', p_proposed_savings, COALESCE(p_proposed_loans,'[]'::jsonb), app_member_id()
  )
  RETURNING id INTO v_id;

  PERFORM write_audit(
    'CREATE_PAYMENT_NOTIFICATION',
    'payment_notification',
    v_id,
    jsonb_build_object('amount', p_amount, 'source', 'MANUAL', 'reference', v_reference)
  );

  PERFORM queue_notification(
    p_member_id,
    'PENDING_QUEUE',
    'Payment submitted',
    'Your payment of N' || to_char(p_amount, 'FM999,999,990.00') ||
      ' has been submitted (Ref: ' || v_reference || ') and is awaiting Treasurer approval.',
    jsonb_build_object('payment_notification_id', v_id, 'reference', v_reference)
  );

  RETURN v_id;
END;
$function$;