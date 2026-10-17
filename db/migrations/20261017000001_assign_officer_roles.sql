-- ============================================================
-- Assign officer roles per bye-laws and Committee decision
-- ============================================================
-- §24 Chairman, §25 Treasurer, §26 Secretary, §27 Trustees,
-- §29 Management Committee, §33 Loan Committee.
--
-- SystemAdmin is a technical role created by the software, not
-- by the bye-laws. It carries no financial or governance power.
-- ============================================================

update public.members set role = 'Chairman'              where registration_number = '0007';
update public.members set role = 'Treasurer'             where registration_number = '0004';
update public.members set role = 'Secretary'             where registration_number = '0049';
update public.members set role = 'LoanCommitteeChairman' where registration_number = '0003';
update public.members set role = 'LoanCommittee'         where registration_number in ('0006','0028','0052');
update public.members set role = 'SystemAdmin'           where registration_number = '0024';

-- Verify: any officer missed will still show 'Member'
do $$
declare
  v_expected int := 8;
  v_actual   int;
begin
  select count(*) into v_actual
  from public.members
  where role <> 'Member';

  if v_actual <> v_expected then
    raise exception 'Expected % officer roles, found %', v_expected, v_actual;
  end if;
end $$;

notify pgrst, 'reload schema';