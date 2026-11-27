grant execute on function private.driver_update_trip_status(uuid,public.trip_status) to authenticated;
create or replace function public.driver_update_trip_status(p_trip_id uuid,p_status public.trip_status)
returns void language plpgsql security invoker set search_path='' as $$
begin
 perform private.driver_update_trip_status(p_trip_id,p_status);
end;
$$;
revoke all on function public.driver_update_trip_status(uuid,public.trip_status) from public,anon;
grant execute on function public.driver_update_trip_status(uuid,public.trip_status) to authenticated;
