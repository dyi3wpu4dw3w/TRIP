create or replace function public.create_trip_bookings(p_trip_id uuid,p_seat_numbers integer[],p_passenger_name text,p_passenger_phone text)
returns table(booking_id uuid,booking_code text,seat_number integer,amount_sdg numeric,booking_group_id uuid)
language plpgsql security invoker set search_path=''
as $$
declare v_user_id uuid; v_group_id uuid:=gen_random_uuid(); v_seat integer; v_capacity integer; v_status public.trip_status;
begin
 v_user_id:=auth.uid();
 if v_user_id is null then raise exception 'Authentication required'; end if;
 if nullif(trim(p_passenger_name),'') is null or nullif(trim(p_passenger_phone),'') is null then raise exception 'Passenger name and phone are required'; end if;
 if p_seat_numbers is null or cardinality(p_seat_numbers)<1 or cardinality(p_seat_numbers)>80 then raise exception 'Choose between 1 and 80 seats'; end if;
 if (select count(distinct seat_no) from unnest(p_seat_numbers) as seats(seat_no))<>cardinality(p_seat_numbers) then raise exception 'Duplicate seat numbers'; end if;
 select b.seat_count,t.status into v_capacity,v_status from public.trips t join public.buses b on b.id=t.bus_id join public.operators o on o.id=t.operator_id and o.verified=true where t.id=p_trip_id for update of t;
 if not found or v_status<>'scheduled' then raise exception 'Trip is unavailable'; end if;
 if exists(select 1 from unnest(p_seat_numbers) as seats(seat_no) where seat_no<1 or seat_no>v_capacity) then raise exception 'Invalid seat'; end if;
 foreach v_seat in array p_seat_numbers loop
  return query insert into public.bookings(trip_id,passenger_id,passenger_name,passenger_phone,seat_number,booking_group_id)
  values(p_trip_id,v_user_id,trim(p_passenger_name),trim(p_passenger_phone),v_seat,v_group_id)
  returning bookings.id,bookings.booking_code,bookings.seat_number,bookings.amount_sdg,bookings.booking_group_id;
 end loop;
end; $$;
revoke all on function public.create_trip_bookings(uuid,integer[],text,text) from public,anon,authenticated;
grant execute on function public.create_trip_bookings(uuid,integer[],text,text) to authenticated;
