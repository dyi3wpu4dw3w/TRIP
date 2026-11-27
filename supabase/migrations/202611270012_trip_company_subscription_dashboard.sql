-- Company subscription-gated dashboard
create table if not exists public.operator_subscriptions (
 id uuid primary key default gen_random_uuid(),
 operator_id uuid not null references public.operators(id) on delete cascade,
 amount_sdg numeric(14,2) not null check (amount_sdg > 0),
 status text not null default 'pending' check (status in ('pending','active','expired','rejected','suspended')),
 payment_reference text,
 payment_note text,
 starts_at timestamptz,
 ends_at timestamptz,
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now()
);
create index if not exists operator_subscriptions_operator_status_idx on public.operator_subscriptions(operator_id,status,ends_at desc);
alter table public.operator_subscriptions enable row level security;

create table if not exists public.operator_drivers_details (
 id uuid primary key default gen_random_uuid(),
 operator_id uuid not null references public.operators(id) on delete cascade,
 full_name text not null,
 phone text not null,
 license_number text,
 user_id uuid references auth.users(id) on delete set null,
 status text not null default 'invited' check (status in ('invited','active','inactive')),
 created_at timestamptz not null default now(),
 unique(operator_id,phone)
);
alter table public.operator_drivers_details enable row level security;

create schema if not exists private;
create or replace function private.operator_has_active_subscription(p_operator_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
 select exists (select 1 from public.operator_subscriptions s where s.operator_id=p_operator_id and s.status='active' and (s.ends_at is null or s.ends_at>now()));
$$;
revoke all on function private.operator_has_active_subscription(uuid) from public, anon;
grant usage on schema private to authenticated, anon;
grant execute on function private.operator_has_active_subscription(uuid) to authenticated, anon;

create policy "subscription owner reads own" on public.operator_subscriptions for select to authenticated
using (exists(select 1 from public.operators o where o.id=operator_subscriptions.operator_id and o.owner_id=(select auth.uid())) or (select public.is_trip_admin()));
create policy "subscription owner requests" on public.operator_subscriptions for insert to authenticated
with check (status='pending' and starts_at is null and ends_at is null and reviewed_by is null and exists(select 1 from public.operators o where o.id=operator_subscriptions.operator_id and o.owner_id=(select auth.uid())));
create policy "subscription admin manages" on public.operator_subscriptions for all to authenticated
using ((select public.is_trip_admin())) with check ((select public.is_trip_admin()));

create policy "driver details owner reads" on public.operator_drivers_details for select to authenticated
using (user_id=(select auth.uid()) or exists(select 1 from public.operators o where o.id=operator_drivers_details.operator_id and o.owner_id=(select auth.uid())) or (select public.is_trip_admin()));
create policy "driver details owner manages active subscription" on public.operator_drivers_details for all to authenticated
using ((exists(select 1 from public.operators o where o.id=operator_drivers_details.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(operator_drivers_details.operator_id)) or (select public.is_trip_admin()))
with check ((exists(select 1 from public.operators o where o.id=operator_drivers_details.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(operator_drivers_details.operator_id)) or (select public.is_trip_admin()));

drop policy if exists "buses read verified operators" on public.buses;
create policy "buses read subscribed operators" on public.buses for select to anon, authenticated
using (exists(select 1 from public.operators o where o.id=buses.operator_id and ((o.verified=true and private.operator_has_active_subscription(o.id)) or o.owner_id=(select auth.uid()))));
create policy "bus owner manages active subscription" on public.buses for all to authenticated
using ((exists(select 1 from public.operators o where o.id=buses.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(buses.operator_id)) or (select public.is_trip_admin()))
with check ((exists(select 1 from public.operators o where o.id=buses.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(buses.operator_id)) or (select public.is_trip_admin()));

drop policy if exists "trips read published" on public.trips;
create policy "trips read subscribed published" on public.trips for select to anon, authenticated
using ((status='scheduled' and exists(select 1 from public.operators o where o.id=trips.operator_id and o.verified=true and private.operator_has_active_subscription(o.id))) or exists(select 1 from public.operators o where o.id=trips.operator_id and o.owner_id=(select auth.uid())) or exists(select 1 from public.operator_members m where m.operator_id=trips.operator_id and m.user_id=(select auth.uid())));
create policy "trip owner manages active subscription" on public.trips for all to authenticated
using ((exists(select 1 from public.operators o where o.id=trips.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(trips.operator_id)) or (select public.is_trip_admin()))
with check ((exists(select 1 from public.operators o where o.id=trips.operator_id and o.owner_id=(select auth.uid())) and private.operator_has_active_subscription(trips.operator_id)) or (select public.is_trip_admin()));

grant select, insert, update, delete on public.operator_subscriptions to authenticated;
grant select, insert, update, delete on public.operator_drivers_details to authenticated;
grant select, insert, update, delete on public.buses, public.trips to authenticated;
