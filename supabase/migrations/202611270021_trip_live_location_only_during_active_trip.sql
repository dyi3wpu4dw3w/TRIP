drop policy if exists "trip participants read live driver location" on public.driver_trip_locations;
create policy "trip participants read live driver location" on public.driver_trip_locations for select to authenticated using (
 driver_id=(select auth.uid())
 or exists(select 1 from public.trips t join public.operators o on o.id=t.operator_id where t.id=driver_trip_locations.trip_id and o.owner_id=(select auth.uid()))
 or (select public.is_trip_admin())
 or exists(select 1 from public.bookings b join public.payments p on (p.booking_id=b.id or (p.booking_group_id is not null and p.booking_group_id=b.booking_group_id))
 join public.trips t on t.id=b.trip_id where b.trip_id=driver_trip_locations.trip_id and b.passenger_id=(select auth.uid())
 and b.status='confirmed' and p.status='succeeded' and t.status in ('boarding','departed'))
);
