-- ============================================================
-- Phase 1b — Member savings corrections (delta-based)
-- Date applied: 2026-11-01
-- Source: Treasurer letter 2026-10-31
-- Applied to: copy DB (verified) then main DB (verified)
-- Idempotent: yes (delta check skips if already at target)
-- ============================================================
-- Changes:
--   0003 Enoch N Gana:  ₦1,260,000 → ₦2,191,512 (+₦931,512 CONTRIBUTION)
--   0028 John Jiya Ahmed: ₦402,650 → ₦385,650 (−₦17,000 REVERSAL)
--
-- Method: compute delta = target − current. If positive, insert
-- CONTRIBUTION of delta. If negative, insert REVERSAL of |delta|
-- pointing to the member's original opening-balance entry.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_member_id         uuid;
  v_treasurer_id      uuid;
  v_current           numeric(12,2);
  v_target            numeric(12,2);
  v_delta             numeric(12,2);
  v_original_entry_id uuid;
  v_reg               text;
  v_corrections jsonb := '[
    {"reg":"0003","target":2191512.00},
    {"reg":"0028","target":385650.00}
  ]'::jsonb;
  c jsonb;
BEGIN
  SELECT id INTO v_treasurer_id FROM members WHERE registration_number='0004';
  IF v_treasurer_id IS NULL THEN
    RAISE EXCEPTION 'Treasurer account (0004) not found — aborting';
  END IF;

  FOR c IN SELECT * FROM jsonb_array_elements(v_corrections) LOOP
    v_reg    := c->>'reg';
    v_target := (c->>'target')::numeric;

    SELECT id INTO v_member_id FROM members WHERE registration_number = v_reg;
    IF v_member_id IS NULL THEN
      RAISE EXCEPTION 'Member % not found', v_reg;
    END IF;

    v_current := get_member_savings_balance(v_member_id);
    v_delta   := v_target - v_current;

    RAISE NOTICE 'Member % — current N%, target N%, delta N%',
      v_reg, v_current, v_target, v_delta;

    IF v_delta = 0 THEN
      RAISE NOTICE '  → already at target, skipping';
      CONTINUE;
    END IF;

    IF v_delta > 0 THEN
      -- Increase savings: plain CONTRIBUTION
      INSERT INTO ledger_entries (
        member_id, transaction_type, amount, source, status,
        approved_by, approved_at, allocation_notes
      ) VALUES (
        v_member_id, 'CONTRIBUTION', v_delta, 'SYSTEM', 'Approved',
        v_treasurer_id, now(),
        format('Round 2 correction (Treasurer, 2026-10-31): savings increase by N%s (was N%s, target N%s)',
               v_delta, v_current, v_target)
      );
      RAISE NOTICE '  → inserted CONTRIBUTION of N%', v_delta;
    ELSE
      -- Decrease savings: REVERSAL against original opening entry
      SELECT id INTO v_original_entry_id FROM ledger_entries
      WHERE member_id = v_member_id
        AND transaction_type = 'CONTRIBUTION'
        AND allocation_notes LIKE 'Historical savings brought forward%'
        AND parent_ledger_entry_id IS NULL
      ORDER BY created_at ASC LIMIT 1;

      IF v_original_entry_id IS NULL THEN
        RAISE EXCEPTION 'No opening-balance entry found for member %', v_reg;
      END IF;

      INSERT INTO ledger_entries (
        member_id, transaction_type, amount, source, status,
        approved_by, approved_at, parent_ledger_entry_id,
        reversal_reason, reversal_approved_by, allocation_notes
      ) VALUES (
        v_member_id, 'REVERSAL', abs(v_delta), 'SYSTEM', 'Approved',
        v_treasurer_id, now(), v_original_entry_id,
        format('Round 2 correction (Treasurer, 2026-10-31): savings decrease of N%s (was N%s, target N%s)',
               abs(v_delta), v_current, v_target),
        v_treasurer_id,
        format('Reversal of opening-balance portion; was N%s, target N%s',
               v_current, v_target)
      );
      RAISE NOTICE '  → inserted REVERSAL of N% against opening entry %',
        abs(v_delta), v_original_entry_id;
    END IF;

    PERFORM write_audit(
      'TREASURER_CORRECTION_SAVINGS_ROUND2',
      'member', v_member_id,
      jsonb_build_object(
        'registration_number', v_reg,
        'old_savings', v_current,
        'new_savings', v_target,
        'delta', v_delta,
        'reason', 'Treasurer letter 2026-10-31'
      ),
      v_treasurer_id
    );
  END LOOP;
END $$;

COMMIT;

-- ============================================================
-- VERIFICATION (run after applying)
-- ============================================================
-- V1. Savings at target
-- SELECT registration_number,
--        get_member_savings_balance(id) AS savings
-- FROM members WHERE registration_number IN ('0003','0028')
-- ORDER BY registration_number;
-- Expected: 0003 = 2,191,512.00 ; 0028 = 385,650.00
--
-- V2. Ledger entries
-- SELECT m.registration_number, le.transaction_type, le.amount,
--        le.parent_ledger_entry_id, le.reversal_reason
-- FROM ledger_entries le
-- JOIN members m ON m.id = le.member_id
-- WHERE m.registration_number IN ('0003','0028')
--   AND (le.allocation_notes LIKE 'Round 2 correction%'
--        OR le.reversal_reason LIKE 'Round 2 correction%')
-- ORDER BY m.registration_number;
-- Expected: 2 rows (CONTRIBUTION for 0003, REVERSAL for 0028)
-- ============================================================