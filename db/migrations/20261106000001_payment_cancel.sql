-- 20261106000001_payment_cancel.sql
--
-- Member-initiated cancel for their own Pending payment submission.
--
-- Rules:
--   * Only the submitting member can cancel.
--   * Only while status = 'Pending' (Treasurer has not acted).
--   * Row preserved (status → Cancelled), not deleted — audit trail intact.
--   * A cancelled submission's bank_reference no longer blocks resubmission
--     (submit_payment_notification's duplicate check excludes Cancelled).
--
-- Financial safety: cancel never touches ledger_entries, savings balances,
-- or loan balances. It only moves a Pending notice to Cancelled. Reversing
-- an Approved payment still requires reverse_ledger_entry (separate flow).
--
-- Application:
--   psql $env:SUPABASE_DB_URL --single-transaction -f db/migrations/20261106000001_payment_cancel.sql

-- ---------------------------------------------------------------------
-- 1. Expand status CHECK constraint
-- ---------------------------------------------------------------------
ALTER TABLE public.payment_notifications
  DROP CONSTRAINT IF EXISTS payment_notifications_status_check;

ALTER TABLE public.payment_notifications
  ADD CONSTRAINT payment_notifications_status_check
  CHECK (status = ANY (ARRAY[
    'Pending', 'Approved', 'Declined', 'Unidentified', 'Reversed', 'Cancelled'
  ]));

-- ---------------------------------------------------------------------
-- 2. Cancellation metadata
-- ---------------------------------------------------------------------
ALTER TABLE public.payment_notifications
  ADD COLUMN IF NOT EXISTS cancelled_at   timestamptz,
  ADD COLUMN IF NOT EXISTS cancelled_by   uuid REFERENCES members(id),
  ADD COLUMN IF NOT EXISTS cancel_reason  text;

-- ---------------------------------------------------------------------
-- 3. cancel_payment_notification RPC
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_payment_notification(
  p_notification_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_caller uuid := app_member_id();
  v_row    payment_notifications%rowtype;
BEGIN
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  SELECT * INTO v_row
  FROM public.payment_notifications
  WHERE id = p_notification_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Notification not found');
  END IF;

  IF v_row.member_id IS DISTINCT FROM v_caller THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'You can only cancel your own payment submissions'
    );
  END IF;

  IF v_row.status <> 'Pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', format(
        'This payment is %s and can no longer be cancelled. '
        'Contact the Treasurer if a change is needed.',
        v_row.status
      )
    );
  END IF;

  UPDATE public.payment_notifications SET
    status = 'Cancelled',
    cancelled_at = now(),
    cancelled_by = v_caller,
    cancel_reason = NULLIF(p_reason, ''),
    updated_at = now()
  WHERE id = p_notification_id;

  PERFORM public.write_audit(
    'CANCEL_PAYMENT_NOTIFICATION',
    'payment_notification',
    p_notification_id,
    jsonb_build_object(
      'amount', v_row.amount,
      'payment_reference', v_row.payment_reference,
      'bank_reference', v_row.bank_reference,
      'reason', p_reason
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'cancelled_at', now(),
    'payment_reference', v_row.payment_reference
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION
  public.cancel_payment_notification(uuid, text)
  TO authenticated;

-- ---------------------------------------------------------------------
-- 4. Patch submit_payment_notification so a cancelled reference
--    no longer blocks resubmission.
--
--    The current duplicate-check filter is:
--        AND status != 'Declined';
--    It must also exclude Cancelled:
--        AND status NOT IN ('Declined', 'Cancelled')
--
--    Uses pg_get_functiondef to fetch and rewrite the current body rather
--    than guessing at the full signature/body. Fails loudly if the pattern
--    is not found, so the migration cannot silently miss the fix.
-- ---------------------------------------------------------------------
DO $patch$
DECLARE
  v_def    text;
  v_old    text := 'status != ''Declined''';
  v_new    text := 'status NOT IN (''Declined'', ''Cancelled'')';
  v_count  int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'submit_payment_notification';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'submit_payment_notification not found';
  END IF;

  -- Verify the target pattern exists exactly once
  v_count := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one occurrence of "%" in submit_payment_notification, found %. '
      'Inspect manually — the migration will not proceed.',
      v_old, v_count;
  END IF;

  v_def := replace(v_def, v_old, v_new);
  EXECUTE v_def;

  RAISE NOTICE 'Patched submit_payment_notification: % -> %', v_old, v_new;
END
$patch$;