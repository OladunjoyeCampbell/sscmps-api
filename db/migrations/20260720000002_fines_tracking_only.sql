-- ============================================================
-- Fines: tracking-only (no automatic debit)
-- ============================================================
-- Committee decision: fines for missed contributions and
-- unauthorised downward revisions are recorded in
-- contribution_fine_events but are NOT charged to the member's
-- savings balance. The record remains visible on the member
-- profile and dashboards.
-- ============================================================

-- ---------- 1. request_contribution_revision (no ledger debit) ----------

CREATE OR REPLACE FUNCTION public.request_contribution_revision(
  p_member_id uuid,
  p_new_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_old numeric(12,2);
BEGIN
  IF app_member_id() IS DISTINCT FROM p_member_id AND app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;

  SELECT standing_contribution_amount INTO v_old
  FROM members WHERE id = p_member_id FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'Member not found';
  END IF;

  IF p_new_amount < 10000 THEN
    RAISE EXCEPTION 'Minimum monthly contribution is N10,000';
  END IF;

  IF extract(month FROM current_date) NOT IN (1,7) THEN
    RAISE EXCEPTION 'Contribution authority form is editable only in January or July';
  END IF;

  IF p_new_amount < v_old THEN
    INSERT INTO contribution_fine_events(member_id, fine_type, amount, reason, ledger_entry_id)
    VALUES (
      p_member_id,
      'DOWNWARD_REVISION',
      2000,
      'Unauthorised downward contribution revision (fine recorded, not charged — Committee policy)',
      NULL
    );

    PERFORM write_audit(
      'DOWNWARD_CONTRIBUTION_REVISION_REJECTED',
      'member',
      p_member_id,
      jsonb_build_object(
        'old_amount', v_old,
        'requested_amount', p_new_amount,
        'fine_amount', 2000,
        'charged', false
      )
    );

    RETURN jsonb_build_object(
      'accepted', false,
      'fine_amount', 2000,
      'charged', false,
      'reason', 'Revision rejected; N2,000 recorded as a compliance event (not charged)'
    );
  END IF;

  UPDATE members
  SET standing_contribution_amount = p_new_amount,
      contribution_authority_form_date = current_date,
      contribution_authority_reviewed = true
  WHERE id = p_member_id;

  PERFORM write_audit(
    'UPDATE_CONTRIBUTION_AUTHORITY',
    'member',
    p_member_id,
    jsonb_build_object('old_amount', v_old, 'new_amount', p_new_amount)
  );

  RETURN jsonb_build_object('accepted', true, 'new_amount', p_new_amount);
END;
$function$;

-- ---------- 2. flag_missed_contribution (tracking only) ----------

CREATE OR REPLACE FUNCTION public.flag_missed_contribution(
  p_member_id uuid,
  p_contribution_month date,
  p_reason text DEFAULT 'Contribution not received by the 10th of the following month'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_event_id uuid;
BEGIN
  p_contribution_month := date_trunc('month', p_contribution_month)::date;

  SELECT id INTO v_event_id
  FROM contribution_fine_events
  WHERE member_id = p_member_id
    AND fine_type = 'MISSED_MONTH'
    AND contribution_month = p_contribution_month
  LIMIT 1;

  IF v_event_id IS NOT NULL THEN
    RETURN v_event_id;
  END IF;

  INSERT INTO contribution_fine_events(
    member_id, fine_type, contribution_month, amount, reason, ledger_entry_id
  )
  VALUES (
    p_member_id,
    'MISSED_MONTH',
    p_contribution_month,
    1000,
    p_reason || ' (fine recorded, not charged — Committee policy)',
    NULL
  )
  RETURNING id INTO v_event_id;

  PERFORM write_audit(
    'FLAG_MISSED_CONTRIBUTION',
    'member',
    p_member_id,
    jsonb_build_object(
      'contribution_month', p_contribution_month,
      'fine_amount', 1000,
      'charged', false
    )
  );

  RETURN v_event_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.flag_missed_contribution(uuid, date, text) TO authenticated;

-- ---------- 3. View: per-member defaulting status ----------

CREATE OR REPLACE VIEW public.member_contribution_defaults AS
WITH expected AS (
  SELECT
    m.id AS member_id,
    m.staff_id,
    m.first_name,
    m.last_name,
    m.standing_contribution_amount,
    gs.month_start
  FROM members m
  CROSS JOIN LATERAL generate_series(
    date_trunc('month', COALESCE(m.first_contribution_date, m.admission_date, m.created_at::date)),
    date_trunc('month', current_date) - interval '1 month',
    interval '1 month'
  ) AS gs(month_start)
  WHERE m.status = 'Active'
)
SELECT
  e.member_id,
  e.staff_id,
  e.first_name || ' ' || e.last_name AS name,
  e.month_start::date AS contribution_month,
  (e.month_start + interval '1 month' + interval '9 days')::date AS due_date,
  e.standing_contribution_amount,
  CASE
    WHEN EXISTS (
      SELECT 1 FROM ledger_entries le
      WHERE le.member_id = e.member_id
        AND le.transaction_type = 'CONTRIBUTION'
        AND le.status = 'Approved'
        AND date_trunc('month', le.transaction_date) = e.month_start
    ) THEN true
    ELSE false
  END AS paid,
  CASE
    WHEN EXISTS (
      SELECT 1 FROM contribution_fine_events cfe
      WHERE cfe.member_id = e.member_id
        AND cfe.fine_type = 'MISSED_MONTH'
        AND cfe.contribution_month = e.month_start::date
    ) THEN true
    ELSE false
  END AS flagged
FROM expected e;

-- ---------- 4. run_compliance_check RPC ----------

CREATE OR REPLACE FUNCTION public.run_compliance_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_row record;
  v_total_flagged integer := 0;
  v_members_affected uuid[] := ARRAY[]::uuid[];
BEGIN
  IF app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Only Treasurer/SystemAdmin may run the compliance check';
  END IF;

  FOR v_row IN
    SELECT member_id, contribution_month
    FROM public.member_contribution_defaults
    WHERE paid = false
      AND flagged = false
      AND due_date < current_date
    ORDER BY member_id, contribution_month
  LOOP
    PERFORM public.flag_missed_contribution(v_row.member_id, v_row.contribution_month);
    v_total_flagged := v_total_flagged + 1;
    IF NOT (v_row.member_id = ANY(v_members_affected)) THEN
      v_members_affected := array_append(v_members_affected, v_row.member_id);
    END IF;
  END LOOP;

  PERFORM write_audit(
    'RUN_COMPLIANCE_CHECK',
    'system',
    NULL,
    jsonb_build_object(
      'total_flagged', v_total_flagged,
      'members_affected', array_length(v_members_affected, 1)
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'total_flagged', v_total_flagged,
    'members_affected', COALESCE(array_length(v_members_affected, 1), 0),
    'member_ids', v_members_affected
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.run_compliance_check() TO authenticated;