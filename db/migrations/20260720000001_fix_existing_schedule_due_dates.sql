-- ============================================================
-- One-time fix: realign existing schedule due dates to the
-- "10th of following month" rule. Safe to run once.
-- ============================================================
UPDATE loan_repayment_schedule s
SET due_date = (
  date_trunc('month', l.disbursed_at::date)
  + (s.instalment_number || ' month')::interval
  + interval '9 days'
)::date
FROM loans l
WHERE s.loan_id = l.id
  AND l.disbursed_at IS NOT NULL;

UPDATE loans l
SET next_payment_due_date = (
  SELECT min(s.due_date)
  FROM loan_repayment_schedule s
  WHERE s.loan_id = l.id
    AND s.amount_paid < s.scheduled_amount
)
WHERE l.status IN ('Active', 'Disbursed', 'Defaulted');