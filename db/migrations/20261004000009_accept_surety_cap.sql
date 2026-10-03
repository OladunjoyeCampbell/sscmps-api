-- ============================================================
-- accept_surety: enforce the 2-guarantee cap at accept-time
-- ============================================================
-- The prior version only counted Active and Disbursed loans,
-- allowing a surety to accept unlimited Pending requests. That
-- pushed the enforcement to approval time, where the committee
-- would discover the cap was exceeded and have to ask the
-- applicant to find a replacement.
--
-- New behaviour: count every Accepted commitment on a non-Closed
-- loan (Pending, Approved, Disbursed, Active, Defaulted). If the
-- surety already has 2 such commitments, block a 3rd.
--
-- Closed loans (rejected, withdrawn, fully repaid) do not count,
-- so capacity is recovered when a loan terminates.
--
-- Result: the pool is respected from the moment of acceptance.
-- The committee never sees a blocked approval for surety
-- capacity — the applicant already knows before the loan is
-- submitted.
-- ============================================================

CREATE OR REPLACE FUNCTION public.accept_surety(p_surety_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path to 'public', 'pg_temp'
AS $function$
DECLARE
  s sureties%ROWTYPE;
  v_count integer;
  v_loan_member uuid;
  v_existing_loans text;
BEGIN
  SELECT * INTO s FROM sureties WHERE id=p_surety_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Surety request not found'; END IF;

  IF s.surety_member_id<>app_member_id() THEN
    RAISE EXCEPTION 'Only the named surety may accept';
  END IF;

  IF (SELECT status FROM members WHERE id=s.surety_member_id)<>'Active' THEN
    RAISE EXCEPTION 'Surety must be an Active member';
  END IF;

  SELECT member_id INTO v_loan_member FROM loans WHERE id=s.loan_id;
  IF v_loan_member=s.surety_member_id THEN
    RAISE EXCEPTION 'A member cannot be surety for own loan';
  END IF;

  -- Count every Accepted commitment on a live (non-Closed) loan.
  SELECT count(*), string_agg(l.loan_reference, ', ' ORDER BY l.loan_reference)
  INTO v_count, v_existing_loans
  FROM sureties ss
  JOIN loans l ON l.id = ss.loan_id
  WHERE ss.surety_member_id = s.surety_member_id
    AND ss.status = 'Accepted'
    AND l.status IN ('Pending','Approved','Disbursed','Active','Defaulted');

  IF v_count >= 2 THEN
    RAISE EXCEPTION
      'You already have 2 accepted guarantees (%). You can only be surety for 2 loans at a time (Bye-law §51). Release one before accepting another.',
      v_existing_loans;
  END IF;

  UPDATE sureties
  SET status='Accepted',
      consent_given_at=now(),
      consent_ip=NULL,
      consent_user_agent=NULL
  WHERE id=s.id;

  PERFORM write_audit('ACCEPT_SURETY','surety',s.id,
    jsonb_build_object('loan_id', s.loan_id, 'existing_guarantees', v_count));
END;
$function$;

notify pgrst, 'reload schema';