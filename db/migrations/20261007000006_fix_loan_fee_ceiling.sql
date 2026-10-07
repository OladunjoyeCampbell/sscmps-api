-- ============================================================
-- Fix loan repayment ceiling to include the application fee
-- ============================================================
-- The schedule includes the ₦2,000 fee in the first instalment,
-- but the payment ceiling excluded it. Loans therefore closed
-- with the fee uncollected. This migration raises the ceiling
-- to include the fee, so future loans collect it in full.
-- ============================================================

-- ---------- 1. Drop the old constraint and add a corrected one ----------
DO $$
DECLARE
  v_constraint text;
BEGIN
  FOR v_constraint IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.loans'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%total_repaid <= total_repayable%'
  LOOP
    EXECUTE format('ALTER TABLE public.loans DROP CONSTRAINT %I', v_constraint);
    RAISE NOTICE 'Dropped constraint %', v_constraint;
  END LOOP;
END $$;

ALTER TABLE public.loans
  ADD CONSTRAINT loans_check_total_repaid
  CHECK (total_repaid <= total_repayable + application_fee_charged);

-- ---------- 2. Fix get_loan_outstanding_balance ----------
create or replace function public.get_loan_outstanding_balance(p_loan_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select greatest(
    0,
    (total_repayable + application_fee_charged) - total_repaid
  )::numeric(12,2)
  from loans where id = p_loan_id;
$$;

-- ---------- 3. Fix approve_payment_with_split ----------
create or replace function public.approve_payment_with_split(
  p_payment_notification_id uuid,
  p_savings_allocation numeric(12,2),
  p_loan_allocations jsonb default '[]'::jsonb,
  p_match_override_member_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
DECLARE
  n payment_notifications%ROWTYPE; r record; v_sum numeric(12,2):=COALESCE(p_savings_allocation,0);
  v_out numeric(12,2); v_member uuid; v_ledger uuid; v_repaid numeric(12,2);
  v_remaining numeric(12,2); v_paid numeric(12,2); v_inst integer; v_early boolean;
  v_loan loans%ROWTYPE; v_true_owed numeric(12,2);
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
    -- Ceiling now includes the fee
    v_true_owed := v_loan.total_repayable + v_loan.application_fee_charged;
    v_out := v_true_owed - v_loan.total_repaid;
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
    v_true_owed := v_loan.total_repayable + v_loan.application_fee_charged;
    v_out := v_true_owed - v_loan.total_repaid;
    IF r.amount > v_out THEN RAISE EXCEPTION 'Concurrent allocation would overpay loan %',v_loan.loan_reference; END IF;

    INSERT INTO ledger_entries(member_id,loan_id,payment_notification_id,transaction_type,amount,payment_reference,evidence_url,source,match_confidence,status,approved_by,allocation_notes)
    VALUES(v_member,r.loan_id,n.id,'LOAN_REPAYMENT',r.amount,n.payment_reference,n.evidence_url,n.source,n.match_confidence,'Approved',app_member_id(),'Treasurer-approved loan repayment allocation')
    RETURNING id INTO v_ledger;

    INSERT INTO payment_allocations(payment_notification_id,member_id,destination_type,loan_id,amount,ledger_entry_id)
    VALUES(n.id,v_member,'LOAN',r.loan_id,r.amount,v_ledger);

    v_repaid:=v_loan.total_repaid+r.amount;
    UPDATE loans SET total_repaid=v_repaid WHERE id=r.loan_id;

    -- Apply payment to earliest unpaid schedule rows
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

    -- Close if fully repaid (fee included)
    SELECT * INTO v_loan FROM loans WHERE id=r.loan_id;
    v_early := v_repaid >= (v_loan.total_repayable + v_loan.application_fee_charged);
    IF v_early THEN
      UPDATE loans SET status='Closed',closed_at=now(),
        closed_reason=CASE WHEN (SELECT count(*) FROM loan_repayment_schedule WHERE loan_id=r.loan_id AND status='Paid') < term_months THEN 'Closed (Early Repayment)' ELSE 'Fully repaid' END,
        next_payment_due_date=NULL WHERE id=r.loan_id;
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

-- ---------- 4. Fix loan_portfolio view ----------
create or replace view public.loan_portfolio as
select
  l.id as loan_id,
  l.loan_reference,
  l.member_id,
  m.first_name,
  m.last_name,
  lp.name as loan_type,
  l.principal_amount,
  l.member_savings_at_disbursement,
  l.covered_principal,
  l.surplus_principal,
  l.normal_interest_applied,
  l.surplus_interest_applied,
  l.total_interest,
  l.application_fee_charged,
  l.total_repayable,
  l.total_repaid,
  greatest(0, (l.total_repayable + l.application_fee_charged) - l.total_repaid) as outstanding_balance,
  l.monthly_instalment,
  l.instalments_paid,
  greatest(0, l.term_months - l.instalments_paid) as instalments_remaining,
  l.term_months,
  l.status,
  l.next_payment_due_date,
  case
    when l.next_payment_due_date < current_date and l.status in ('Active','Disbursed') then 'Overdue'
    when l.next_payment_due_date <= current_date + 7 and l.status in ('Active','Disbursed') then 'Due Soon'
    else 'Current'
  end as payment_status
from loans l
join members m on m.id = l.member_id
join loan_products lp on lp.id = l.loan_product_id
where l.status in ('Active','Disbursed','Defaulted');

-- ---------- 5. Fix member_dashboard view ----------
create or replace view public.member_dashboard as
select m.id as member_id, m.first_name, m.last_name, m.email, m.status,
  get_member_savings_balance(m.id) as savings_balance,
  get_member_total_outstanding_loans(m.id) as total_outstanding_loans,
  coalesce(
    (select jsonb_agg(jsonb_build_object(
      'loan_id', l.id,
      'loan_reference', l.loan_reference,
      'product_type', lp.name,
      'principal', l.principal_amount,
      'monthly_instalment', l.monthly_instalment,
      'outstanding_balance', get_loan_outstanding_balance(l.id),
      'instalments_paid', l.instalments_paid,
      'instalments_remaining', greatest(0, l.term_months - l.instalments_paid),
      'status', l.status,
      'next_payment_due', l.next_payment_due_date,
      'repayment_progress',
        case
          when (l.total_repayable + l.application_fee_charged) = 0 then 0
          else round(l.total_repaid / (l.total_repayable + l.application_fee_charged) * 100, 2)
        end
    ) order by l.next_payment_due_date)
    from loans l join loan_products lp on lp.id = l.loan_product_id
    where l.member_id = m.id and l.status in ('Active','Disbursed','Defaulted')),
    '[]'::jsonb
  ) as active_loans
from members m;

notify pgrst, 'reload schema';