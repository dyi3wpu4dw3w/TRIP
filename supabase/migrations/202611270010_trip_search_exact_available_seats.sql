drop function if exists public.search_trip_availability(text,text,date,integer);
create function public.search_trip_availability(p_origin_city text,p_destination_city text,p_departure_date date,p_min_seats integer default 1)
returns table(id uuid,company text,origin_city text,destination_city text,origin_state text,destination_state text,origin_terminal text,destination_terminal text,departure_at timestamptz,arrival_at timestamptz,price_sdg numeric,bus_name text,total_seats integer,available_seats integer,available_seat_numbers integer[])
language sql stable security definer set search_path=''
as $$
 select t.id,o.name,t.origin_city,t.destination_city,t.origin_state,t.destination_state,t.origin_terminal,t.destination_terminal,t.departure_at,t.arrival_at,t.price_sdg,b.name,b.seat_count,
 count(av.seat_no)::integer,
 coalesce(array_agg(av.seat_no order by av.seat_no) filter(where av.seat_no is not null),array[]::integer[])
 from public.trips t join public.buses b on b.id=t.bus_id join public.operators o on o.id=t.operator_id and o.verified=true
 left join lateral (
   select gs.seat_no from generate_series(1,b.seat_count) as gs(seat_no)
   where not exists(select 1 from public.bookings bk where bk.trip_id=t.id and bk.seat_number=gs.seat_no and bk.status in ('pending','confirmed'))
 ) av on true
 where t.status='scheduled' and t.origin_city=p_origin_city and t.destination_city=p_destination_city and t.departure_at::date=p_departure_date
 group by t.id,o.name,b.name,b.seat_count
 having count(av.seat_no)>=greatest(1,coalesce(p_min_seats,1))
 order by t.departure_at;
$$;
revoke all on function public.search_trip_availability(text,text,date,integer) from public;
grant execute on function public.search_trip_availability(text,text,date,integer) to anon,authenticated;
