-- Atomic booking validation. The trigger derives price/status from the trip, not client input.
create or replace function public.prepare_trip_booking()
returns trigger
language plpgsql
security invoker
set search_path = ''
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

  select t.price_sdg, b.seat_count
    into v_price, v_seat_count
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
create trigger prepare_trip_booking_before_insert
before insert on public.bookings
for each row execute procedure public.prepare_trip_booking();

-- The RPC is SECURITY INVOKER; RLS and the trigger enforce ownership and authoritative price.
create or replace function public.create_trip_booking(
  p_trip_id uuid,
  p_seat_number integer,
  p_passenger_name text,
  p_passenger_phone text
)
returns table(booking_id uuid, booking_code text, amount_sdg numeric)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then raise exception 'Authentication required'; end if;

  return query
  insert into public.bookings(
    trip_id, passenger_id, passenger_name, passenger_phone, seat_number
  )
  values (
    p_trip_id, v_user_id, trim(p_passenger_name), trim(p_passenger_phone), p_seat_number
  )
  returning id, bookings.booking_code, bookings.amount_sdg;
end;
$$;
revoke all on function public.create_trip_booking(uuid,integer,text,text) from public, anon, authenticated;
grant execute on function public.create_trip_booking(uuid,integer,text,text) to authenticated;
grant insert on public.bookings to authenticated;
drop policy if exists "bookings create own" on public.bookings;
create policy "bookings create own" on public.bookings
for insert to authenticated with check (passenger_id=(select auth.uid()));
