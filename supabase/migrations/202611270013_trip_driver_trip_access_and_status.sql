drop policy if exists "assigned driver reads own trips" on public.trips;
create policy "assigned driver reads own trips" on public.trips for select to authenticated using (driver_id=(select auth.uid()));
create or replace function private.driver_update_trip_status(p_trip_id uuid,p_status public.trip_status)
returns void language plpgsql security definer set search_path='' as $$
declare v_old public.trip_status;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_status not in ('boarding','departed','completed') then raise exception 'Invalid driver status'; end if;
 select status into v_old from public.trips where id=p_trip_id and driver_id=auth.uid() for update;
 if not found then raise exception 'Trip not assigned to this driver'; end if;
 if not ((v_old='scheduled' and p_status='boarding') or (v_old='boarding' and p_status='departed') or (v_old='departed' and p_status='completed')) then raise exception 'Invalid trip status transition'; end if;
 update public.trips set status=p_status where id=p_trip_id;
end;
$$;
revoke all on function private.driver_update_trip_status(uuid,public.trip_status) from public,anon;
grant execute on function private.driver_update_trip_status(uuid,public.trip_status) to authenticated;
