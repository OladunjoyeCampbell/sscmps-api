-- ============================================================
-- Evidence Storage RLS Policy
-- ============================================================
-- Restricts write access to the `evidence` bucket to each user's
-- own folder. Reads go through the API's signed-URL endpoint,
-- which uses the service-role key and is not subject to RLS.
--
-- Applied to the live Supabase project on 2026-09-15.
-- This file exists so the migration can be replayed on a fresh
-- database and so repo state matches live state.
--
-- Upload path structure (enforced by the frontend and the policy):
--   evidence/<auth_user_id>/payment-evidence/<timestamp>-<random>.<ext>
-- ============================================================

-- 1. Drop the pre-existing permissive policies
DROP POLICY IF EXISTS "evidence_read"   ON storage.objects;
DROP POLICY IF EXISTS "evidence_upload" ON storage.objects;

-- 2. Drop our new policies too, so this migration is idempotent
DROP POLICY IF EXISTS "evidence_insert_own_folder" ON storage.objects;
DROP POLICY IF EXISTS "evidence_update_own_folder" ON storage.objects;
DROP POLICY IF EXISTS "evidence_delete_own_folder" ON storage.objects;

-- 3. INSERT: users can only upload into their own folder
CREATE POLICY "evidence_insert_own_folder"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'evidence'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- 4. UPDATE: users can only modify files in their own folder
CREATE POLICY "evidence_update_own_folder"
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'evidence'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'evidence'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- 5. DELETE: users can only delete files in their own folder
CREATE POLICY "evidence_delete_own_folder"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'evidence'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

-- NOTE: No SELECT policy is defined. Members and the Treasurer view
-- evidence via the API's signed-URL endpoint (src/routes/evidence.js),
-- which uses the service-role key and bypasses RLS entirely.
