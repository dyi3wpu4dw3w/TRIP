drop policy if exists "profiles read own" on public.profiles;
drop policy if exists "trip admins read all profiles" on public.profiles;
create policy "profiles read own or trip admin"
on public.profiles for select to authenticated
using (id=(select auth.uid()) or (select public.is_trip_admin()));

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime'
      and schemaname='public'
      and tablename='trip_payment_submissions'
  ) then
    alter publication supabase_realtime add table public.trip_payment_submissions;
  end if;
end
$$;
