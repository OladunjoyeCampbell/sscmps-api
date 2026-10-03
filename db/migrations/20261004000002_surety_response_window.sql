-- ============================================================
-- Per-product surety response window
-- ============================================================
-- Hours an invitation remains Pending before auto-expiry.
-- Matched to the relative urgency of each loan product:
--   Emergency          48h  (member needs funds fast)
--   Short-Term         72h
--   Essential Commodity 120h
--   Long-Term          168h (7 days)
--
-- Default is 120h for any future product not explicitly set.
-- ============================================================

alter table public.loan_products
  add column if not exists surety_response_window_hours integer not null default 120
    check (surety_response_window_hours > 0);

update public.loan_products set surety_response_window_hours = 48  where name = 'Emergency';
update public.loan_products set surety_response_window_hours = 72  where name = 'Short-Term';
update public.loan_products set surety_response_window_hours = 120 where name = 'Essential Commodity';
update public.loan_products set surety_response_window_hours = 168 where name = 'Long-Term';

comment on column public.loan_products.surety_response_window_hours is
  'Hours a surety invitation stays Pending before auto-expiry. '
  'Per-product because urgency differs: Emergency 48h, Short-Term 72h, '
  'Essential Commodity 120h, Long-Term 168h.';

notify pgrst, 'reload schema';