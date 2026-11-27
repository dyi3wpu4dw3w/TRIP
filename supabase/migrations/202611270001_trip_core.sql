create extension if not exists pgcrypto;

create type public.trip_status as enum ('scheduled','boarding','departed','completed','cancelled');
create type public.booking_status as enum ('pending','confirmed','cancelled','refunded');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text unique,
  created_at timestamptz not null default now()
);
create table public.operators (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id),
  name text not null,
  phone text not null,
  verified boolean not null default false,
  created_at timestamptz not null default now()
);
create table public.operator_members (
  operator_id uuid not null references public.operators(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key(operator_id,user_id)
);
create table public.buses (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id) on delete cascade,
  name text not null,
  plate_number text not null,
  seat_count integer not null check(seat_count between 1 and 80),
  created_at timestamptz not null default now()
);
create table public.trips (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(id),
  bus_id uuid not null references public.buses(id),
  origin_city text not null,
  destination_city text not null,
  departure_at timestamptz not null,
  arrival_at timestamptz,
  price_sdg numeric(14,2) not null check(price_sdg >= 0),
  status public.trip_status not null default 'scheduled',
  created_at timestamptz not null default now(),
  check(origin_city <> destination_city)
);
create index trips_lookup_idx on public.trips(origin_city,destination_city,departure_at) where status='scheduled';

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  booking_code text not null unique,
  trip_id uuid not null references public.trips(id),
  passenger_id uuid not null references public.profiles(id),
  passenger_name text not null,
  passenger_phone text not null,
  seat_number integer not null check(seat_number > 0),
  status public.booking_status not null default 'pending',
  amount_sdg numeric(14,2) not null check(amount_sdg >= 0),
  created_at timestamptz not null default now()
);
create unique index bookings_active_seat_unique
  on public.bookings(trip_id,seat_number)
  where status in ('pending','confirmed');

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id),
  provider text not null,
  provider_reference text unique,
  amount_sdg numeric(14,2) not null check(amount_sdg > 0),
  currency text not null default 'SDG',
  status text not null default 'initiated'
    check(status in ('initiated','pending','succeeded','failed','refunded')),
  created_at timestamptz not null default now()
);
create table public.parcels (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id),
  sender_name text not null,
  sender_phone text not null,
  receiver_name text not null,
  receiver_phone text not null,
  origin_city text not null,
  destination_city text not null,
  description text,
  status text not null default 'requested'
    check(status in ('requested','accepted','in_transit','delivered','cancelled')),
  created_at timestamptz not null default now(),
  check(origin_city <> destination_city)
);

create function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles(id,full_name)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''));
  return new;
end;
$$;
revoke all on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create function public.prepare_trip_booking()
returns trigger language plpgsql security invoker set search_path = ''
as $$
declare
  v_price numeric(14,2);
  v_seat_count integer;
begin
  if auth.uid() is null or new.passenger_id is distinct from auth.uid() then
    raise exception 'Authentication required';
  end if;
  if nullif(trim(new.passenger_name),'') is null or nullif(trim(new.passenger_phone),'') is null then
    raise exception 'Passenger name and phone are required';
  end if;
  select t.price_sdg,b.seat_count into v_price,v_seat_count
  from public.trips t
  join public.buses b on b.id=t.bus_id
  join public.operators o on o.id=t.operator_id and o.verified=true
  where t.id=new.trip_id and t.status='scheduled';
  if not found then raise exception 'Trip is unavailable'; end if;
  if new.seat_number < 1 or new.seat_number > v_seat_count then
    raise exception 'Invalid seat';
  end if;
  new.booking_code := 'TR-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  new.amount_sdg := v_price;
  new.status := 'pending';
  return new;
end;
$$;
revoke all on function public.prepare_trip_booking() from public, anon, authenticated;
create trigger prepare_trip_booking_before_insert before insert on public.bookings
for each row execute procedure public.prepare_trip_booking();

create function public.create_trip_booking(
  p_trip_id uuid,p_seat_number integer,p_passenger_name text,p_passenger_phone text
)
returns table(booking_id uuid,booking_code text,amount_sdg numeric)
language plpgsql security invoker set search_path = ''
as $$
declare v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'Authentication required'; end if;
  return query
  insert into public.bookings(trip_id,passenger_id,passenger_name,passenger_phone,seat_number)
  values(p_trip_id,v_user_id,trim(p_passenger_name),trim(p_passenger_phone),p_seat_number)
  returning id,bookings.booking_code,bookings.amount_sdg;
end;
$$;
revoke all on function public.create_trip_booking(uuid,integer,text,text) from public,anon,authenticated;
grant execute on function public.create_trip_booking(uuid,integer,text,text) to authenticated;

alter table public.profiles enable row level security;
alter table public.operators enable row level security;
alter table public.operator_members enable row level security;
alter table public.buses enable row level security;
alter table public.trips enable row level security;
alter table public.bookings enable row level security;
alter table public.payments enable row level security;
alter table public.parcels enable row level security;

create policy "profiles read own" on public.profiles for select to authenticated
using(id=(select auth.uid()));
create policy "profiles update own" on public.profiles for update to authenticated
using(id=(select auth.uid())) with check(id=(select auth.uid()));
create policy "operators read verified or owned" on public.operators for select to anon,authenticated
using(verified=true or owner_id=(select auth.uid()));
create policy "operators create own" on public.operators for insert to authenticated
with check(owner_id=(select auth.uid()));
create policy "operator members read own" on public.operator_members for select to authenticated
using(user_id=(select auth.uid()));
create policy "buses read verified operators" on public.buses for select to anon,authenticated
using(exists(select 1 from public.operators o where o.id=buses.operator_id and
  (o.verified=true or o.owner_id=(select auth.uid()))));
create policy "trips read published" on public.trips for select to anon,authenticated
using((status='scheduled' and exists(select 1 from public.operators o
  where o.id=trips.operator_id and o.verified=true))
  or exists(select 1 from public.operator_members m
  where m.operator_id=trips.operator_id and m.user_id=(select auth.uid())));
create policy "bookings read own" on public.bookings for select to authenticated
using(passenger_id=(select auth.uid()));
create policy "bookings create own" on public.bookings for insert to authenticated
with check(passenger_id=(select auth.uid()));
create policy "payments read own" on public.payments for select to authenticated
using(exists(select 1 from public.bookings b where b.id=payments.booking_id
  and b.passenger_id=(select auth.uid())));
create policy "parcels read own" on public.parcels for select to authenticated
using(sender_id=(select auth.uid()));
create policy "parcels create own" on public.parcels for insert to authenticated
with check(sender_id=(select auth.uid()));

grant usage on schema public to anon,authenticated;
grant select on public.operators,public.buses,public.trips to anon,authenticated;
grant select,update on public.profiles to authenticated;
grant select on public.operator_members,public.bookings,public.payments,public.parcels to authenticated;
grant insert on public.operators,public.bookings,public.parcels to authenticated;
