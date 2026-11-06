-- 20261105000001_annual_10_percent_withdrawal.sql
--
-- Adds ANNUAL_10_PERCENT withdrawal type per Treasurer's confirmed rules
-- (2026-11-05):
--   * Exactly 10% of current savings, no more no less
--   * Once per financial year (Dec 1 - Nov 30, bye-law Section 1a)
--   * Request window: January 1 - July 31 of that financial year
--   * Cash in full (no loan offset)
--   * Same two-signature workflow as termination (Trustee + Treasurer)
--   * No 2% admin charge (bye-laws apply 2% only to retirement/termination)
--
-- Also fixes two pre-existing bugs found while preparing this migration:
--   (a) submit_withdrawal_request required status IN ('Terminated','Exited')
--       for all withdrawal types, so no Active member could ever request
--       a RETIREMENT withdrawal. Bye-law 15(a)(ii) says retirees retain
--       membership, so Active is the correct status for RETIREMENT.
--       ANNUAL_10_PERCENT also requires Active.
--   (b) assert_withdrawal_type_allowed was IMMUTABLE despite being the
--       gate for time-sensitive rules. Changed to STABLE.
--
-- Layer 2 status-gate hardening (RETIREMENT and ANNUAL_10_PERCENT = Active
-- only) is included. The loan-lifecycle gap (Active member applies, becomes
-- Terminated, committee approves, treasurer disburses) is NOT addressed
-- here — that requires gates in record_committee_decision and disburse_loan
-- and is a separate follow-up migration.
--
-- Application:
--   psql $env:SUPABASE_DB_URL --single-transaction -f db/migrations/20261105000001_annual_10_percent_withdrawal.sql

BEGIN;

-- =============================================================
-- 1. Expand withdrawal_type CHECK constraint
-- =============================================================
ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_withdrawal_type_check;

ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_withdrawal_type_check
  CHECK (withdrawal_type = ANY (ARRAY[
    'RETIREMENT', 'TERMINATION', 'FINAL_EXIT', 'ANNUAL_10_PERCENT'
  ]));

-- =============================================================
-- 2. assert_withdrawal_type_allowed — STABLE + annual window check
-- =============================================================
CREATE OR REPLACE FUNCTION public.assert_withdrawal_type_allowed(
  p_withdrawal_type text,
  p_caller_role text
) RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if p_withdrawal_type = 'TERMINATION'
     and p_caller_role not in ('Treasurer','Chairman','Secretary','SystemAdmin') then
    raise exception 'Termination is initiated by the management, not by the member';
  end if;

  if p_withdrawal_type = 'ANNUAL_10_PERCENT' then
    if extract(month from now()) not between 1 and 7 then
      raise exception 'Annual 10%% withdrawal requests are only accepted January through July';
    end if;
  end if;
end;
$function$;

-- =============================================================
-- 3. submit_withdrawal_request — annual 10% + retirement status fix
-- =============================================================
CREATE OR REPLACE FUNCTION public.submit_withdrawal_request(
  p_withdrawal_type text,
  p_requested_amount numeric,
  p_reason text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_member    uuid := app_member_id();
  v_status    text;
  v_id        uuid;
  v_balance   numeric(12,2);
  v_ten_pct   numeric(12,2);
  v_fy_start  timestamptz;
  v_fy_end    timestamptz;
BEGIN
  SELECT status INTO v_status FROM members WHERE id = v_member;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Member account not found'; END IF;
  IF p_requested_amount <= 0 THEN RAISE EXCEPTION 'Withdrawal amount must be greater than zero'; END IF;
  IF p_withdrawal_type NOT IN ('RETIREMENT','TERMINATION','FINAL_EXIT','ANNUAL_10_PERCENT') THEN
    RAISE EXCEPTION 'Invalid withdrawal type';
  END IF;

  -- Caller-role + window gate
  PERFORM assert_withdrawal_type_allowed(p_withdrawal_type, app_role());

  -- Status gate per withdrawal type
  IF p_withdrawal_type = 'ANNUAL_10_PERCENT' THEN
    IF v_status <> 'Active' THEN
      RAISE EXCEPTION 'Annual withdrawal requires Active membership status';
    END IF;
  ELSIF p_withdrawal_type = 'RETIREMENT' THEN
    -- Bye-law 15(a)(ii): retiree retains membership. Only Active members
    -- may claim the 50%% retirement withdrawal. Terminated/Exited must
    -- use TERMINATION or FINAL_EXIT (100%% payout) instead.
    IF v_status <> 'Active' THEN
      RAISE EXCEPTION 'Retirement withdrawal requires Active membership status';
    END IF;
  ELSE
    -- TERMINATION or FINAL_EXIT
    IF v_status NOT IN ('Terminated','Exited') THEN
      RAISE EXCEPTION 'Termination withdrawal requires Terminated or Exited status';
    END IF;
  END IF;

  v_balance := get_member_savings_balance(v_member);

  IF p_withdrawal_type = 'ANNUAL_10_PERCENT' THEN
    -- Exactly 10%, no more no less
    v_ten_pct := round(v_balance * 0.10, 2);
    IF v_ten_pct <= 0 THEN
      RAISE EXCEPTION 'Savings balance is too low for an annual withdrawal (balance %, 10%% = %)',
        v_balance, v_ten_pct;
    END IF;
    IF p_requested_amount <> v_ten_pct THEN
      RAISE EXCEPTION 'Annual withdrawal must be exactly 10%% of savings (% expected, % submitted)',
        v_ten_pct, p_requested_amount;
    END IF;

    -- Once per financial year (Dec 1 - Nov 30)
    IF extract(month from now()) >= 12 THEN
      v_fy_start := date_trunc('year', now()) + interval '11 months';
    ELSE
      v_fy_start := date_trunc('year', now()) - interval '1 month';
    END IF;
    v_fy_end := v_fy_start + interval '1 year';

    IF EXISTS (
      SELECT 1 FROM withdrawal_requests
      WHERE member_id = v_member
        AND withdrawal_type = 'ANNUAL_10_PERCENT'
        AND status NOT IN ('Declined')
        AND created_at >= v_fy_start
        AND created_at < v_fy_end
    ) THEN
      RAISE EXCEPTION 'Member has already requested an annual withdrawal this financial year';
    END IF;
  ELSE
    IF p_requested_amount > v_balance THEN
      RAISE EXCEPTION 'Withdrawal exceeds available savings';
    END IF;
  END IF;

  INSERT INTO withdrawal_requests(
    member_id, withdrawal_type, requested_amount,
    charge_amount, net_amount, reason, created_by
  ) VALUES (
    v_member, p_withdrawal_type, p_requested_amount,
    0, p_requested_amount, p_reason, v_member
  ) RETURNING id INTO v_id;

  PERFORM write_audit(
    'SUBMIT_WITHDRAWAL_REQUEST',
    'withdrawal_request',
    v_id,
    jsonb_build_object(
      'amount', p_requested_amount,
      'type', p_withdrawal_type,
      'savings_balance_at_request', v_balance
    )
  );

  RETURN v_id;
END;
$function$;

-- =============================================================
-- 4. process_withdrawal_with_liquidation
--    Signature unchanged so CREATE OR REPLACE preserves grants.
--    Skips liquidation for ANNUAL_10_PERCENT (cash in full),
--    applies 0 charge for ANNUAL_10_PERCENT (bye-laws only charge 2%
--    on retirement/termination).
-- =============================================================
CREATE OR REPLACE FUNCTION public.process_withdrawal_with_liquidation(
  p_request_id uuid,
  p_processed_by uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_request withdrawal_requests%rowtype;
  v_savings_before numeric(12,2);
  v_loans_outstanding numeric(12,2);
  v_savings_after numeric(12,2);
  v_loan record;
  v_remaining numeric(12,2);
  v_loan_repaid_total numeric(12,2) := 0;
  v_loans_closed integer := 0;
  v_cap numeric(12,2);
  v_gross numeric(12,2);
  v_charge numeric(12,2);
  v_net numeric(12,2);
  v_ledger uuid;
  v_approved_loan record;
  v_skip_liquidation boolean;
begin
  select * into v_request from withdrawal_requests
  where id = p_request_id for update;
  if not found then
    return jsonb_build_object('success', false, 'error', 'Request not found');
  end if;
  if v_request.status <> 'Approved' then
    return jsonb_build_object('success', false,
      'error', format('Request is %s; only Approved requests can be processed', v_request.status));
  end if;

  select l.loan_reference into v_approved_loan
  from loans l
  where l.member_id = v_request.member_id and l.status = 'Approved'
  limit 1;
  if found then
    return jsonb_build_object('success', false,
      'error', format(
        'Member has an approved loan (%s) awaiting disbursement. Disburse or cancel it first.',
        v_approved_loan.loan_reference));
  end if;

  -- ANNUAL_10_PERCENT: cash in full, no loan offset
  v_skip_liquidation := (v_request.withdrawal_type = 'ANNUAL_10_PERCENT');

  v_savings_before := get_member_savings_balance(v_request.member_id);
  v_loans_outstanding := get_member_total_outstanding_loans(v_request.member_id);

  if not v_skip_liquidation and v_loans_outstanding > 0 then
    for v_loan in
      select id, loan_reference, total_repayable, application_fee_charged, total_repaid
      from loans
      where member_id = v_request.member_id
        and status in ('Active','Disbursed','Defaulted')
      order by disbursed_at asc nulls last, created_at asc
      for update
    loop
      v_remaining := (v_loan.total_repayable + v_loan.application_fee_charged) - v_loan.total_repaid;
      exit when v_remaining <= 0;
      exit when v_loan_repaid_total >= v_savings_before;

      declare
        v_available numeric(12,2);
        v_this numeric(12,2);
      begin
        v_available := v_savings_before - v_loan_repaid_total;
        v_this := least(v_remaining, v_available);

        insert into ledger_entries (
          member_id, loan_id, transaction_type, amount, source, status,
          approved_by, allocation_notes
        ) values (
          v_request.member_id, v_loan.id, 'LOAN_LIQUIDATION',
          v_this, 'SYSTEM', 'Approved', p_processed_by,
          format('Savings applied to clear loan %s during withdrawal processing (request %s)',
                 v_loan.loan_reference, p_request_id));

        update loans set
          total_repaid = total_repaid + v_this,
          instalments_paid = (
            select count(*) from loan_repayment_schedule
            where loan_id = v_loan.id and amount_paid >= scheduled_amount),
          status = case when total_repaid + v_this >= total_repayable + application_fee_charged
                        then 'Closed' else status end,
          closed_at = case when total_repaid + v_this >= total_repayable + application_fee_charged
                           then now() else closed_at end,
          closed_reason = case when total_repaid + v_this >= total_repayable + application_fee_charged
                               then 'Liquidated from savings during withdrawal' else closed_reason end,
          next_payment_due_date = case when total_repaid + v_this >= total_repayable + application_fee_charged
                                       then null else next_payment_due_date end,
          updated_at = now()
        where id = v_loan.id;

        if v_this >= v_remaining then
          update loan_repayment_schedule
          set amount_paid = scheduled_amount, status = 'Paid', paid_at = now()
          where loan_id = v_loan.id and amount_paid < scheduled_amount;
          v_loans_closed := v_loans_closed + 1;
        end if;

        v_loan_repaid_total := v_loan_repaid_total + v_this;
      end;
    end loop;
  end if;

  v_savings_after := get_member_savings_balance(v_request.member_id);

  v_cap := case when v_request.withdrawal_type = 'RETIREMENT'
                then round(v_savings_after * 0.5, 2)
                else v_savings_after end;

  v_gross := least(v_request.requested_amount, v_cap);

  -- Charge policy:
  --   RETIREMENT / TERMINATION / FINAL_EXIT: 2% per bye-laws 15(a-ii),(a-iii)
  --   ANNUAL_10_PERCENT: 0% (new convention, no bye-law charge)
  v_charge := case when v_request.withdrawal_type = 'ANNUAL_10_PERCENT'
                   then 0::numeric
                   else round(v_gross * 0.02, 2) end;
  v_net := v_gross - v_charge;

  if v_gross > 0 then
    insert into ledger_entries (
      member_id, transaction_type, amount, source, status,
      approved_by, allocation_notes
    ) values (
      v_request.member_id, 'WITHDRAWAL', v_gross, 'SYSTEM', 'Approved',
      p_processed_by,
      format('Withdrawal %s processed. Gross N%s, charge N%s, net N%s.',
             v_request.withdrawal_type, v_gross, v_charge, v_net))
    returning id into v_ledger;
  end if;

  update withdrawal_requests set
    status = 'Processed', processed_at = now(),
    liquidation_amount = v_loan_repaid_total,
    actual_payout = v_gross, charge_amount = v_charge, net_amount = v_net,
    ledger_entry_id = v_ledger
  where id = p_request_id;

  -- Status transitions:
  --   TERMINATION -> Terminated
  --   FINAL_EXIT  -> Exited
  --   RETIREMENT and ANNUAL_10_PERCENT leave member status untouched
  if v_request.withdrawal_type = 'TERMINATION' then
    update members set
      status = 'Terminated',
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_request.member_id
      and status not in ('Terminated','Exited');
  elsif v_request.withdrawal_type = 'FINAL_EXIT' then
    update members set
      status = 'Exited',
      termination_date = coalesce(termination_date, current_date),
      termination_reason = coalesce(termination_reason, 'Final exit (withdrawal processed)'),
      session_invalidated_at = now(),
      updated_at = now()
    where id = v_request.member_id;
  end if;

  perform write_audit('PROCESS_WITHDRAWAL','withdrawal_request',p_request_id,
    jsonb_build_object(
      'withdrawal_type', v_request.withdrawal_type,
      'savings_before', v_savings_before,
      'loans_outstanding', v_loans_outstanding,
      'loans_closed', v_loans_closed,
      'loan_repaid_total', v_loan_repaid_total,
      'savings_after_liquidation', v_savings_after,
      'cap_applied', v_cap,
      'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net));

  return jsonb_build_object(
    'success', true, 'savings_before', v_savings_before,
    'loans_outstanding', v_loans_outstanding, 'loans_closed', v_loans_closed,
    'loan_repaid_total', v_loan_repaid_total,
    'savings_after_liquidation', v_savings_after, 'cap_applied', v_cap,
    'gross_payout', v_gross, 'charge', v_charge, 'net_to_member', v_net,
    'ledger_entry_id', v_ledger);
end;
$function$;

-- =============================================================
-- 5. Annual withdrawal eligibility view (RLS-scoped to caller/management)
-- =============================================================
CREATE OR REPLACE VIEW public.v_annual_withdrawal_eligibility AS
SELECT
  m.id AS member_id,
  get_member_savings_balance(m.id) AS current_savings,
  round(get_member_savings_balance(m.id) * 0.10, 2) AS annual_amount,
  (extract(month from now()) between 1 and 7) AS in_window,
  EXISTS (
    SELECT 1 FROM withdrawal_requests wr
    WHERE wr.member_id = m.id
      AND wr.withdrawal_type = 'ANNUAL_10_PERCENT'
      AND wr.status NOT IN ('Declined')
      AND wr.created_at >= (
        CASE WHEN extract(month from now()) >= 12
             THEN date_trunc('year', now()) + interval '11 months'
             ELSE date_trunc('year', now()) - interval '1 month' END)
      AND wr.created_at < (
        CASE WHEN extract(month from now()) >= 12
             THEN date_trunc('year', now()) + interval '23 months'
             ELSE date_trunc('year', now()) + interval '11 months' END)
  ) AS already_withdrawn_this_fy
FROM members m
WHERE m.status = 'Active'
  AND (
    m.id = app_member_id()
    OR app_role() IN ('Treasurer','Chairman','Secretary','ManagementCommittee','SystemAdmin')
  );

GRANT SELECT ON public.v_annual_withdrawal_eligibility TO authenticated;

COMMIT;