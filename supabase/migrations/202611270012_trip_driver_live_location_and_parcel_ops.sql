alter table public.parcels
  add column if not exists tracking_code text,
  add column if not exists operator_id uuid references public.operators(id) on delete set null,
  add column if not exists price_sdg numeric(12,2),
  add column if not exists updated_at timestamptz not null default now();
update public.parcels set tracking_code='TRP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)) where tracking_code is null;
alter table public.parcels alter column tracking_code set default ('TRP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)));
alter table public.parcels alter column tracking_code set not null;
create unique index if not exists parcels_tracking_code_uidx on public.parcels(tracking_code);
create index if not exists parcels_operator_created_idx on public.parcels(operator_id,created_at desc);
drop policy if exists "parcels company reads assigned" on public.parcels;
create policy "parcels company reads assigned" on public.parcels for select to authenticated using (
 exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()))
 or (select public.is_trip_admin())
);
drop policy if exists "parcels company updates assigned" on public.parcels;
create policy "parcels company updates assigned" on public.parcels for update to authenticated
using (exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()) and o.verified=true) or (select public.is_trip_admin()))
with check (exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()) and o.verified=true) or (select public.is_trip_admin()));
grant update on public.parcels to authenticated;
create table if not exists public.driver_trip_locations (
 trip_id uuid primary key references public.trips(id) on delete cascade,
 driver_id uuid not null references public.profiles(id) on delete cascade,
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 accuracy_m double precision,
 updated_at timestamptz not null default now()
);
alter table public.driver_trip_locations enable row level security;
drop policy if exists "trip participants read live driver location" on public.driver_trip_locations;
create policy "trip participants read live driver location" on public.driver_trip_locations for select to authenticated using (
 driver_id=(select auth.uid())
 or exists(select 1 from public.trips t join public.operators o on o.id=t.operator_id where t.id=driver_trip_locations.trip_id and o.owner_id=(select auth.uid()))
 or (select public.is_trip_admin())
 or exists(select 1 from public.bookings b join public.payments p on p.booking_id=b.id where b.trip_id=driver_trip_locations.trip_id and b.passenger_id=(select auth.uid()) and b.status='confirmed' and p.status='succeeded')
);
drop policy if exists "assigned driver writes own live location" on public.driver_trip_locations;
create policy "assigned driver writes own live location" on public.driver_trip_locations for insert to authenticated with check (
 driver_id=(select auth.uid()) and exists(select 1 from public.trips t where t.id=driver_trip_locations.trip_id and t.driver_id=(select auth.uid()) and t.status in ('boarding','departed'))
);
drop policy if exists "assigned driver updates own live location" on public.driver_trip_locations;
create policy "assigned driver updates own live location" on public.driver_trip_locations for update to authenticated
using (driver_id=(select auth.uid()) and exists(select 1 from public.trips t where t.id=driver_trip_locations.trip_id and t.driver_id=(select auth.uid()) and t.status in ('boarding','departed')))
with check (driver_id=(select auth.uid()) and exists(select 1 from public.trips t where t.id=driver_trip_locations.trip_id and t.driver_id=(select auth.uid()) and t.status in ('boarding','departed')));
grant select,insert,update on public.driver_trip_locations to authenticated;
do $$ begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime')
 and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='driver_trip_locations') then
  alter publication supabase_realtime add table public.driver_trip_locations;
 end if;
end $$;
