-- ============================================================
-- SSCMPS SUPABASE MIGRATION v3.0
-- Digital Cooperative Management System
-- Niger State Polytechnic Senior Staff Cooperative & Multipurpose Society Ltd.
--
-- Basis: Software Requirements Specification v2.3 (September 2026)
-- Purpose: Production-oriented PostgreSQL/Supabase schema, RLS, business
-- rules, controlled financial workflows, audit, reconciliation and reporting.
--
-- IMPORTANT:
-- 1. Run this migration on a new/empty SSCMPS database, or reconcile it
--    carefully with existing data before applying to an existing database.
-- 2. Financial balances are derived from approved ledger entries; client
--    applications must not update balances directly.
-- 3. API and manual payment notices use the same payment_notifications queue.
-- 4. All financial posting functions are atomic: an error rolls back the
--    complete transaction.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

BEGIN;

-- ============================================================
-- 1. COMMON TYPES / HELPERS
-- ============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION app_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role
  FROM public.members
  WHERE auth_user_id = auth.uid()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION app_member_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id
  FROM public.members
  WHERE auth_user_id = auth.uid()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION is_trustee(p_member_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT role IN ('Chairman','Secretary','Treasurer')
     FROM public.members WHERE id = p_member_id), false
  );
$$;

CREATE OR REPLACE FUNCTION financial_year_start(p_date date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN extract(month FROM p_date) >= 12
      THEN make_date(extract(year FROM p_date)::int, 12, 1)
    ELSE make_date((extract(year FROM p_date)::int) - 1, 12, 1)
  END;
$$;

CREATE OR REPLACE FUNCTION financial_year_end(p_date date)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT financial_year_start(p_date) + interval '1 year' - interval '1 day';
$$;

-- ============================================================
-- 2. MEMBERS
-- ============================================================

CREATE TABLE members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
  staff_id text UNIQUE NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  middle_name text,
  email text UNIQUE NOT NULL,
  phone text,
  department text,
  position text,
  home_address text,
  next_of_kin_name text,
  next_of_kin_phone text,
  next_of_kin_relationship text,
  admission_date date,
  first_contribution_date date,
  standing_contribution_amount numeric(12,2) NOT NULL DEFAULT 10000.00
    CHECK (standing_contribution_amount >= 10000.00),
  contribution_authority_form_date date,
  contribution_authority_reviewed boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'Applicant'
    CHECK (status IN ('Applicant','Active','Suspended','Terminated','Exited')),
  termination_date date,
  termination_reason text,
  outside_indebtedness_declaration text,
  application_submitted_at timestamptz NOT NULL DEFAULT now(),
  admission_decision_at timestamptz,
  admission_decision_by uuid REFERENCES members(id),
  admission_rejection_reason text,
  role text NOT NULL DEFAULT 'Member'
    CHECK (role IN ('Member','Treasurer','Secretary','Chairman','LoanCommittee','ManagementCommittee','SystemAdmin')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (status IN ('Applicant','Active','Suspended','Terminated','Exited') OR first_contribution_date IS NOT NULL)
);

CREATE INDEX idx_members_auth_user ON members(auth_user_id);
CREATE INDEX idx_members_staff_id ON members(staff_id);
CREATE INDEX idx_members_status ON members(status);
CREATE INDEX idx_members_role ON members(role);
CREATE INDEX idx_members_first_contribution ON members(first_contribution_date);

CREATE TRIGGER trg_members_updated_at
BEFORE UPDATE ON members
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Lock role/status-sensitive fields behind controlled functions.
CREATE OR REPLACE FUNCTION guard_member_direct_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.role IS DISTINCT FROM NEW.role AND app_role() <> 'SystemAdmin' THEN
    RAISE EXCEPTION 'Only SystemAdmin may change member roles';
  END IF;

  IF OLD.status IS DISTINCT FROM NEW.status
     AND app_role() NOT IN ('Treasurer','Secretary','ManagementCommittee','SystemAdmin') THEN
    RAISE EXCEPTION 'Member status must be changed through the controlled admission/status workflow';
  END IF;

  IF OLD.standing_contribution_amount IS DISTINCT FROM NEW.standing_contribution_amount
     AND NEW.standing_contribution_amount < OLD.standing_contribution_amount THEN
    RAISE EXCEPTION 'Standing contribution cannot be reduced directly; use request_contribution_revision()';
  END IF;

  IF OLD.contribution_authority_form_date IS DISTINCT FROM NEW.contribution_authority_form_date
     AND extract(month FROM NEW.contribution_authority_form_date) NOT IN (1,7) THEN
    RAISE EXCEPTION 'Contribution authority form is editable only in January or July';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_member_update
BEFORE UPDATE ON members
FOR EACH ROW EXECUTE FUNCTION guard_member_direct_update();

ALTER TABLE members ENABLE ROW LEVEL SECURITY;

CREATE POLICY members_self_select ON members
FOR SELECT USING (auth.uid() = auth_user_id);

CREATE POLICY members_management_select ON members
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','LoanCommittee','ManagementCommittee','SystemAdmin'));

CREATE POLICY members_self_insert_application ON members
FOR INSERT WITH CHECK (
  auth.uid() = auth_user_id AND role = 'Member' AND status = 'Applicant'
);

CREATE POLICY members_controlled_update ON members
FOR UPDATE USING (
  app_role() IN ('Treasurer','Secretary','ManagementCommittee','SystemAdmin')
  OR auth.uid() = auth_user_id
)
WITH CHECK (
  app_role() IN ('Treasurer','Secretary','ManagementCommittee','SystemAdmin')
  OR auth.uid() = auth_user_id
);

-- ============================================================
-- 3. LOAN PRODUCTS
-- ============================================================

CREATE TABLE loan_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text UNIQUE NOT NULL CHECK (name IN ('Long-Term','Short-Term','Emergency','Essential Commodity')),
  normal_interest_rate numeric(5,2) NOT NULL,
  surplus_interest_rate numeric(5,2) NOT NULL DEFAULT 20.00,
  min_term_months integer NOT NULL,
  max_term_months integer NOT NULL,
  max_per_financial_year integer,
  requires_sureties boolean NOT NULL DEFAULT true,
  number_of_sureties_required integer NOT NULL DEFAULT 2 CHECK (number_of_sureties_required >= 0),
  application_fee numeric(12,2) NOT NULL DEFAULT 2000.00 CHECK (application_fee >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (min_term_months <= max_term_months)
);

INSERT INTO loan_products
(name, normal_interest_rate, surplus_interest_rate, min_term_months, max_term_months, max_per_financial_year)
VALUES
('Long-Term', 5.00, 20.00, 1, 24, NULL),
('Short-Term', 10.00, 20.00, 1, 10, 2),
('Emergency', 10.00, 20.00, 1, 10, 2),
('Essential Commodity', 10.00, 20.00, 10, 10, NULL)
ON CONFLICT (name) DO UPDATE SET
  normal_interest_rate = EXCLUDED.normal_interest_rate,
  surplus_interest_rate = EXCLUDED.surplus_interest_rate,
  min_term_months = EXCLUDED.min_term_months,
  max_term_months = EXCLUDED.max_term_months,
  max_per_financial_year = EXCLUDED.max_per_financial_year;

-- ============================================================
-- 4. LOANS
-- ============================================================

CREATE SEQUENCE loan_reference_seq START 1000;

CREATE TABLE loans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_reference text UNIQUE NOT NULL DEFAULT ('LN-' || to_char(current_date,'YYYYMMDD') || '-' || nextval('loan_reference_seq')::text),
  member_id uuid NOT NULL REFERENCES members(id),
  loan_product_id uuid NOT NULL REFERENCES loan_products(id),
  principal_amount numeric(12,2) NOT NULL CHECK (principal_amount > 0),
  member_savings_at_disbursement numeric(12,2) NOT NULL DEFAULT 0,
  covered_principal numeric(12,2) NOT NULL DEFAULT 0,
  surplus_principal numeric(12,2) NOT NULL DEFAULT 0,
  normal_interest_applied numeric(12,2) NOT NULL DEFAULT 0,
  surplus_interest_applied numeric(12,2) NOT NULL DEFAULT 0,
  total_interest numeric(12,2) NOT NULL DEFAULT 0,
  application_fee_charged numeric(12,2) NOT NULL DEFAULT 2000.00,
  total_repayable numeric(12,2) NOT NULL DEFAULT 0,
  monthly_instalment numeric(12,2) NOT NULL DEFAULT 0,
  term_months integer NOT NULL CHECK (term_months > 0),
  total_repaid numeric(12,2) NOT NULL DEFAULT 0 CHECK (total_repaid >= 0),
  instalments_paid integer NOT NULL DEFAULT 0 CHECK (instalments_paid >= 0),
  next_payment_due_date date,
  status text NOT NULL DEFAULT 'Pending'
    CHECK (status IN ('Pending','Approved','Disbursed','Active','Closed','Defaulted')),
  application_date date NOT NULL DEFAULT current_date,
  application_notes text,
  purpose text,
  approved_at timestamptz,
  approved_by uuid REFERENCES members(id),
  trustee_signoff_1 uuid REFERENCES members(id),
  trustee_signoff_2 uuid REFERENCES members(id),
  trustee_signoff_1_at timestamptz,
  trustee_signoff_2_at timestamptz,
  recorder_id uuid REFERENCES members(id),
  disbursed_by uuid REFERENCES members(id),
  disbursed_at timestamptz,
  override_credit_limit boolean NOT NULL DEFAULT false,
  override_reason text,
  override_by uuid REFERENCES members(id),
  override_at timestamptz,
  closed_at timestamptz,
  closed_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (covered_principal + surplus_principal = principal_amount),
  CHECK (total_interest = normal_interest_applied + surplus_interest_applied),
  CHECK (total_repayable = principal_amount + total_interest + application_fee_charged),
  CHECK (total_repaid <= total_repayable),
  CHECK (status <> 'Closed' OR closed_at IS NOT NULL)
);

CREATE INDEX idx_loans_member ON loans(member_id);
CREATE INDEX idx_loans_status ON loans(status);
CREATE INDEX idx_loans_due ON loans(next_payment_due_date);
CREATE INDEX idx_loans_product ON loans(loan_product_id);
CREATE INDEX idx_loans_application_date ON loans(application_date);

CREATE TRIGGER trg_loans_updated_at
BEFORE UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE loans ENABLE ROW LEVEL SECURITY;

CREATE POLICY loans_member_select ON loans
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY loans_management_select ON loans
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','LoanCommittee','ManagementCommittee','SystemAdmin'));

CREATE POLICY loans_member_insert ON loans
FOR INSERT WITH CHECK (
  app_member_id() = member_id AND status = 'Pending'
);

CREATE POLICY loans_committee_update ON loans
FOR UPDATE USING (app_role() IN ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin'))
WITH CHECK (app_role() IN ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin'));

-- ============================================================
-- 5. SURETIES
-- ============================================================

CREATE TABLE sureties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  surety_member_id uuid NOT NULL REFERENCES members(id),
  status text NOT NULL DEFAULT 'Pending'
    CHECK (status IN ('Pending','Accepted','Declined','Expired')),
  consent_given_at timestamptz,
  consent_ip inet,
  consent_user_agent text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (loan_id, surety_member_id)
);

CREATE INDEX idx_sureties_loan ON sureties(loan_id);
CREATE INDEX idx_sureties_member ON sureties(surety_member_id);
CREATE INDEX idx_sureties_status ON sureties(status);

CREATE TRIGGER trg_sureties_updated_at
BEFORE UPDATE ON sureties FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE sureties ENABLE ROW LEVEL SECURITY;

CREATE POLICY sureties_member_select ON sureties
FOR SELECT USING (app_member_id() = surety_member_id OR app_member_id() = (SELECT member_id FROM loans WHERE id = loan_id));

CREATE POLICY sureties_management_all ON sureties
FOR ALL USING (app_role() IN ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin'))
WITH CHECK (app_role() IN ('LoanCommittee','Treasurer','Chairman','Secretary','SystemAdmin'));

CREATE POLICY sureties_self_consent ON sureties
FOR UPDATE USING (app_member_id() = surety_member_id)
WITH CHECK (app_member_id() = surety_member_id);

-- ============================================================
-- 6. REPAYMENT SCHEDULE
-- ============================================================

CREATE TABLE loan_repayment_schedule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id uuid NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
  instalment_number integer NOT NULL CHECK (instalment_number > 0),
  due_date date NOT NULL,
  scheduled_amount numeric(12,2) NOT NULL CHECK (scheduled_amount > 0),
  amount_paid numeric(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  status text NOT NULL DEFAULT 'Pending'
    CHECK (status IN ('Pending','Partially Paid','Paid','Overdue','Waived')),
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (loan_id, instalment_number),
  CHECK (amount_paid <= scheduled_amount)
);

CREATE INDEX idx_schedule_loan_due ON loan_repayment_schedule(loan_id, due_date);
CREATE INDEX idx_schedule_status ON loan_repayment_schedule(status);

CREATE TRIGGER trg_schedule_updated_at
BEFORE UPDATE ON loan_repayment_schedule FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE loan_repayment_schedule ENABLE ROW LEVEL SECURITY;

CREATE POLICY schedule_member_select ON loan_repayment_schedule
FOR SELECT USING (app_member_id() = (SELECT member_id FROM loans WHERE id = loan_id));

CREATE POLICY schedule_management_select ON loan_repayment_schedule
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','LoanCommittee','ManagementCommittee','SystemAdmin'));

-- ============================================================
-- 7. UNIFIED PAYMENT NOTIFICATIONS / PENDING QUEUE
-- ============================================================

CREATE TABLE payment_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid REFERENCES members(id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  transaction_date date NOT NULL DEFAULT current_date,
  payment_reference text,
  bank_reference text,
  payment_narration text,
  sender_name text,
  sender_account text,
  evidence_url text,
  source text NOT NULL CHECK (source IN ('MANUAL','API')),
  match_confidence text CHECK (match_confidence IN ('EXACT','PARTIAL','NONE')),
  matched_by_api boolean NOT NULL DEFAULT false,
  api_response jsonb,
  status text NOT NULL DEFAULT 'Pending'
    CHECK (status IN ('Pending','Approved','Declined','Unidentified','Reversed')),
  proposed_savings_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (proposed_savings_amount >= 0),
  proposed_loan_allocations jsonb NOT NULL DEFAULT '[]'::jsonb,
  approved_by uuid REFERENCES members(id),
  approved_at timestamptz,
  decline_reason text,
  processed_at timestamptz,
  created_by uuid REFERENCES members(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (proposed_savings_amount <= amount)
);

CREATE INDEX idx_payment_queue_status_created ON payment_notifications(status, created_at);
CREATE INDEX idx_payment_queue_member ON payment_notifications(member_id);
CREATE INDEX idx_payment_queue_bank_ref ON payment_notifications(bank_reference);
CREATE INDEX idx_payment_queue_source ON payment_notifications(source);

CREATE TRIGGER trg_payment_notifications_updated_at
BEFORE UPDATE ON payment_notifications FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE payment_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY payment_queue_treasurer_select ON payment_notifications
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'));

CREATE POLICY payment_queue_member_select_own ON payment_notifications
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY payment_queue_member_insert ON payment_notifications
FOR INSERT WITH CHECK (
  source = 'MANUAL' AND app_member_id() = member_id AND created_by = app_member_id()
);

CREATE POLICY payment_queue_treasurer_update ON payment_notifications
FOR UPDATE USING (app_role() IN ('Treasurer','SystemAdmin'))
WITH CHECK (app_role() IN ('Treasurer','SystemAdmin'));

-- ============================================================
-- 8. PAYMENT ALLOCATIONS
-- ============================================================

CREATE TABLE payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_notification_id uuid NOT NULL REFERENCES payment_notifications(id) ON DELETE RESTRICT,
  member_id uuid NOT NULL REFERENCES members(id),
  destination_type text NOT NULL CHECK (destination_type IN ('SAVINGS','LOAN')),
  loan_id uuid REFERENCES loans(id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  ledger_entry_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((destination_type = 'SAVINGS' AND loan_id IS NULL)
      OR (destination_type = 'LOAN' AND loan_id IS NOT NULL)),
  UNIQUE (payment_notification_id, destination_type, loan_id)
);

CREATE INDEX idx_alloc_payment ON payment_allocations(payment_notification_id);
CREATE INDEX idx_alloc_loan ON payment_allocations(loan_id);
CREATE INDEX idx_alloc_member ON payment_allocations(member_id);

ALTER TABLE payment_allocations ENABLE ROW LEVEL SECURITY;

CREATE POLICY allocations_member_select ON payment_allocations
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY allocations_management_select ON payment_allocations
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin'));

-- ============================================================
-- 9. FINANCIAL LEDGER
-- ============================================================

CREATE TABLE ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES members(id),
  loan_id uuid REFERENCES loans(id),
  payment_notification_id uuid REFERENCES payment_notifications(id),
  transaction_date date NOT NULL DEFAULT current_date,
  transaction_type text NOT NULL CHECK (transaction_type IN (
    'CONTRIBUTION','LOAN_DISBURSEMENT','LOAN_REPAYMENT','FINE','WITHDRAWAL','REVERSAL','ENTRANCE_FEE','LOAN_FORM_SALE'
  )),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  payment_reference text,
  evidence_url text,
  source text NOT NULL CHECK (source IN ('MANUAL','API','SYSTEM')),
  match_confidence text CHECK (match_confidence IN ('EXACT','PARTIAL','NONE')),
  status text NOT NULL DEFAULT 'Approved' CHECK (status IN ('Approved','Declined')),
  approved_by uuid REFERENCES members(id),
  approved_at timestamptz NOT NULL DEFAULT now(),
  decline_reason text,
  parent_ledger_entry_id uuid REFERENCES ledger_entries(id),
  allocation_notes text,
  reversal_reason text,
  reversal_approved_by uuid REFERENCES members(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((transaction_type = 'LOAN_REPAYMENT' AND loan_id IS NOT NULL)
      OR (transaction_type <> 'LOAN_REPAYMENT')),
  CHECK (transaction_type <> 'REVERSAL' OR parent_ledger_entry_id IS NOT NULL),
  CHECK (transaction_type <> 'REVERSAL' OR reversal_reason IS NOT NULL)
);

CREATE INDEX idx_ledger_member ON ledger_entries(member_id, created_at);
CREATE INDEX idx_ledger_loan ON ledger_entries(loan_id, created_at);
CREATE INDEX idx_ledger_payment ON ledger_entries(payment_notification_id);
CREATE INDEX idx_ledger_type ON ledger_entries(transaction_type);

ALTER TABLE ledger_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY ledger_member_select ON ledger_entries
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY ledger_management_select ON ledger_entries
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin'));

-- No client INSERT/UPDATE/DELETE policy. Financial posting is performed only by
-- SECURITY DEFINER controlled functions below.

-- ============================================================
-- 10. UNIDENTIFIED DEPOSITS
-- ============================================================

CREATE TABLE unidentified_deposits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_notification_id uuid UNIQUE REFERENCES payment_notifications(id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  transaction_date date NOT NULL,
  bank_reference text,
  payment_narration text,
  sender_name text,
  sender_account text,
  source text NOT NULL CHECK (source IN ('MANUAL','API')),
  evidence_url text,
  api_response jsonb,
  status text NOT NULL DEFAULT 'Unclaimed'
    CHECK (status IN ('Unclaimed','Escalated','Resolved')),
  escalated_at timestamptz,
  escalation_reason text,
  escalated_by uuid REFERENCES members(id),
  resolved_at timestamptz,
  resolved_by uuid REFERENCES members(id),
  resolution_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_unidentified_status ON unidentified_deposits(status, created_at);

CREATE TRIGGER trg_unidentified_updated_at
BEFORE UPDATE ON unidentified_deposits FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE unidentified_deposits ENABLE ROW LEVEL SECURITY;

CREATE POLICY unidentified_management_all ON unidentified_deposits
FOR ALL USING (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'))
WITH CHECK (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'));

-- ============================================================
-- 11. WITHDRAWAL WORKFLOW
-- ============================================================

CREATE TABLE withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES members(id),
  withdrawal_type text NOT NULL CHECK (withdrawal_type IN ('RETIREMENT','TERMINATION','FINAL_EXIT')),
  requested_amount numeric(12,2) NOT NULL CHECK (requested_amount > 0),
  charge_amount numeric(12,2) NOT NULL DEFAULT 0 CHECK (charge_amount >= 0),
  net_amount numeric(12,2) NOT NULL CHECK (net_amount > 0),
  reason text,
  status text NOT NULL DEFAULT 'Pending'
    CHECK (status IN ('Pending','Approved','Declined','Processed')),
  trustee_1 uuid REFERENCES members(id),
  trustee_2 uuid REFERENCES members(id),
  recorder_id uuid REFERENCES members(id),
  approved_at timestamptz,
  processed_at timestamptz,
  decline_reason text,
  ledger_entry_id uuid REFERENCES ledger_entries(id),
  created_by uuid REFERENCES members(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_withdrawal_member ON withdrawal_requests(member_id);
CREATE INDEX idx_withdrawal_status ON withdrawal_requests(status);

CREATE TRIGGER trg_withdrawals_updated_at
BEFORE UPDATE ON withdrawal_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE withdrawal_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY withdrawals_member_select ON withdrawal_requests
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY withdrawals_management_select ON withdrawal_requests
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin'));

CREATE POLICY withdrawals_member_insert ON withdrawal_requests
FOR INSERT WITH CHECK (app_member_id() = member_id AND created_by = app_member_id());

CREATE POLICY withdrawals_management_update ON withdrawal_requests
FOR UPDATE USING (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'))
WITH CHECK (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'));

-- ============================================================
-- 12. CONTRIBUTION / FINE EVENTS
-- ============================================================

CREATE TABLE contribution_fine_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES members(id),
  fine_type text NOT NULL CHECK (fine_type IN ('MISSED_MONTH','DOWNWARD_REVISION')),
  contribution_month date,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  reason text NOT NULL,
  ledger_entry_id uuid REFERENCES ledger_entries(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(member_id, fine_type, contribution_month)
);

CREATE INDEX idx_fines_member_month ON contribution_fine_events(member_id, contribution_month);

ALTER TABLE contribution_fine_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY fines_member_select ON contribution_fine_events
FOR SELECT USING (app_member_id() = member_id);

CREATE POLICY fines_management_select ON contribution_fine_events
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin'));

-- ============================================================
-- 13. AUDIT LOG
-- ============================================================

CREATE TABLE audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid REFERENCES members(id),
  actor_role text,
  action text NOT NULL,
  resource_type text,
  resource_id uuid,
  details jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_actor ON audit_log(actor_id, created_at);
CREATE INDEX idx_audit_action ON audit_log(action, created_at);
CREATE INDEX idx_audit_resource ON audit_log(resource_type, resource_id);
CREATE INDEX idx_audit_created ON audit_log(created_at);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_read_management ON audit_log
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'));

-- Intentionally no client INSERT/UPDATE/DELETE policy.

CREATE OR REPLACE FUNCTION write_audit(
  p_action text,
  p_resource_type text DEFAULT NULL,
  p_resource_id uuid DEFAULT NULL,
  p_details jsonb DEFAULT '{}'::jsonb,
  p_actor_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.audit_log(actor_id, actor_role, action, resource_type, resource_id, details)
  VALUES (
    COALESCE(p_actor_id, app_member_id()),
    app_role(), p_action, p_resource_type, p_resource_id, COALESCE(p_details,'{}'::jsonb)
  ) RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================
-- 14. API / RECONCILIATION / IDEMPOTENCY
-- ============================================================

CREATE TABLE bank_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_date date NOT NULL,
  bank_reference text UNIQUE,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  description text,
  narration text,
  sender_name text,
  sender_account text,
  matched_to_payment_notification_id uuid REFERENCES payment_notifications(id),
  matched_to_ledger_entry_id uuid REFERENCES ledger_entries(id),
  matched_at timestamptz,
  matched_by uuid REFERENCES members(id),
  status text NOT NULL DEFAULT 'Unmatched'
    CHECK (status IN ('Unmatched','Matched','Manual','Unidentified')),
  source text NOT NULL CHECK (source IN ('API','MANUAL_IMPORT')),
  api_response jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_bank_tx_status_date ON bank_transactions(status, transaction_date);
CREATE INDEX idx_bank_tx_reference ON bank_transactions(bank_reference);

CREATE TRIGGER trg_bank_transactions_updated_at
BEFORE UPDATE ON bank_transactions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE bank_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY bank_tx_management_all ON bank_transactions
FOR ALL USING (app_role() IN ('Treasurer','SystemAdmin'))
WITH CHECK (app_role() IN ('Treasurer','SystemAdmin'));

CREATE TABLE idempotency_keys (
  key text PRIMARY KEY,
  request_path text NOT NULL,
  request_method text NOT NULL,
  request_body jsonb,
  response_data jsonb,
  response_status integer,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days')
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys(expires_at);
ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;
-- No authenticated client policy. Edge/server functions using service_role
-- handle idempotency records.

-- ============================================================
-- 15. NOTIFICATION / EVENT QUEUE
-- ============================================================

CREATE TABLE notification_queue (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recipient_member_id uuid REFERENCES members(id),
  recipient_email text,
  category text NOT NULL CHECK (category IN (
    'APPROVAL_REJECTION','REPAYMENT_REMINDER','MISSED_PAYMENT','SURETY_REQUEST',
    'PENDING_QUEUE','API_CREDIT','LOAN_DISBURSEMENT','EARLY_REPAYMENT','SYSTEM'
  )),
  subject text NOT NULL,
  body text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'Pending' CHECK (status IN ('Pending','Sent','Failed')),
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_notifications_pending ON notification_queue(status, created_at);
CREATE INDEX idx_notifications_recipient ON notification_queue(recipient_member_id);

CREATE TRIGGER trg_notifications_updated_at
BEFORE UPDATE ON notification_queue FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE notification_queue ENABLE ROW LEVEL SECURITY;

CREATE POLICY notifications_member_select ON notification_queue
FOR SELECT USING (app_member_id() = recipient_member_id);

CREATE POLICY notifications_management_select ON notification_queue
FOR SELECT USING (app_role() IN ('Treasurer','Chairman','Secretary','SystemAdmin'));

CREATE OR REPLACE FUNCTION queue_notification(
  p_member_id uuid,
  p_category text,
  p_subject text,
  p_body text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid; v_email text;
BEGIN
  SELECT email INTO v_email FROM members WHERE id = p_member_id;
  INSERT INTO notification_queue(recipient_member_id,recipient_email,category,subject,body,payload)
  VALUES(p_member_id,v_email,p_category,p_subject,p_body,COALESCE(p_payload,'{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================
-- 16. FINANCIAL BALANCE FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION get_member_savings_balance(p_member_id uuid)
RETURNS numeric(12,2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(0, COALESCE(SUM(CASE
    WHEN le.transaction_type IN ('CONTRIBUTION','ENTRANCE_FEE') THEN le.amount
    WHEN le.transaction_type IN ('FINE','WITHDRAWAL') THEN -le.amount
    WHEN le.transaction_type = 'REVERSAL' THEN
      CASE WHEN parent.transaction_type IN ('CONTRIBUTION','ENTRANCE_FEE') THEN -le.amount
           WHEN parent.transaction_type IN ('FINE','WITHDRAWAL') THEN le.amount
           ELSE 0 END
    ELSE 0 END),0))::numeric(12,2)
  FROM ledger_entries le
  LEFT JOIN ledger_entries parent ON parent.id=le.parent_ledger_entry_id
  WHERE le.member_id = p_member_id AND le.status='Approved' AND le.loan_id IS NULL;
$$;

CREATE OR REPLACE FUNCTION get_loan_outstanding_balance(p_loan_id uuid)
RETURNS numeric(12,2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT GREATEST(0, total_repayable - total_repaid)::numeric(12,2)
  FROM loans WHERE id = p_loan_id;
$$;

CREATE OR REPLACE FUNCTION get_member_total_outstanding_loans(p_member_id uuid)
RETURNS numeric(12,2)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(GREATEST(0,total_repayable-total_repaid)),0)::numeric(12,2)
  FROM loans
  WHERE member_id=p_member_id AND status IN ('Disbursed','Active','Defaulted');
$$;

-- ============================================================
-- 17. CONTRIBUTION ELIGIBILITY / REVISION
-- ============================================================

CREATE OR REPLACE FUNCTION request_contribution_revision(
  p_member_id uuid,
  p_new_amount numeric(12,2)
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_old numeric(12,2); v_fine_id uuid;
BEGIN
  IF app_member_id() IS DISTINCT FROM p_member_id AND app_role() NOT IN ('Treasurer','SystemAdmin') THEN
    RAISE EXCEPTION 'Not authorised';
  END IF;

  SELECT standing_contribution_amount INTO v_old FROM members WHERE id=p_member_id FOR UPDATE;
  IF v_old IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;

  IF p_new_amount < 10000 THEN
    RAISE EXCEPTION 'Minimum monthly contribution is N10,000';
  END IF;

  IF extract(month FROM current_date) NOT IN (1,7) THEN
    RAISE EXCEPTION 'Contribution authority form is editable only in January or July';
  END IF;

  IF p_new_amount < v_old THEN
    INSERT INTO ledger_entries(member_id,transaction_type,amount,source,status,approved_by,allocation_notes)
    VALUES(p_member_id,'FINE',2000,'SYSTEM','Approved',app_member_id(),'N2,000 fine for attempted unauthorised downward contribution revision')
    RETURNING id INTO v_fine_id;

    INSERT INTO contribution_fine_events(member_id,fine_type,amount,reason,ledger_entry_id)
    VALUES(p_member_id,'DOWNWARD_REVISION',2000,'Unauthorised downward contribution revision',v_fine_id);

    PERFORM write_audit('DOWNWARD_CONTRIBUTION_REVISION_REJECTED','member',p_member_id,
      jsonb_build_object('old_amount',v_old,'requested_amount',p_new_amount,'fine',2000));
    RETURN jsonb_build_object('accepted',false,'fine_amount',2000,'reason','Revision rejected; N2,000 fine applied');
  END IF;

  UPDATE members
  SET standing_contribution_amount=p_new_amount,
      contribution_authority_form_date=current_date,
      contribution_authority_reviewed=true
  WHERE id=p_member_id;

  PERFORM write_audit('UPDATE_CONTRIBUTION_AUTHORITY','member',p_member_id,
    jsonb_build_object('old_amount',v_old,'new_amount',p_new_amount));

  RETURN jsonb_build_object('accepted',true,'new_amount',p_new_amount);
END;
$$;

CREATE OR REPLACE FUNCTION member_has_six_consecutive_months(p_member_id uuid, p_as_of date DEFAULT current_date)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_start date; v_month date; v_count integer;
BEGIN
  SELECT first_contribution_date INTO v_start FROM members WHERE id=p_member_id;
  IF v_start IS NULL THEN RETURN false; END IF;
  v_start := date_trunc('month',v_start)::date;
  IF v_start > date_trunc('month',p_as_of)::date - interval '5 months' THEN RETURN false; END IF;

  SELECT count(*) INTO v_count
  FROM generate_series(date_trunc('month',p_as_of)::date - interval '5 months', date_trunc('month',p_as_of)::date, interval '1 month') gs(month_start)
  WHERE EXISTS (
    SELECT 1 FROM ledger_entries le
    WHERE le.member_id=p_member_id AND le.transaction_type='CONTRIBUTION'
      AND le.status='Approved'
      AND date_trunc('month',le.transaction_date)::date = gs.month_start::date
      AND le.amount >= 10000
  );
  RETURN v_count = 6;
END;
$$;

-- ============================================================
-- 18. LOAN TERM CALCULATION
-- ============================================================

CREATE OR REPLACE FUNCTION calculate_loan_terms(
  p_member_id uuid,
  p_loan_product_id uuid,
  p_principal numeric(12,2),
  p_term_months integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_savings numeric(12,2);
  v_normal numeric(5,2); v_surplus numeric(5,2); v_fee numeric(12,2);
  v_min integer; v_max integer; v_name text;
  v_covered numeric(12,2); v_surplus_pr numeric(12,2);
  v_i1 numeric(12,2); v_i2 numeric(12,2); v_total_i numeric(12,2);
  v_total numeric(12,2); v_monthly numeric(12,2);
BEGIN
  IF p_principal <= 0 THEN RAISE EXCEPTION 'Principal must be greater than zero'; END IF;
  SELECT get_member_savings_balance(p_member_id) INTO v_savings;
  SELECT name,normal_interest_rate,surplus_interest_rate,application_fee,min_term_months,max_term_months
    INTO v_name,v_normal,v_surplus,v_fee,v_min,v_max
  FROM loan_products WHERE id=p_loan_product_id AND is_active=true;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Loan product not found or inactive'; END IF;

  IF p_term_months < v_min OR p_term_months > v_max THEN
    RAISE EXCEPTION 'Term must be between % and % months for %',v_min,v_max,v_name;
  END IF;
  IF v_name IN ('Short-Term','Emergency') THEN
    IF p_principal > 300000 AND p_term_months <> 10 THEN
      RAISE EXCEPTION 'Short-Term/Emergency loans above N300,000 require a 10-month term';
    END IF;
    IF p_principal <= 300000 AND p_term_months > 6 THEN
      RAISE EXCEPTION 'Short-Term/Emergency loans of N300,000 or less must be repayable within 6 months';
    END IF;
  END IF;

  v_covered := least(p_principal,v_savings);
  v_surplus_pr := greatest(0,p_principal-v_savings);
  v_i1 := round(v_covered*(v_normal/100)*(p_term_months/12.0),2);
  v_i2 := round(v_surplus_pr*(v_surplus/100)*(p_term_months/12.0),2);
  v_total_i := v_i1+v_i2;
  v_total := p_principal+v_total_i+v_fee;
  v_monthly := round(v_total/p_term_months,2);

  RETURN jsonb_build_object(
    'product',v_name,'savings_balance',v_savings,'covered_principal',v_covered,
    'surplus_principal',v_surplus_pr,'normal_rate',v_normal,'surplus_rate',v_surplus,
    'interest_covered',v_i1,'interest_surplus',v_i2,'total_interest',v_total_i,
    'application_fee',v_fee,'total_repayable',v_total,'monthly_instalment',v_monthly,
    'term_months',p_term_months
  );
END;
$$;

-- ============================================================
-- 19. MEMBER ADMISSION WORKFLOW
-- ============================================================

CREATE OR REPLACE FUNCTION decide_member_application(
  p_member_id uuid,
  p_approve boolean,
  p_rejection_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_role text := app_role();
BEGIN
  IF v_role NOT IN ('ManagementCommittee','SystemAdmin') THEN
    RAISE EXCEPTION 'Only Management Committee/SystemAdmin may decide membership applications';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM members WHERE id=p_member_id AND status='Applicant') THEN
    RAISE EXCEPTION 'Applicant not found or already decided';
  END IF;
  IF NOT p_approve AND NULLIF(trim(p_rejection_reason),'') IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required';
  END IF;

  UPDATE members SET
    status = CASE WHEN p_approve THEN 'Applicant' ELSE 'Exited' END,
    admission_decision_at=now(), admission_decision_by=app_member_id(),
    admission_rejection_reason=CASE WHEN p_approve THEN NULL ELSE p_rejection_reason END
  WHERE id=p_member_id;

  PERFORM write_audit(CASE WHEN p_approve THEN 'APPROVE_MEMBER' ELSE 'REJECT_MEMBER' END,
    'member',p_member_id,jsonb_build_object('reason',p_rejection_reason));

  PERFORM queue_notification(p_member_id,'APPROVAL_REJECTION',
    CASE WHEN p_approve THEN 'Membership application approved' ELSE 'Membership application rejected' END,
    CASE WHEN p_approve THEN 'Your membership application has been approved. Your membership becomes Active after your first contribution.'
         ELSE 'Your membership application was rejected. Reason: '||p_rejection_reason END);

  RETURN jsonb_build_object('success',true,'approved',p_approve);
END;
$$;

CREATE OR REPLACE FUNCTION activate_member_after_first_contribution(p_member_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE members m
  SET status='Active',
      first_contribution_date=COALESCE(m.first_contribution_date,
        (SELECT min(le.transaction_date) FROM ledger_entries le
         WHERE le.member_id=m.id AND le.transaction_type='CONTRIBUTION' AND le.status='Approved')),
      admission_date=COALESCE(m.admission_date,current_date)
  WHERE m.id=p_member_id AND m.status='Applicant'
    AND m.admission_decision_at IS NOT NULL
    AND EXISTS(SELECT 1 FROM ledger_entries le
               WHERE le.member_id=m.id AND le.transaction_type='CONTRIBUTION' AND le.status='Approved');
END;
$$;

-- ============================================================
-- 20. LOAN APPLICATION / APPROVAL
-- ============================================================

CREATE OR REPLACE FUNCTION validate_loan_application(p_loan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  l loans%ROWTYPE; p loan_products%ROWTYPE; v_count integer; v_savings numeric(12,2);
  fy_start date; fy_end date; v_existing numeric(12,2); v_member_status text;
BEGIN
  SELECT * INTO l FROM loans WHERE id=p_loan_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Loan not found'; END IF;
  SELECT * INTO p FROM loan_products WHERE id=l.loan_product_id;
  SELECT status INTO v_member_status FROM members WHERE id=l.member_id;
  IF v_member_status IS NULL THEN RAISE EXCEPTION 'Member not found'; END IF;
  IF v_member_status <> 'Active' THEN RAISE EXCEPTION 'Member must be Active'; END IF;
  IF l.status <> 'Pending' THEN RAISE EXCEPTION 'Only pending loans may be validated'; END IF;

  IF NOT member_has_six_consecutive_months(l.member_id,l.application_date) THEN
    RAISE EXCEPTION 'Member must have six consecutive months of active contributions before first loan';
  END IF;

  IF p.name IN ('Short-Term','Emergency') THEN
    fy_start := financial_year_start(l.application_date); fy_end := financial_year_end(l.application_date);
    SELECT count(*) INTO v_count FROM loans
    WHERE member_id=l.member_id AND loan_product_id=l.loan_product_id
      AND application_date BETWEEN fy_start AND fy_end
      AND status IN ('Approved','Disbursed','Active','Closed','Defaulted');
    IF v_count >= p.max_per_financial_year THEN
      RAISE EXCEPTION 'Maximum % % loans per financial year has been reached',p.max_per_financial_year,p.name;
    END IF;
  END IF;

  v_savings := get_member_savings_balance(l.member_id);
  SELECT get_member_total_outstanding_loans(l.member_id) INTO v_existing;
  IF NOT l.override_credit_limit AND v_existing + l.principal_amount > v_savings THEN
    RAISE EXCEPTION 'Credit limit exceeded: existing outstanding % + requested % > savings %',v_existing,l.principal_amount,v_savings;
  END IF;

  IF l.override_credit_limit THEN
    IF app_role() NOT IN ('LoanCommittee','SystemAdmin') THEN
      RAISE EXCEPTION 'Only Loan Committee may override the maximum credit limit';
    END IF;
    IF NULLIF(trim(l.override_reason),'') IS NULL THEN RAISE EXCEPTION 'Override reason is required'; END IF;
  END IF;

  IF p.requires_sureties THEN
    SELECT count(*) INTO v_count FROM sureties WHERE loan_id=l.id AND status='Accepted';
    IF v_count <> p.number_of_sureties_required THEN
      RAISE EXCEPTION 'Exactly % accepted sureties are required; found %',p.number_of_sureties_required,v_count;
    END IF;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION approve_loan(p_loan_id uuid, p_override_credit_limit boolean DEFAULT false, p_override_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE l loans%ROWTYPE; v_role text:=app_role();
BEGIN
  IF v_role NOT IN ('LoanCommittee','SystemAdmin') THEN RAISE EXCEPTION 'Only Loan Committee may approve loans'; END IF;
  SELECT * INTO l FROM loans WHERE id=p_loan_id FOR UPDATE;
  IF l.status <> 'Pending' THEN RAISE EXCEPTION 'Loan is not pending'; END IF;

  IF p_override_credit_limit THEN
    UPDATE loans SET override_credit_limit=true, override_reason=p_override_reason,
      override_by=app_member_id(), override_at=now() WHERE id=p_loan_id;
  END IF;

  PERFORM validate_loan_application(p_loan_id);
  UPDATE loans SET status='Approved', approved_at=now(), approved_by=app_member_id() WHERE id=p_loan_id;
  PERFORM write_audit('APPROVE_LOAN','loan',p_loan_id,jsonb_build_object('override',p_override_credit_limit));
  PERFORM queue_notification(l.member_id,'APPROVAL_REJECTION','Loan application approved','Your loan application has been approved and is awaiting disbursement.');
  RETURN jsonb_build_object('success',true,'loan_id',p_loan_id);
END;
$$;

-- ============================================================
-- 21. TRUSTEE SIGN-OFF AND ATOMIC LOAN DISBURSEMENT
-- ============================================================

CREATE OR REPLACE FUNCTION record_loan_trustee_signoff(p_loan_id uuid, p_signoff_number integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid:=app_member_id(); v_role text:=app_role(); l loans%ROWTYPE;
BEGIN
  IF v_role NOT IN ('Chairman','Secretary','Treasurer') THEN RAISE EXCEPTION 'Only the three trustees may sign off a disbursement'; END IF;
  IF p_signoff_number NOT IN (1,2) THEN RAISE EXCEPTION 'Sign-off number must be 1 or 2'; END IF;
  SELECT * INTO l FROM loans WHERE id=p_loan_id FOR UPDATE;
  IF l.status <> 'Approved' THEN RAISE EXCEPTION 'Loan must be approved before trustee sign-off'; END IF;

  IF p_signoff_number=1 THEN
    IF l.trustee_signoff_2=v_id THEN RAISE EXCEPTION 'Two signatories must be different trustees'; END IF;
    UPDATE loans SET trustee_signoff_1=v_id, trustee_signoff_1_at=now() WHERE id=p_loan_id;
  ELSE
    IF l.trustee_signoff_1=v_id THEN RAISE EXCEPTION 'Two signatories must be different trustees'; END IF;
    UPDATE loans SET trustee_signoff_2=v_id, trustee_signoff_2_at=now() WHERE id=p_loan_id;
  END IF;

  PERFORM write_audit('LOAN_TRUSTEE_SIGNOFF','loan',p_loan_id,jsonb_build_object('signoff_number',p_signoff_number));
  RETURN jsonb_build_object('success',true,'signoff_number',p_signoff_number);
END;
$$;

CREATE OR REPLACE FUNCTION disburse_loan(p_loan_id uuid, p_recorder_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  l loans%ROWTYPE; p loan_products%ROWTYPE; v_savings numeric(12,2);
  v_covered numeric(12,2); v_surplus numeric(12,2); v_i1 numeric(12,2); v_i2 numeric(12,2);
  v_total_i numeric(12,2); v_total numeric(12,2); v_monthly numeric(12,2);
  v_recorder uuid:=COALESCE(p_recorder_id,app_member_id()); v_sign1 uuid; v_sign2 uuid;
  i integer; v_due date; v_amount numeric(12,2); v_last numeric(12,2);
  v_ledger uuid;
BEGIN
  SELECT * INTO l FROM loans WHERE id=p_loan_id FOR UPDATE;
  IF l.status <> 'Approved' THEN RAISE EXCEPTION 'Only approved loans may be disbursed'; END IF;
  SELECT * INTO p FROM loan_products WHERE id=l.loan_product_id;
  IF p.requires_sureties AND (SELECT count(*) FROM sureties WHERE loan_id=l.id AND status='Accepted') <> p.number_of_sureties_required THEN
    RAISE EXCEPTION 'Exactly % accepted sureties are required',p.number_of_sureties_required;
  END IF;

  v_sign1:=l.trustee_signoff_1; v_sign2:=l.trustee_signoff_2;
  IF v_sign1 IS NULL OR v_sign2 IS NULL OR v_sign1=v_sign2 THEN RAISE EXCEPTION 'Two different trustee sign-offs are required'; END IF;
  IF NOT is_trustee(v_sign1) OR NOT is_trustee(v_sign2) THEN RAISE EXCEPTION 'Signatories must be Chairman, Secretary or Treasurer'; END IF;
  IF v_recorder IS NULL THEN RAISE EXCEPTION 'Recorder is required'; END IF;
  IF v_recorder=v_sign2 OR v_recorder=v_sign1 THEN RAISE EXCEPTION 'Treasurer/recorder cannot be one of the final signatories'; END IF;

  -- Capture savings at the exact disbursement point and calculate tiers atomically.
  PERFORM 1 FROM members WHERE id=l.member_id FOR UPDATE;
  v_savings:=get_member_savings_balance(l.member_id);
  v_covered:=least(l.principal_amount,v_savings);
  v_surplus:=greatest(0,l.principal_amount-v_savings);
  v_i1:=round(v_covered*(p.normal_interest_rate/100)*(l.term_months/12.0),2);
  v_i2:=round(v_surplus*(p.surplus_interest_rate/100)*(l.term_months/12.0),2);
  v_total_i:=v_i1+v_i2;
  v_total:=l.principal_amount+v_total_i+p.application_fee;
  v_monthly:=round(v_total/l.term_months,2);

  UPDATE loans SET
    member_savings_at_disbursement=v_savings,
    covered_principal=v_covered, surplus_principal=v_surplus,
    normal_interest_applied=v_i1, surplus_interest_applied=v_i2,
    total_interest=v_total_i, application_fee_charged=p.application_fee,
    total_repayable=v_total, monthly_instalment=v_monthly,
    total_repaid=0, instalments_paid=0,
    next_payment_due_date=(current_date + interval '1 month')::date,
    status='Active', recorder_id=v_recorder, disbursed_by=app_member_id(), disbursed_at=now()
  WHERE id=l.id;

  -- Fixed schedule. The final instalment absorbs rounding remainder.
  v_last:=round(v_total-v_monthly*(l.term_months-1),2);
  FOR i IN 1..l.term_months LOOP
    v_due := (current_date + (i || ' month')::interval)::date;
    v_amount := CASE WHEN i=l.term_months THEN v_last ELSE v_monthly END;
    INSERT INTO loan_repayment_schedule(loan_id,instalment_number,due_date,scheduled_amount)
    VALUES(l.id,i,v_due,v_amount);
  END LOOP;

  INSERT INTO ledger_entries(member_id,loan_id,transaction_type,amount,source,status,approved_by,approved_at,allocation_notes)
  VALUES(l.member_id,l.id,'LOAN_DISBURSEMENT',l.principal_amount,'SYSTEM','Approved',app_member_id(),now(),
         'Loan principal disbursed; interest and application fee capitalised into total repayable')
  RETURNING id INTO v_ledger;

  PERFORM write_audit('DISBURSE_LOAN','loan',l.id,jsonb_build_object(
    'principal',l.principal_amount,'savings_at_disbursement',v_savings,
    'covered_principal',v_covered,'surplus_principal',v_surplus,
    'interest_covered',v_i1,'interest_surplus',v_i2,'total_repayable',v_total,
    'monthly_instalment',v_monthly,'signatory_1',v_sign1,'signatory_2',v_sign2,
    'recorder',v_recorder,'ledger_entry',v_ledger));

  PERFORM queue_notification(l.member_id,'LOAN_DISBURSEMENT','Loan disbursed',
    'Your loan has been disbursed. Fixed monthly instalment: N'||to_char(v_monthly,'FM999,999,990.00')||'. Term: '||l.term_months||' months.',
    jsonb_build_object('loan_id',l.id,'monthly_instalment',v_monthly,'term_months',l.term_months));

  RETURN jsonb_build_object('success',true,'loan_id',l.id,'total_repayable',v_total,'monthly_instalment',v_monthly);
END;
$$;

-- ============================================================
-- 22. UNIFIED PAYMENT SUBMISSION / PROPOSAL
-- ============================================================

CREATE OR REPLACE FUNCTION submit_payment_notification(
  p_member_id uuid,
  p_amount numeric(12,2),
  p_payment_reference text DEFAULT NULL,
  p_evidence_url text DEFAULT NULL,
  p_proposed_savings numeric(12,2) DEFAULT 0,
  p_proposed_loans jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid; r record; v_sum numeric(12,2):=COALESCE(p_proposed_savings,0); v_status text;
BEGIN
  IF app_member_id() IS DISTINCT FROM p_member_id AND app_role() NOT IN ('Treasurer','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  SELECT status INTO v_status FROM members WHERE id=p_member_id;
  IF v_status <> 'Active' THEN RAISE EXCEPTION 'Only Active members may submit payments'; END IF;
  IF p_amount <= 0 OR p_proposed_savings < 0 THEN RAISE EXCEPTION 'Invalid amount'; END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(COALESCE(p_proposed_loans,'[]'::jsonb)) x(loan_id uuid, amount numeric(12,2)) LOOP
    IF r.amount <= 0 THEN RAISE EXCEPTION 'Loan allocation must be positive'; END IF;
    IF NOT EXISTS(SELECT 1 FROM loans WHERE id=r.loan_id AND member_id=p_member_id AND status IN ('Active','Disbursed')) THEN
      RAISE EXCEPTION 'Selected loan does not belong to member or is not active';
    END IF;
    v_sum:=v_sum+r.amount;
  END LOOP;
  IF v_sum <> p_amount THEN RAISE EXCEPTION 'Proposed allocation total % must equal payment amount %',v_sum,p_amount; END IF;

  INSERT INTO payment_notifications(member_id,amount,payment_reference,evidence_url,source,
    match_confidence,proposed_savings_amount,proposed_loan_allocations,created_by)
  VALUES(p_member_id,p_amount,p_payment_reference,p_evidence_url,'MANUAL','NONE',
    p_proposed_savings,COALESCE(p_proposed_loans,'[]'::jsonb),app_member_id())
  RETURNING id INTO v_id;

  PERFORM write_audit('CREATE_PAYMENT_NOTIFICATION','payment_notification',v_id,jsonb_build_object('amount',p_amount,'source','MANUAL'));
  PERFORM queue_notification(p_member_id,'PENDING_QUEUE','Payment submitted','Your payment has been submitted and is awaiting Treasurer approval.',jsonb_build_object('payment_notification_id',v_id));
  RETURN v_id;
END;
$$;

-- API credits use this same table/queue. This function is intended for a
-- server-side Edge Function using service_role, not direct browser clients.
CREATE OR REPLACE FUNCTION ingest_api_credit(
  p_amount numeric(12,2), p_transaction_date date, p_bank_reference text,
  p_narration text, p_sender_name text DEFAULT NULL, p_sender_account text DEFAULT NULL,
  p_member_id uuid DEFAULT NULL, p_match_confidence text DEFAULT 'NONE', p_api_response jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO payment_notifications(member_id,amount,transaction_date,bank_reference,payment_narration,
    sender_name,sender_account,source,match_confidence,matched_by_api,api_response,created_by)
  VALUES(p_member_id,p_amount,p_transaction_date,p_bank_reference,p_narration,p_sender_name,p_sender_account,
    'API',p_match_confidence,true,p_api_response,NULL)
  RETURNING id INTO v_id;

  PERFORM write_audit('API_CREDIT_RECEIVED','payment_notification',v_id,jsonb_build_object(
    'bank_reference',p_bank_reference,'amount',p_amount,'match_confidence',p_match_confidence));
  IF p_member_id IS NOT NULL THEN
    PERFORM queue_notification(p_member_id,'API_CREDIT','Bank credit detected','A bank credit has been detected and is awaiting Treasurer approval.',jsonb_build_object('payment_notification_id',v_id));
  END IF;
  RETURN v_id;
EXCEPTION WHEN OTHERS THEN
  PERFORM write_audit('API_ERROR',NULL,NULL,jsonb_build_object('error',SQLERRM,'bank_reference',p_bank_reference));
  RAISE;
END;
$$;

-- ============================================================
-- 23. TREASURER APPROVAL + SPLIT ALLOCATION (ATOMIC)
-- ============================================================

CREATE OR REPLACE FUNCTION approve_payment_with_split(
  p_payment_notification_id uuid,
  p_savings_allocation numeric(12,2),
  p_loan_allocations jsonb DEFAULT '[]'::jsonb,
  p_match_override_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  n payment_notifications%ROWTYPE; r record; v_sum numeric(12,2):=COALESCE(p_savings_allocation,0);
  v_out numeric(12,2); v_member uuid; v_ledger uuid; v_alloc_id uuid; v_repaid numeric(12,2);
  v_remaining numeric(12,2); v_paid numeric(12,2); v_inst integer; v_early boolean;
  v_loan loans%ROWTYPE;
BEGIN
  IF app_role() <> 'Treasurer' THEN RAISE EXCEPTION 'Only Treasurer may approve and allocate payments'; END IF;
  SELECT * INTO n FROM payment_notifications WHERE id=p_payment_notification_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment notification not found'; END IF;
  IF n.status <> 'Pending' THEN RAISE EXCEPTION 'Payment notification is not pending'; END IF;
  v_member:=COALESCE(p_match_override_member_id,n.member_id);
  IF v_member IS NULL THEN
    UPDATE payment_notifications SET status='Unidentified',processed_at=now() WHERE id=n.id;
    INSERT INTO unidentified_deposits(payment_notification_id,amount,transaction_date,bank_reference,payment_narration,sender_name,sender_account,source,evidence_url,api_response)
    VALUES(n.id,n.amount,n.transaction_date,n.bank_reference,n.payment_narration,n.sender_name,n.sender_account,n.source,n.evidence_url,n.api_response)
    ON CONFLICT(payment_notification_id) DO NOTHING;
    PERFORM write_audit('MOVE_TO_UNIDENTIFIED','payment_notification',n.id,jsonb_build_object('reason','No member match'));
    RETURN jsonb_build_object('success',true,'status','Unidentified');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM members WHERE id=v_member) THEN RAISE EXCEPTION 'Matched member not found'; END IF;
  IF (SELECT status FROM members WHERE id=v_member) <> 'Active' THEN RAISE EXCEPTION 'Matched member is not Active'; END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(COALESCE(p_loan_allocations,'[]'::jsonb)) x(loan_id uuid, amount numeric(12,2)) LOOP
    IF r.amount <= 0 THEN RAISE EXCEPTION 'Loan allocation must be positive'; END IF;
    SELECT * INTO v_loan FROM loans WHERE id=r.loan_id FOR UPDATE;
    IF NOT FOUND OR v_loan.member_id<>v_member OR v_loan.status NOT IN ('Active','Disbursed') THEN
      RAISE EXCEPTION 'Loan % is not an active loan of the matched member',r.loan_id;
    END IF;
    v_out:=v_loan.total_repayable-v_loan.total_repaid;
    IF r.amount > v_out THEN
      RAISE EXCEPTION 'Allocation N% exceeds current outstanding N% for loan %',r.amount,v_out,v_loan.loan_reference;
    END IF;
    v_sum:=v_sum+r.amount;
  END LOOP;
  IF v_sum <> n.amount THEN RAISE EXCEPTION 'Allocation total N% must equal payment amount N%',v_sum,n.amount; END IF;

  UPDATE payment_notifications SET member_id=v_member, status='Approved',approved_by=app_member_id(),approved_at=now(),processed_at=now() WHERE id=n.id;

  IF p_savings_allocation>0 THEN
    INSERT INTO ledger_entries(member_id,payment_notification_id,transaction_type,amount,payment_reference,evidence_url,source,match_confidence,status,approved_by,allocation_notes)
    VALUES(v_member,n.id,'CONTRIBUTION',p_savings_allocation,n.payment_reference,n.evidence_url,n.source,n.match_confidence,'Approved',app_member_id(),'Treasurer-approved savings allocation')
    RETURNING id INTO v_ledger;
    INSERT INTO payment_allocations(payment_notification_id,member_id,destination_type,amount,ledger_entry_id)
    VALUES(n.id,v_member,'SAVINGS',p_savings_allocation,v_ledger);
    PERFORM activate_member_after_first_contribution(v_member);
  END IF;

  FOR r IN SELECT * FROM jsonb_to_recordset(COALESCE(p_loan_allocations,'[]'::jsonb)) x(loan_id uuid, amount numeric(12,2)) LOOP
    SELECT * INTO v_loan FROM loans WHERE id=r.loan_id FOR UPDATE;
    v_out:=v_loan.total_repayable-v_loan.total_repaid;
    IF r.amount > v_out THEN RAISE EXCEPTION 'Concurrent allocation would overpay loan %',v_loan.loan_reference; END IF;

    INSERT INTO ledger_entries(member_id,loan_id,payment_notification_id,transaction_type,amount,payment_reference,evidence_url,source,match_confidence,status,approved_by,allocation_notes)
    VALUES(v_member,r.loan_id,n.id,'LOAN_REPAYMENT',r.amount,n.payment_reference,n.evidence_url,n.source,n.match_confidence,'Approved',app_member_id(),'Treasurer-approved loan repayment allocation')
    RETURNING id INTO v_ledger;

    INSERT INTO payment_allocations(payment_notification_id,member_id,destination_type,loan_id,amount,ledger_entry_id)
    VALUES(n.id,v_member,'LOAN',r.loan_id,r.amount,v_ledger);

    v_repaid:=v_loan.total_repaid+r.amount;
    UPDATE loans SET total_repaid=v_repaid WHERE id=r.loan_id;

    -- Allocate repayment to the earliest unpaid schedule rows.
    v_remaining:=r.amount;
    FOR v_inst IN SELECT instalment_number FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND amount_paid<scheduled_amount ORDER BY instalment_number FOR UPDATE LOOP
      EXIT WHEN v_remaining<=0;
      SELECT scheduled_amount-amount_paid INTO v_out FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND instalment_number=v_inst FOR UPDATE;
      v_paid:=LEAST(v_remaining,v_out);
      UPDATE loan_repayment_schedule SET amount_paid=amount_paid+v_paid,
        status=CASE WHEN amount_paid+v_paid>=scheduled_amount THEN 'Paid' ELSE 'Partially Paid' END,
        paid_at=CASE WHEN amount_paid+v_paid>=scheduled_amount THEN now() ELSE paid_at END
      WHERE loan_id=r.loan_id AND instalment_number=v_inst;
      v_remaining:=v_remaining-v_paid;
    END LOOP;

    SELECT * INTO v_loan FROM loans WHERE id=r.loan_id;
    v_early := v_repaid=v_loan.total_repayable;
    IF v_early THEN
      UPDATE loans SET status='Closed',closed_at=now(),closed_reason=CASE WHEN (SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND status='Paid') < term_months THEN 'Closed (Early Repayment)' ELSE 'Fully repaid' END,next_payment_due_date=NULL WHERE id=r.loan_id;
      PERFORM queue_notification(v_member,'EARLY_REPAYMENT','Loan closed','Loan '||v_loan.loan_reference||' has been fully repaid.',jsonb_build_object('loan_id',r.loan_id,'amount',r.amount));
    ELSE
      UPDATE loans SET instalments_paid=(SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND status='Paid'),
        next_payment_due_date=(SELECT min(due_date) FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND status<>'Paid')
      WHERE id=r.loan_id;
    END IF;
  END LOOP;

  PERFORM write_audit('APPROVE_TRANSACTION','payment_notification',n.id,jsonb_build_object(
    'total_amount',n.amount,'savings_allocation',p_savings_allocation,'loan_allocations',p_loan_allocations,
    'matched_member',v_member,'match_override',p_match_override_member_id IS NOT NULL));

  RETURN jsonb_build_object('success',true,'payment_notification_id',n.id,'member_id',v_member,'amount',n.amount);
END;
$$;

CREATE OR REPLACE FUNCTION decline_payment(p_payment_notification_id uuid,p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n payment_notifications%ROWTYPE;
BEGIN
  IF app_role()<>'Treasurer' THEN RAISE EXCEPTION 'Only Treasurer may decline payments'; END IF;
  IF NULLIF(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Decline reason is required'; END IF;
  SELECT * INTO n FROM payment_notifications WHERE id=p_payment_notification_id FOR UPDATE;
  IF n.status<>'Pending' THEN RAISE EXCEPTION 'Payment is not pending'; END IF;
  UPDATE payment_notifications SET status='Declined',decline_reason=p_reason,approved_by=app_member_id(),approved_at=now(),processed_at=now() WHERE id=n.id;
  IF n.member_id IS NOT NULL THEN
    PERFORM queue_notification(n.member_id,'APPROVAL_REJECTION','Payment declined','Your payment was declined. Reason: '||p_reason);
  END IF;
  PERFORM write_audit('DECLINE_TRANSACTION','payment_notification',n.id,jsonb_build_object('reason',p_reason));
END;
$$;

-- ============================================================
-- 24. REVERSAL / CORRECTION WORKFLOW
-- ============================================================

CREATE OR REPLACE FUNCTION reverse_ledger_entry(p_ledger_entry_id uuid,p_reason text,p_second_approver uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE e ledger_entries%ROWTYPE; v_id uuid; v_actor uuid:=app_member_id(); v_actor_role text:=app_role();
BEGIN
  IF v_actor_role NOT IN ('Treasurer','Chairman','Secretary','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised to reverse transactions'; END IF;
  IF NULLIF(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Reversal reason is required'; END IF;
  IF p_second_approver IS NULL OR p_second_approver=v_actor THEN RAISE EXCEPTION 'A different second approver is required'; END IF;
  IF NOT is_trustee(p_second_approver) AND app_role()<>'SystemAdmin' THEN RAISE EXCEPTION 'Second approver must be a trustee'; END IF;
  SELECT * INTO e FROM ledger_entries WHERE id=p_ledger_entry_id AND status='Approved' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Approved ledger entry not found'; END IF;
  IF e.transaction_type='REVERSAL' THEN RAISE EXCEPTION 'A reversal cannot itself be reversed'; END IF;
  IF EXISTS(SELECT 1 FROM ledger_entries WHERE parent_ledger_entry_id=e.id AND transaction_type='REVERSAL' AND status='Approved') THEN
    RAISE EXCEPTION 'Ledger entry has already been reversed';
  END IF;

  INSERT INTO ledger_entries(member_id,loan_id,transaction_type,amount,source,status,approved_by,approved_at,parent_ledger_entry_id,reversal_reason,reversal_approved_by,allocation_notes)
  VALUES(e.member_id,e.loan_id,'REVERSAL',e.amount,'SYSTEM','Approved',v_actor,now(),e.id,p_reason,p_second_approver,'Approved reversal; original entry remains immutable')
  RETURNING id INTO v_id;

  IF e.transaction_type='LOAN_DISBURSEMENT' THEN
    RAISE EXCEPTION 'Loan disbursement reversal is not supported; use a controlled loan correction workflow';
  ELSIF e.transaction_type='LOAN_REPAYMENT' THEN
    UPDATE loans SET total_repaid=total_repaid-e.amount,
      status=CASE WHEN status='Closed' THEN 'Active' ELSE status END,
      closed_at=CASE WHEN status='Closed' THEN NULL ELSE closed_at END,
      closed_reason=CASE WHEN status='Closed' THEN NULL ELSE closed_reason END
    WHERE id=e.loan_id AND total_repaid>=e.amount;

    -- Reverse the repayment against the latest schedule rows first.
    DECLARE v_remaining numeric(12,2); v_sched record; v_reduce numeric(12,2);
    BEGIN
      v_remaining:=e.amount;
      FOR v_sched IN SELECT id,amount_paid FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND amount_paid>0 ORDER BY instalment_number DESC FOR UPDATE LOOP
        EXIT WHEN v_remaining<=0;
        v_reduce:=LEAST(v_remaining,v_sched.amount_paid);
        UPDATE loan_repayment_schedule SET amount_paid=amount_paid-v_reduce,
          status=CASE WHEN amount_paid-v_reduce<=0 THEN 'Pending' ELSE 'Partially Paid' END,
          paid_at=CASE WHEN amount_paid-v_reduce<=0 THEN NULL ELSE paid_at END
        WHERE id=v_sched.id;
        v_remaining:=v_remaining-v_reduce;
      END LOOP;
    END;
    UPDATE loans SET instalments_paid=(SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND status='Paid'),
      next_payment_due_date=(SELECT min(due_date) FROM loan_repayment_schedule WHERE loan_id=e.loan_id AND amount_paid<scheduled_amount)
    WHERE id=e.loan_id;
  END IF;

  PERFORM write_audit('REVERSE_TRANSACTION','ledger_entry',e.id,jsonb_build_object('reversal_id',v_id,'reason',p_reason,'second_approver',p_second_approver));
  RETURN v_id;
END;
$$;

-- ============================================================
-- 25. WITHDRAWAL APPROVAL / PROCESSING
-- ============================================================

CREATE OR REPLACE FUNCTION approve_withdrawal(
  p_request_id uuid,p_trustee_1 uuid,p_trustee_2 uuid,p_recorder_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE w withdrawal_requests%ROWTYPE; v_balance numeric(12,2); v_charge numeric(12,2); v_net numeric(12,2);
BEGIN
  IF app_role() NOT IN ('Treasurer','Chairman','Secretary','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  SELECT * INTO w FROM withdrawal_requests WHERE id=p_request_id FOR UPDATE;
  IF w.status<>'Pending' THEN RAISE EXCEPTION 'Withdrawal is not pending'; END IF;
  IF p_trustee_1 IS NULL OR p_trustee_2 IS NULL OR p_trustee_1=p_trustee_2 THEN RAISE EXCEPTION 'Two different trustees are required'; END IF;
  IF NOT is_trustee(p_trustee_1) OR NOT is_trustee(p_trustee_2) THEN RAISE EXCEPTION 'Signatories must be trustees'; END IF;
  IF p_recorder_id=p_trustee_1 OR p_recorder_id=p_trustee_2 THEN RAISE EXCEPTION 'Recorder cannot be a signatory'; END IF;
  v_balance:=get_member_savings_balance(w.member_id);
  IF w.requested_amount>v_balance THEN RAISE EXCEPTION 'Withdrawal exceeds available savings balance'; END IF;
  IF w.withdrawal_type='RETIREMENT' THEN
    IF (SELECT status FROM members WHERE id=w.member_id) NOT IN ('Terminated','Exited') THEN RAISE EXCEPTION 'Retirement withdrawal requires termination/exit status'; END IF;
    IF (SELECT termination_date FROM members WHERE id=w.member_id) IS NULL OR current_date > (SELECT termination_date FROM members WHERE id=w.member_id)+interval '3 months' THEN
      RAISE EXCEPTION 'Retirement partial withdrawal must be within 3 months of retirement';
    END IF;
    IF w.requested_amount>v_balance*0.50 THEN RAISE EXCEPTION 'Retirement withdrawal may not exceed 50%% of savings'; END IF;
    v_charge:=round(w.requested_amount*0.02,2);
  ELSE
    v_charge:=0;
  END IF;
  v_net:=w.requested_amount-v_charge;
  IF v_net<=0 THEN RAISE EXCEPTION 'Net withdrawal must be positive'; END IF;

  UPDATE withdrawal_requests SET trustee_1=p_trustee_1,trustee_2=p_trustee_2,recorder_id=p_recorder_id,
    charge_amount=v_charge,net_amount=v_net,status='Approved',approved_at=now() WHERE id=w.id;
  PERFORM write_audit('APPROVE_WITHDRAWAL','withdrawal_request',w.id,jsonb_build_object('amount',w.requested_amount,'charge',v_charge));
  RETURN jsonb_build_object('success',true,'gross_amount',w.requested_amount,'charge',v_charge,'net_amount',v_net);
END;
$$;

CREATE OR REPLACE FUNCTION process_withdrawal(p_request_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE w withdrawal_requests%ROWTYPE; v_ledger uuid;
BEGIN
  IF app_role()<>'Treasurer' THEN RAISE EXCEPTION 'Only Treasurer may process withdrawals'; END IF;
  SELECT * INTO w FROM withdrawal_requests WHERE id=p_request_id FOR UPDATE;
  IF w.status<>'Approved' THEN RAISE EXCEPTION 'Withdrawal must be approved first'; END IF;
  IF w.recorder_id=app_member_id() AND w.trustee_1=app_member_id() THEN RAISE EXCEPTION 'Recorder/signatory separation violated'; END IF;
  INSERT INTO ledger_entries(member_id,transaction_type,amount,source,status,approved_by,allocation_notes)
  VALUES(w.member_id,'WITHDRAWAL',w.requested_amount,'SYSTEM','Approved',app_member_id(),'Approved savings withdrawal; net amount after charge N'||w.net_amount)
  RETURNING id INTO v_ledger;
  IF w.charge_amount>0 THEN
    INSERT INTO ledger_entries(member_id,transaction_type,amount,source,status,approved_by,allocation_notes)
    VALUES(w.member_id,'FINE',w.charge_amount,'SYSTEM','Approved',app_member_id(),'Retirement withdrawal 2% charge');
  END IF;
  UPDATE withdrawal_requests SET status='Processed',processed_at=now(),ledger_entry_id=v_ledger WHERE id=w.id;
  PERFORM write_audit('PROCESS_WITHDRAWAL','withdrawal_request',w.id,jsonb_build_object('ledger_entry',v_ledger));
  RETURN v_ledger;
END;
$$;

-- ============================================================
-- 26. MISSED CONTRIBUTIONS / FINES / DEFAULT FLAGS
-- ============================================================

CREATE OR REPLACE FUNCTION assess_missed_contributions(p_as_of date DEFAULT current_date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE m record; month_start date; v_count integer:=0; v_ledger uuid; v_contributed boolean; v_missed_streak integer; i integer;
BEGIN
  IF app_role() NOT IN ('Treasurer','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  FOR m IN SELECT id,standing_contribution_amount FROM members WHERE status='Active' LOOP
    month_start:=date_trunc('month',p_as_of)::date;
    v_contributed:=EXISTS(SELECT 1 FROM ledger_entries WHERE member_id=m.id AND transaction_type='CONTRIBUTION' AND status='Approved' AND date_trunc('month',transaction_date)::date=month_start);
    IF NOT v_contributed THEN
      IF NOT EXISTS(SELECT 1 FROM contribution_fine_events WHERE member_id=m.id AND fine_type='MISSED_MONTH' AND contribution_month=month_start) THEN
        INSERT INTO ledger_entries(member_id,transaction_type,amount,source,status,approved_by,allocation_notes)
        VALUES(m.id,'FINE',1000,'SYSTEM','Approved',app_member_id(),'N1,000 fine for missed monthly contribution') RETURNING id INTO v_ledger;
        INSERT INTO contribution_fine_events(member_id,fine_type,contribution_month,amount,reason,ledger_entry_id)
        VALUES(m.id,'MISSED_MONTH',month_start,1000,'Missed monthly contribution',v_ledger);
        v_count:=v_count+1;
      END IF;
    END IF;

    -- Three consecutive missed months triggers withdrawal/management review flag.
    v_missed_streak:=0;
    FOR i IN 0..2 LOOP
      IF NOT EXISTS(SELECT 1 FROM ledger_entries WHERE member_id=m.id AND transaction_type='CONTRIBUTION' AND status='Approved'
        AND date_trunc('month',transaction_date)::date=(month_start-(i||' month')::interval)::date) THEN
        v_missed_streak:=v_missed_streak+1;
      ELSE EXIT; END IF;
    END LOOP;
    IF v_missed_streak>=2 THEN
      PERFORM write_audit('WITHDRAWAL_REVIEW_FLAG','member',m.id,jsonb_build_object('consecutive_missed_months',v_missed_streak));
    END IF;
  END LOOP;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION assess_loan_defaults(p_as_of date DEFAULT current_date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE l record; v_streak integer; v_count integer:=0; d record;
BEGIN
  IF app_role() NOT IN ('Treasurer','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  FOR l IN SELECT id,member_id FROM loans WHERE status='Active' LOOP
    SELECT count(*) INTO v_streak
    FROM (
      SELECT s.status FROM loan_repayment_schedule s WHERE s.loan_id=l.id AND s.due_date<=p_as_of ORDER BY s.instalment_number DESC LIMIT 3
    ) x WHERE x.status IN ('Overdue','Pending');
    IF v_streak>=3 THEN
      UPDATE loans SET status='Defaulted' WHERE id=l.id;
      PERFORM write_audit('LOAN_RECALL_FLAG','loan',l.id,jsonb_build_object('consecutive_default_months',v_streak));
      PERFORM queue_notification(l.member_id,'MISSED_PAYMENT','Loan default/recall flag','Loan '||l.id||' has reached three consecutive missed instalments and has been flagged for recall.');
      v_count:=v_count+1;
    END IF;
  END LOOP;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION refresh_schedule_statuses(p_as_of date DEFAULT current_date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count integer;
BEGIN
  UPDATE loan_repayment_schedule SET status='Overdue'
  WHERE due_date<p_as_of AND amount_paid<scheduled_amount AND status IN ('Pending','Partially Paid');
  GET DIAGNOSTICS v_count=ROW_COUNT;
  UPDATE loans l SET next_payment_due_date=(SELECT min(s.due_date) FROM loan_repayment_schedule s WHERE s.loan_id=l.id AND s.amount_paid<s.scheduled_amount)
  WHERE l.status IN ('Active','Defaulted');
  RETURN v_count;
END;
$$;

-- ============================================================
-- 27. UNIDENTIFIED DEPOSIT ESCALATION
-- ============================================================

CREATE OR REPLACE FUNCTION escalate_unidentified_deposits()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count integer;
BEGIN
  UPDATE unidentified_deposits SET status='Escalated',escalated_at=now(),escalation_reason='Auto-escalated after 30 days'
  WHERE status='Unclaimed' AND created_at < now()-interval '30 days';
  GET DIAGNOSTICS v_count=ROW_COUNT;
  IF v_count>0 THEN PERFORM write_audit('ESCALATE_UNIDENTIFIED_DEPOSIT',NULL,NULL,jsonb_build_object('count',v_count)); END IF;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION resolve_unidentified_deposit(p_id uuid,p_member_id uuid,p_savings numeric(12,2),p_loans jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE d unidentified_deposits%ROWTYPE; n payment_notifications%ROWTYPE;
BEGIN
  IF app_role()<>'Treasurer' THEN RAISE EXCEPTION 'Only Treasurer may resolve unidentified deposits'; END IF;
  SELECT * INTO d FROM unidentified_deposits WHERE id=p_id FOR UPDATE;
  IF d.status NOT IN ('Unclaimed','Escalated') THEN RAISE EXCEPTION 'Deposit already resolved'; END IF;
  SELECT * INTO n FROM payment_notifications WHERE id=d.payment_notification_id FOR UPDATE;
  UPDATE payment_notifications SET member_id=p_member_id,status='Pending' WHERE id=n.id;
  PERFORM approve_payment_with_split(n.id,p_savings,p_loans,p_member_id);
  UPDATE unidentified_deposits SET status='Resolved',resolved_at=now(),resolved_by=app_member_id(),resolution_notes='Resolved to member '||p_member_id WHERE id=d.id;
  PERFORM write_audit('RESOLVE_UNIDENTIFIED_DEPOSIT','unidentified_deposit',d.id,jsonb_build_object('member_id',p_member_id));
  RETURN jsonb_build_object('success',true,'deposit_id',d.id);
END;
$$;

-- ============================================================
-- 28. SURETY / REPAYMENT PERIOD RULES
-- ============================================================

CREATE OR REPLACE FUNCTION accept_surety(p_surety_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE s sureties%ROWTYPE; v_count integer; v_loan_member uuid;
BEGIN
  SELECT * INTO s FROM sureties WHERE id=p_surety_id FOR UPDATE;
  IF s.surety_member_id<>app_member_id() THEN RAISE EXCEPTION 'Only the named surety may accept'; END IF;
  IF (SELECT status FROM members WHERE id=s.surety_member_id)<>'Active' THEN RAISE EXCEPTION 'Surety must be Active'; END IF;
  SELECT member_id INTO v_loan_member FROM loans WHERE id=s.loan_id;
  IF v_loan_member=s.surety_member_id THEN RAISE EXCEPTION 'A member cannot be surety for own loan'; END IF;
  SELECT count(*) INTO v_count FROM sureties ss JOIN loans l ON l.id=ss.loan_id
  WHERE ss.surety_member_id=s.surety_member_id AND ss.status='Accepted' AND l.status IN ('Active','Disbursed');
  IF v_count>=2 THEN RAISE EXCEPTION 'Maximum two concurrent active guarantees reached'; END IF;
  UPDATE sureties SET status='Accepted',consent_given_at=now(),consent_ip=NULL,consent_user_agent=NULL WHERE id=s.id;
  PERFORM write_audit('ACCEPT_SURETY','surety',s.id,jsonb_build_object('loan_id',s.loan_id));
END;
$$;

CREATE OR REPLACE FUNCTION request_loan_term_change(p_loan_id uuid,p_new_term integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count integer;
BEGIN
  IF app_role() NOT IN ('Treasurer','LoanCommittee','SystemAdmin') THEN RAISE EXCEPTION 'Not authorised'; END IF;
  SELECT count(*) INTO v_count FROM sureties WHERE loan_id=p_loan_id AND status='Accepted';
  IF v_count<>2 THEN RAISE EXCEPTION 'All two sureties must have consented before repayment period may be changed'; END IF;
  RAISE EXCEPTION 'Repayment period changes are not permitted after disbursement in Phase 1; obtain explicit SRS/bye-law amendment before implementing';
END;
$$;

-- ============================================================
-- 29. REPORTING VIEWS
-- ============================================================

CREATE OR REPLACE VIEW member_dashboard AS
SELECT m.id member_id,m.first_name,m.last_name,m.email,m.status,
  get_member_savings_balance(m.id) savings_balance,
  get_member_total_outstanding_loans(m.id) total_outstanding_loans,
  COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'loan_id',l.id,'loan_reference',l.loan_reference,'product_type',lp.name,
    'principal',l.principal_amount,'monthly_instalment',l.monthly_instalment,
    'outstanding_balance',get_loan_outstanding_balance(l.id),
    'instalments_paid',l.instalments_paid,
    'instalments_remaining',GREATEST(0,l.term_months-l.instalments_paid),
    'status',l.status,'next_payment_due',l.next_payment_due_date,
    'repayment_progress',CASE WHEN l.total_repayable=0 THEN 0 ELSE round(l.total_repaid/l.total_repayable*100,2) END
  ) ORDER BY l.next_payment_due_date)
  FROM loans l JOIN loan_products lp ON lp.id=l.loan_product_id
  WHERE l.member_id=m.id AND l.status IN ('Active','Disbursed','Defaulted')), '[]'::jsonb) active_loans
FROM members m;

CREATE OR REPLACE VIEW pending_transactions AS
SELECT p.id transaction_id,p.member_id,m.first_name,m.last_name,p.amount,p.transaction_date,
  p.payment_reference,p.bank_reference,p.payment_narration,p.evidence_url,p.source,p.match_confidence,
  p.proposed_savings_amount,p.proposed_loan_allocations,p.created_at,
  CASE WHEN p.source='API' AND p.match_confidence='EXACT' THEN 'High'
       WHEN p.source='API' AND p.match_confidence='PARTIAL' THEN 'Medium'
       WHEN p.source='API' AND p.match_confidence='NONE' THEN 'Low' ELSE 'Manual' END priority
FROM payment_notifications p LEFT JOIN members m ON m.id=p.member_id
WHERE p.status='Pending'
ORDER BY CASE WHEN p.source='API' AND p.match_confidence='EXACT' THEN 1
              WHEN p.source='API' AND p.match_confidence='PARTIAL' THEN 2 ELSE 3 END,p.created_at;

CREATE OR REPLACE VIEW loan_portfolio AS
SELECT l.id loan_id,l.loan_reference,l.member_id,m.first_name,m.last_name,lp.name loan_type,
 l.principal_amount,l.member_savings_at_disbursement,l.covered_principal,l.surplus_principal,
 l.normal_interest_applied,l.surplus_interest_applied,l.total_interest,l.application_fee_charged,
 l.total_repayable,l.total_repaid,get_loan_outstanding_balance(l.id) outstanding_balance,
 l.monthly_instalment,l.instalments_paid,
 GREATEST(0,l.term_months-l.instalments_paid) instalments_remaining,l.term_months,l.status,l.next_payment_due_date,
 CASE WHEN l.next_payment_due_date<CURRENT_DATE AND l.status IN ('Active','Disbursed') THEN 'Overdue'
      WHEN l.next_payment_due_date<=CURRENT_DATE+7 AND l.status IN ('Active','Disbursed') THEN 'Due Soon' ELSE 'Current' END payment_status
FROM loans l JOIN members m ON m.id=l.member_id JOIN loan_products lp ON lp.id=l.loan_product_id
WHERE l.status IN ('Active','Disbursed','Defaulted');

CREATE OR REPLACE VIEW monthly_reconciliation AS
SELECT date_trunc('month',COALESCE(le.created_at,bt.created_at))::date month,
  COALESCE(sum(bt.amount) FILTER(WHERE bt.status IN ('Matched','Manual')),0) bank_matched,
  COALESCE(sum(le.amount) FILTER(WHERE le.status='Approved'),0) approved_ledger,
  COALESCE(sum(bt.amount) FILTER(WHERE bt.status='Unmatched'),0) unreconciled_bank_amount
FROM bank_transactions bt
FULL OUTER JOIN ledger_entries le ON le.id=bt.matched_to_ledger_entry_id
GROUP BY 1;

CREATE OR REPLACE VIEW member_statement_lines AS
SELECT le.member_id,le.transaction_date,le.transaction_type,le.amount,
       le.loan_id,l.loan_reference,le.payment_reference,le.allocation_notes
FROM ledger_entries le LEFT JOIN loans l ON l.id=le.loan_id
WHERE le.status='Approved';

CREATE OR REPLACE VIEW loan_repayment_history AS
SELECT le.loan_id,l.loan_reference,l.member_id,le.transaction_date repayment_date,
       le.amount,le.payment_reference,le.payment_notification_id,le.allocation_notes
FROM ledger_entries le JOIN loans l ON l.id=le.loan_id
WHERE le.transaction_type='LOAN_REPAYMENT' AND le.status='Approved';

CREATE OR REPLACE VIEW loan_schedule_report AS
SELECT s.loan_id,l.loan_reference,l.member_id,s.instalment_number,s.due_date,s.scheduled_amount,
 s.amount_paid,s.scheduled_amount-s.amount_paid balance_on_instalment,s.status
FROM loan_repayment_schedule s JOIN loans l ON l.id=s.loan_id;

-- ============================================================
-- 30. GRANTS FOR SUPABASE AUTHENTICATED CLIENTS
-- ============================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON member_dashboard,pending_transactions,loan_portfolio,member_statement_lines,loan_repayment_history,loan_schedule_report TO authenticated;
GRANT SELECT ON members,loans,sureties,loan_repayment_schedule,payment_notifications,payment_allocations,ledger_entries,withdrawal_requests,contribution_fine_events,notification_queue TO authenticated;
GRANT INSERT ON members,loans,payment_notifications,withdrawal_requests TO authenticated;
GRANT UPDATE ON members,loans,sureties,payment_notifications,withdrawal_requests TO authenticated;

-- Controlled RPCs. Direct ledger writes remain unavailable to authenticated users.
GRANT EXECUTE ON FUNCTION app_role() TO authenticated;
GRANT EXECUTE ON FUNCTION app_member_id() TO authenticated;
GRANT EXECUTE ON FUNCTION get_member_savings_balance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_member_total_outstanding_loans(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_loan_outstanding_balance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION calculate_loan_terms(uuid,uuid,numeric,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION request_contribution_revision(uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION member_has_six_consecutive_months(uuid,date) TO authenticated;
GRANT EXECUTE ON FUNCTION submit_payment_notification(uuid,numeric,text,text,numeric,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_payment_with_split(uuid,numeric,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION decline_payment(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION accept_surety(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION record_loan_trustee_signoff(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION disburse_loan(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_loan(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION decide_member_application(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION reverse_ledger_entry(uuid,text,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION approve_withdrawal(uuid,uuid,uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION process_withdrawal(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION resolve_unidentified_deposit(uuid,uuid,numeric,jsonb) TO authenticated;

-- API ingestion, scheduled assessment and reconciliation routines should be
-- called only by trusted Edge Functions/service_role, not browser clients.

-- ============================================================
-- 31. COMMENTS / IMPLEMENTATION NOTES
-- ============================================================

COMMENT ON TABLE payment_notifications IS 'Single Unified Pending Queue for both manual and API incoming payment notices; no auto-posting.';
COMMENT ON TABLE payment_allocations IS 'Immutable record of how one approved payment was split across savings and specific loans.';
COMMENT ON TABLE ledger_entries IS 'Append-only financial record. No authenticated INSERT/UPDATE/DELETE policy; controlled RPCs post entries.';
COMMENT ON TABLE loan_repayment_schedule IS 'Fixed schedule generated at disbursement. Payment allocation is applied to earliest unpaid instalments.';
COMMENT ON TABLE notification_queue IS 'Email notification outbox required by SRS FR-7. Email delivery itself is performed by an external email worker/Edge Function.';
COMMENT ON FUNCTION assess_missed_contributions(date) IS 'Run monthly after the contribution deadline. Applies N1,000 missed-month fines and audit flags consecutive misses.';
COMMENT ON FUNCTION assess_loan_defaults(date) IS 'Run after schedule status refresh. Three consecutive due schedule rows with status Overdue or Pending are treated as consecutive defaults; treatment of partially paid instalments is a UAT/business-rule decision.';
COMMENT ON FUNCTION escalate_unidentified_deposits() IS 'Run daily by a trusted scheduler; escalates deposits unclaimed for more than 30 days.';

-- ============================================================
-- 32. MIGRATION SELF-CHECKS
-- ============================================================

DO $$
DECLARE v integer;
BEGIN
  SELECT count(*) INTO v FROM loan_products WHERE is_active=true;
  IF v<>4 THEN RAISE EXCEPTION 'Migration self-check failed: four active loan products expected'; END IF;
  IF (SELECT normal_interest_rate FROM loan_products WHERE name='Long-Term')<>5 THEN RAISE EXCEPTION 'Long-Term rate self-check failed'; END IF;
  IF (SELECT normal_interest_rate FROM loan_products WHERE name='Short-Term')<>10 THEN RAISE EXCEPTION 'Short-Term rate self-check failed'; END IF;
  IF (SELECT application_fee FROM loan_products WHERE name='Essential Commodity')<>2000 THEN RAISE EXCEPTION 'Application fee self-check failed'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='ledger_entries'
      AND column_name='transaction_date'
  ) THEN
    RAISE EXCEPTION 'Migration self-check failed: ledger_entries.transaction_date column is missing';
  END IF;
END $$;

COMMIT;

-- ============================================================
-- END SSCMPS SUPABASE MIGRATION v3.0
-- ============================================================
