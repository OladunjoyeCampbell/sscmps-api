-- ============================================================
-- Phase 1a — Member name corrections
-- Date applied: 2026-11-01
-- Source: Treasurer letter 2026-10-31
-- Applied to: main DB only
--   (The copy DB was restored from a pre-Phase-1a backup and
--    was not re-run for names — the copy's purpose was to test
--    Phase 1b and Phase 2, which don't depend on member names.)
-- Idempotent: yes (re-running with same values is a row-level no-op)
-- ============================================================
-- Changes:
--   0019 Mamman Zacchaeus Ndaba    → Zacchaeus Ndaba Mamman
--   0023 Daniel Olanrewaju Adewara → Olanrewaju Daniel Adewara
--   0071 Winnifred Wodu Tsado      → Winifred Wodu Tsado
-- ============================================================

BEGIN;

UPDATE members
SET first_name  = 'Zacchaeus',
    middle_name = 'Ndaba',
    last_name   = 'Mamman',
    updated_at  = now()
WHERE registration_number = '0019';

UPDATE members
SET first_name  = 'Olanrewaju',
    middle_name = 'Daniel',
    last_name   = 'Adewara',
    updated_at  = now()
WHERE registration_number = '0023';

UPDATE members
SET first_name  = 'Winifred',
    middle_name = 'Wodu',
    last_name   = 'Tsado',
    updated_at  = now()
WHERE registration_number = '0071';

COMMIT;

-- ============================================================
-- VERIFICATION (run after applying)
-- ============================================================
-- SELECT registration_number, first_name, middle_name, last_name
-- FROM members WHERE registration_number IN ('0019','0023','0071')
-- ORDER BY registration_number;
--
-- Expected:
--   0019 | Zacchaeus    | Ndaba       | Mamman
--   0023 | Olanrewaju   | Daniel      | Adewara
--   0071 | Winifred     | Wodu        | Tsado
-- ============================================================