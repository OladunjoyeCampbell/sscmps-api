-- ============================================================
-- Link new auth.users to pre-loaded members by email
-- ============================================================
-- When Supabase Auth creates a user (invitation, self-signup,
-- or admin-created), match the email to a member row with a
-- null auth_user_id and link them. This is how new accounts
-- get access to their pre-migrated member data.
-- ============================================================

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_member_id uuid;
begin
  select id into v_member_id
  from public.members
  where lower(email) = lower(new.email)
    and auth_user_id is null
  limit 1;

  if v_member_id is not null then
    update public.members
    set auth_user_id = new.id,
        updated_at = now()
    where id = v_member_id;
    perform write_audit('AUTH_USER_LINKED','member',v_member_id,
      jsonb_build_object('auth_user_id', new.id, 'email', new.email));
  else
    perform write_audit('AUTH_USER_UNLINKED',null,null,
      jsonb_build_object('auth_user_id', new.id, 'email', new.email,
        'reason','no matching member with null auth_user_id'));
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

notify pgrst, 'reload schema';