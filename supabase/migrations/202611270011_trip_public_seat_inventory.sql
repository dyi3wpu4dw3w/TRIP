create table if not exists public.trip_seat_inventory(
 trip_id uuid not null references public.trips(id) on delete cascade,
 seat_number integer not null check(seat_number>0),
 booking_id uuid not null unique references public.bookings(id) on delete cascade,
 primary key(trip_id,seat_number)
);
alter table public.trip_seat_inventory enable row level security;
drop policy if exists "public can read occupied seat numbers" on public.trip_seat_inventory;
create policy "public can read occupied seat numbers" on public.trip_seat_inventory for select to anon,authenticated using(true);
grant select on public.trip_seat_inventory to anon,authenticated;

create or replace function public.sync_trip_seat_inventory()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if tg_op='DELETE' then
  delete from public.trip_seat_inventory where booking_id=old.id;
  return old;
 end if;
 if tg_op='UPDATE' then
  delete from public.trip_seat_inventory where booking_id=new.id;
 end if;
 if new.status in ('pending','confirmed') then
  insert into public.trip_seat_inventory(trip_id,seat_number,booking_id)
  values(new.trip_id,new.seat_number,new.id)
  on conflict(trip_id,seat_number) do nothing;
 end if;
 return new;
end;
$$;
revoke all on function public.sync_trip_seat_inventory() from public,anon,authenticated;
drop trigger if exists sync_trip_seat_inventory_after_booking on public.bookings;
create trigger sync_trip_seat_inventory_after_booking
after insert or update of status,trip_id,seat_number or delete on public.bookings
for each row execute function public.sync_trip_seat_inventory();

insert into public.trip_seat_inventory(trip_id,seat_number,booking_id)
select trip_id,seat_number,id from public.bookings where status in ('pending','confirmed')
on conflict(trip_id,seat_number) do nothing;

drop function if exists public.search_trip_availability(text,text,date,integer);
create function public.search_trip_availability(p_origin_city text,p_destination_city text,p_departure_date date,p_min_seats integer default 1)
returns table(id uuid,company text,origin_city text,destination_city text,origin_state text,destination_state text,origin_terminal text,destination_terminal text,departure_at timestamptz,arrival_at timestamptz,price_sdg numeric,bus_name text,total_seats integer,available_seats integer,available_seat_numbers integer[])
language sql stable security invoker set search_path=''
as $$
 select t.id,o.name,t.origin_city,t.destination_city,t.origin_state,t.destination_state,t.origin_terminal,t.destination_terminal,t.departure_at,t.arrival_at,t.price_sdg,b.name,b.seat_count,
 count(av.seat_no)::integer,
 coalesce(array_agg(av.seat_no order by av.seat_no) filter(where av.seat_no is not null),array[]::integer[])
 from public.trips t join public.buses b on b.id=t.bus_id join public.operators o on o.id=t.operator_id and o.verified=true
 left join lateral (
   select gs.seat_no from generate_series(1,b.seat_count) as gs(seat_no)
   where not exists(select 1 from public.trip_seat_inventory si where si.trip_id=t.id and si.seat_number=gs.seat_no)
 ) av on true
 where t.status='scheduled' and t.origin_city=p_origin_city and t.destination_city=p_destination_city and t.departure_at::date=p_departure_date
 group by t.id,o.name,b.name,b.seat_count
 having count(av.seat_no)>=greatest(1,coalesce(p_min_seats,1))
 order by t.departure_at;
$$;
revoke all on function public.search_trip_availability(text,text,date,integer) from public;
grant execute on function public.search_trip_availability(text,text,date,integer) to anon,authenticated;
