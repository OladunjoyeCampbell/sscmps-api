-- ============================================================
-- Admission votes — Management Committee admission workflow
-- ============================================================
-- Bye-law Section 10: disposal of admission applications rests
-- with the Management Committee.
-- Bye-law Section 29: the MC comprises the Chairman, Treasurer,
-- and Secretary (ex officio), plus any additionally tagged
-- ManagementCommittee members.
--
-- Each eligible committee member records one vote per applicant.
-- A decision finalises when 2 approvals or 2 rejections are in.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.admission_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES public.members(id) ON DELETE CASCADE,
  voter_id  uuid NOT NULL REFERENCES public.members(id) ON DELETE RESTRICT,
  vote text NOT NULL CHECK (vote IN ('Approve', 'Reject')),
  vote_reason text,
  voted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (member_id, voter_id)
);

CREATE INDEX IF NOT EXISTS idx_admission_votes_member ON public.admission_votes (member_id);

COMMENT ON TABLE public.admission_votes IS
  'Append-only committee votes on member admission. Bye-law Sections 10, 29.';

-- ------------------------------------------------------------
-- record_admission_vote
-- Records one committee member's vote and finalises the
-- decision when the threshold (2 of 3) is reached.
-- ------------------------------------------------------------
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
BEGIN
  SELECT id, status, admission_decision_at
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
    UPDATE public.members
    SET admission_decision_at  = now(),
        admission_decision_by  = p_voter_id,
        status                 = 'Active',
        admission_rejection_reason = NULL,
        updated_at             = now()
    WHERE id = p_member_id;

    RETURN jsonb_build_object(
      'success', true,
      'outcome', 'Approved',
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

GRANT EXECUTE ON FUNCTION public.record_admission_vote(uuid, uuid, text, text)
  TO authenticated;