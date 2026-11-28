drop policy if exists "trip admins read all profiles" on public.profiles;
create policy "trip admins read all profiles"
on public.profiles for select to authenticated
using ((select public.is_trip_admin()));

create or replace function private.admin_approve_driver_profile(p_profile_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_updated integer;
begin
  if auth.uid() is null or not public.is_trip_admin() then
    raise exception 'Administrator access required';
  end if;

  update public.profiles
  set registration_status='active'
  where id=p_profile_id
    and requested_role='driver'
    and registration_status='pending_review';

  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;

revoke all on function private.admin_approve_driver_profile(uuid) from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.admin_approve_driver_profile(uuid) to authenticated;

create or replace function public.admin_approve_driver_account(p_profile_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_trip_admin() then
    raise exception 'Administrator access required';
  end if;
  return private.admin_approve_driver_profile(p_profile_id);
end;
$$;

revoke all on function public.admin_approve_driver_account(uuid) from public, anon;
grant execute on function public.admin_approve_driver_account(uuid) to authenticated;
