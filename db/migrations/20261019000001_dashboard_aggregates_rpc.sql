-- ============================================================
-- Dashboard aggregates RPC
-- ============================================================
-- Previously the Worker computed these aggregates by looping over
-- every member and calling two RPCs per member (148 sequential
-- HTTP calls), which exceeded Cloudflare Workers' 30s duration
-- limit and hung the response forever.
--
-- This function does the same math in a single SQL statement,
-- executed entirely server-side. No HTTP round trips.
-- ============================================================

create or replace function public.get_dashboard_aggregates()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select jsonb_build_object(
    'aggregate_savings', coalesce((
      select sum(public.get_member_savings_balance(m.id))
      from members m
    ), 0),

    'aggregate_loans_outstanding', coalesce((
      select sum(public.get_member_total_outstanding_loans(m.id))
      from members m
    ), 0),

    'active_loans_count', (select count(*) from loans
                           where status in ('Active','Disbursed','Defaulted')),

    'defaulted_loans_count', (select count(*) from loans
                              where status = 'Defaulted'),

    'pending_payments', (select count(*) from payment_notifications
                         where status = 'Pending'),

    'unidentified_deposits', (select count(*) from unidentified_deposits
                              where status in ('Unclaimed','Escalated')),

    'today_transactions', (select count(*) from ledger_entries
                           where created_at >= current_date),

    'defaulting_members_count', (select count(distinct member_id)
                                 from member_contribution_defaults
                                 where paid = false and due_date < current_date)
  );
$$;

grant execute on function public.get_dashboard_aggregates() to authenticated;

notify pgrst, 'reload schema';