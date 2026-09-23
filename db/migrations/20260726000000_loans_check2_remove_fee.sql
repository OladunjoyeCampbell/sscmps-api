-- ============================================================
-- Update loans_check2 for the new fee rule
-- ============================================================
-- Old rule: total_repayable = principal + interest + fee
-- New rule: total_repayable = principal + interest
--           (fee collected with the first instalment)
--
-- Applied as NOT VALID so existing loans (created under the old
-- rule) are grandfathered. New inserts and updates must satisfy
-- the new formula.
--
-- To validate the constraint later (once historical data no
-- longer matters), run:
--   ALTER TABLE public.loans VALIDATE CONSTRAINT loans_check2;
-- ============================================================

-- 1. Drop the old constraint
ALTER TABLE public.loans DROP CONSTRAINT IF EXISTS loans_check2;

-- 2. Add the corrected constraint, skipping validation of existing rows
ALTER TABLE public.loans
  ADD CONSTRAINT loans_check2
  CHECK (total_repayable = (principal_amount + total_interest))
  NOT VALID;

NOTIFY pgrst, 'reload schema';