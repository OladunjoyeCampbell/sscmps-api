-- ============================================================
-- request_surety: count only active sureties toward the cap
-- ============================================================
-- The previous version counted every row in sureties, including
-- Declined, Expired, and Released. That blocked the applicant
-- from inviting a replacement after one surety declined, which
-- left the loan stuck.
--
-- New behaviour: only Pending and Accepted sureties count toward
-- the 2-cap. Declined/Expired/Released do not, so replacement
-- works without an explicit release step for those statuses.
--
-- Other than the count filter, this function is unchanged.
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_surety(p_loan_id uuid, p_surety_member_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE v_member uuid:=app_member_id(); v_loan loans%ROWTYPE; v_count integer; v_id uuid;

BEGIN

  SELECT * INTO v_loan FROM loans WHERE id=p_loan_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Loan not found'; END IF;

  IF v_loan.member_id<>v_member THEN RAISE EXCEPTION 'Only the borrowing member may request sureties'; END IF;

  IF v_loan.status<>'Pending' THEN RAISE EXCEPTION 'Sureties may only be requested for a pending loan application'; END IF;

  IF p_surety_member_id=v_member THEN RAISE EXCEPTION 'A member cannot be surety for own loan'; END IF;

  IF (SELECT status FROM members WHERE id=p_surety_member_id)<>'Active' THEN RAISE EXCEPTION 'Surety must be an Active member'; END IF;

  -- Only active commitments count toward the cap. Declined, Expired, and
  -- Released sureties do not, so the applicant can replace them.
  SELECT count(*) INTO v_count FROM sureties
  WHERE loan_id=p_loan_id AND status IN ('Pending','Accepted');

  IF v_count>=2 THEN RAISE EXCEPTION 'A loan may have at most 2 active sureties. Release one before inviting another.'; END IF;

  IF EXISTS(SELECT 1 FROM sureties WHERE loan_id=p_loan_id AND surety_member_id=p_surety_member_id) THEN RAISE EXCEPTION 'Surety has already been requested'; END IF;

  INSERT INTO sureties(loan_id,surety_member_id,status) VALUES(p_loan_id,p_surety_member_id,'Pending') RETURNING id INTO v_id;

  PERFORM write_audit('REQUEST_SURETY','surety',v_id,jsonb_build_object('loan_id',p_loan_id,'surety_member_id',p_surety_member_id));

  PERFORM queue_notification(p_surety_member_id,'SURETY_REQUEST','Surety consent requested','You have been asked to stand as surety for a cooperative loan. Please review and accept or decline the request.',jsonb_build_object('surety_id',v_id,'loan_id',p_loan_id));

  RETURN v_id;

END;

$function$;

notify pgrst, 'reload schema';