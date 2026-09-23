-- ============================================================
-- Add registration_number to members
-- ============================================================
-- Format: 4-digit zero-padded text (e.g. 0005, 0178)
-- Legacy members carry over their FILE NO from the manual register.
-- New members receive one on committee approval.
-- ============================================================

ALTER TABLE public.members
  ADD COLUMN IF NOT EXISTS registration_number text;

CREATE UNIQUE INDEX IF NOT EXISTS uniq_members_registration_number
  ON public.members (registration_number)
  WHERE registration_number IS NOT NULL;

ALTER TABLE public.members
  DROP CONSTRAINT IF EXISTS members_registration_number_format;

ALTER TABLE public.members
  ADD CONSTRAINT members_registration_number_format
  CHECK (registration_number IS NULL OR registration_number ~ '^[0-9]{4}$');

COMMENT ON COLUMN public.members.registration_number IS
  'Cooperative member number from the manual register. 4 digits, zero-padded.';

-- Generator: next available number, padded to 4 digits
CREATE OR REPLACE FUNCTION public.generate_registration_number()
RETURNS text
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
  v_next integer;
BEGIN
  SELECT COALESCE(MAX(NULLIF(registration_number, '')::integer), 0) + 1
  INTO v_next
  FROM public.members
  WHERE registration_number ~ '^[0-9]{4}$';

  IF v_next > 9999 THEN
    RAISE EXCEPTION 'Registration number space exhausted (more than 9999). Extend the format before continuing.';
  END IF;

  RETURN lpad(v_next::text, 4, '0');
END;
$function$;

COMMENT ON FUNCTION public.generate_registration_number() IS
  'Returns the next available 4-digit registration number (e.g. 0179).';

-- Update record_admission_vote to assign a registration_number on approval
CREATE OR REPLACE FUNCTION public.record_admission_vote(
  p_member_id uuid,
  p_voter_id  uuid,
  p_vote      text,
  p_reason    text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_applicant record;
  v_voter_role text;
  v_approve_count int;
  v_reject_count  int;
  v_reg_number text;
BEGIN
  SELECT id, status, admission_decision_at, registration_number
  INTO v_applicant
  FROM public.members
  WHERE id = p_member_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Applicant not found');
  END IF;

  IF v_applicant.admission_decision_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Application already decided');
  END IF;

  SELECT role INTO v_voter_role
  FROM public.members
  WHERE id = p_voter_id;

  IF v_voter_role NOT IN ('Chairman', 'Secretary', 'Treasurer',
                          'ManagementCommittee', 'SystemAdmin') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Only Management Committee members may vote');
  END IF;

  IF p_vote NOT IN ('Approve', 'Reject') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'vote must be Approve or Reject');
  END IF;

  IF p_vote = 'Reject' AND (p_reason IS NULL OR length(trim(p_reason)) = 0) THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Reason is required for rejection');
  END IF;

  INSERT INTO public.admission_votes (member_id, voter_id, vote, vote_reason)
  VALUES (p_member_id, p_voter_id, p_vote, p_reason)
  ON CONFLICT (member_id, voter_id) DO NOTHING;

  SELECT
    COALESCE(SUM(CASE WHEN vote = 'Approve' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN vote = 'Reject'  THEN 1 ELSE 0 END), 0)
  INTO v_approve_count, v_reject_count
  FROM public.admission_votes
  WHERE member_id = p_member_id;

  IF v_approve_count >= 2 THEN
    -- Assign a registration number if the applicant doesn't already have one
    IF v_applicant.registration_number IS NULL THEN
      v_reg_number := public.generate_registration_number();
    ELSE
      v_reg_number := v_applicant.registration_number;
    END IF;

    UPDATE public.members
    SET admission_decision_at  = now(),
        admission_decision_by  = p_voter_id,
        status                 = 'Active',
        registration_number    = v_reg_number,
        admission_rejection_reason = NULL,
        updated_at             = now()
    WHERE id = p_member_id;

    RETURN jsonb_build_object(
      'success', true,
      'outcome', 'Approved',
      'registration_number', v_reg_number,
      'approve_count', v_approve_count,
      'reject_count',  v_reject_count,
      'finalised', true
    );
  ELSIF v_reject_count >= 2 THEN
    UPDATE public.members
    SET admission_decision_at       = now(),
        admission_decision_by       = p_voter_id,
        admission_rejection_reason  = p_reason,
        status                      = 'Applicant',
        updated_at                  = now()
    WHERE id = p_member_id;

    RETURN jsonb_build_object(
      'success', true,
      'outcome', 'Rejected',
      'approve_count', v_approve_count,
      'reject_count',  v_reject_count,
      'finalised', true
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'outcome', 'Pending',
    'approve_count', v_approve_count,
    'reject_count',  v_reject_count,
    'finalised', false
  );
END;
$function$;