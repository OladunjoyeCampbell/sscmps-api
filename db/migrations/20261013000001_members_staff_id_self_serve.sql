-- ============================================================
-- Make members.staff_id self-serve
-- ============================================================
-- Staff ID is not required by the bye-laws (§35 lists only name,
-- address, admission date, next of kin, contribution). We do not
-- ask the Treasurer for 74 employee numbers during migration.
-- Instead the column becomes nullable and is filled by each
-- member on first login via update_member_profile().
--
-- The UNIQUE constraint is retained: PostgreSQL treats NULL as
-- distinct, so many NULLs coexist while duplicates once set are
-- still rejected.
-- ============================================================

alter table public.members
  alter column staff_id drop not null;

comment on column public.members.staff_id is
  'Niger State Polytechnic employee number. Optional at admission; members complete it via update_member_profile(). Unique when set.';

-- Signature changes (9th arg added), so DROP first.
drop function if exists public.update_member_profile(
  text, text, text, text, text, text, text, text
);

create or replace function public.update_member_profile(
  p_phone                    text default null,
  p_department               text default null,
  p_position                 text default null,
  p_home_address             text default null,
  p_next_of_kin_name         text default null,
  p_next_of_kin_phone        text default null,
  p_next_of_kin_relationship text default null,
  p_email                    text default null,
  p_staff_id                 text default null
) returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if app_member_id() is null then
    raise exception 'Authenticated member record not found';
  end if;

  update members set
    phone                    = p_phone,
    department               = p_department,
    position                 = p_position,
    home_address             = p_home_address,
    next_of_kin_name         = p_next_of_kin_name,
    next_of_kin_phone        = p_next_of_kin_phone,
    next_of_kin_relationship = p_next_of_kin_relationship,
    email                    = coalesce(nullif(trim(p_email), ''), email),
    staff_id                 = coalesce(nullif(trim(p_staff_id), ''), staff_id)
  where id = app_member_id();

  perform write_audit('UPDATE_MEMBER_PROFILE', 'member', app_member_id());
end;
$$;

grant execute on function public.update_member_profile(
  text, text, text, text, text, text, text, text, text
) to authenticated;

notify pgrst, 'reload schema';