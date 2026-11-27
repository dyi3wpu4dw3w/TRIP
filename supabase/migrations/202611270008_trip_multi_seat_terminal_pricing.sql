
alter table public.trips
  add column if not exists origin_state text,
  add column if not exists destination_state text,
  add column if not exists origin_terminal text,
  add column if not exists destination_terminal text;

alter table public.bookings
  add column if not exists booking_group_id uuid;

create index if not exists bookings_group_idx
  on public.bookings(booking_group_id) where booking_group_id is not null;

create or replace function public.create_trip_bookings(
  p_trip_id uuid,
  p_seat_numbers integer[],
  p_passenger_name text,
  p_passenger_phone text
)
returns table(booking_id uuid, booking_code text, seat_number integer, amount_sdg numeric, booking_group_id uuid)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_group_id uuid := gen_random_uuid();
  v_seat integer;
  v_capacity integer;
  v_status public.trip_status;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if nullif(trim(p_passenger_name),'') is null or nullif(trim(p_passenger_phone),'') is null then
    raise exception 'Passenger name and phone are required';
  end if;
  if p_seat_numbers is null or cardinality(p_seat_numbers) < 1 or cardinality(p_seat_numbers) > 80 then
    raise exception 'Choose between 1 and 80 seats';
  end if;
  if (select count(distinct x) from unnest(p_seat_numbers) as x) <> cardinality(p_seat_numbers) then
    raise exception 'Duplicate seat numbers';
  end if;

  select b.seat_count, t.status into v_capacity, v_status
  from public.trips t
  join public.buses b on b.id=t.bus_id
  join public.operators o on o.id=t.operator_id and o.verified=true
  where t.id=p_trip_id
  for update of t;

  if not found or v_status <> 'scheduled' then raise exception 'Trip is unavailable'; end if;
  if exists (
    select 1 from unnest(p_seat_numbers) s
    where s < 1 or s > v_capacity
  ) then raise exception 'Invalid seat'; end if;

  foreach v_seat in array p_seat_numbers loop
    return query
    insert into public.bookings(
      trip_id, passenger_id, passenger_name, passenger_phone,
      seat_number, booking_group_id
    )
    values(p_trip_id, v_user_id, trim(p_passenger_name), trim(p_passenger_phone), v_seat, v_group_id)
    returning bookings.id, bookings.booking_code, bookings.seat_number,
              bookings.amount_sdg, bookings.booking_group_id;
  end loop;
end;
$$;

revoke all on function public.create_trip_bookings(uuid,integer[],text,text) from public, anon, authenticated;
grant execute on function public.create_trip_bookings(uuid,integer[],text,text) to authenticated;

create or replace function public.search_trip_availability(
  p_origin_city text,
  p_destination_city text,
  p_departure_date date,
  p_min_seats integer default 1
)
returns table(
  id uuid,
  company text,
  origin_city text,
  destination_city text,
  origin_state text,
  destination_state text,
  origin_terminal text,
  destination_terminal text,
  departure_at timestamptz,
  arrival_at timestamptz,
  price_sdg numeric,
  bus_name text,
  total_seats integer,
  available_seats integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, o.name, t.origin_city, t.destination_city,
         t.origin_state, t.destination_state, t.origin_terminal, t.destination_terminal,
         t.departure_at, t.arrival_at, t.price_sdg, b.name, b.seat_count,
         greatest(0, b.seat_count - coalesce((
           select count(*)::integer from public.bookings bk
           where bk.trip_id=t.id and bk.status in ('pending','confirmed')
         ),0))
  from public.trips t
  join public.buses b on b.id=t.bus_id
  join public.operators o on o.id=t.operator_id and o.verified=true
  where t.status='scheduled'
    and t.origin_city=p_origin_city
    and t.destination_city=p_destination_city
    and t.departure_at::date=p_departure_date
    and greatest(0, b.seat_count - coalesce((
      select count(*)::integer from public.bookings bk
      where bk.trip_id=t.id and bk.status in ('pending','confirmed')
    ),0)) >= greatest(1, coalesce(p_min_seats,1))
  order by t.departure_at;
$$;

revoke all on function public.search_trip_availability(text,text,date,integer) from public;
grant execute on function public.search_trip_availability(text,text,date,integer) to anon, authenticated;
