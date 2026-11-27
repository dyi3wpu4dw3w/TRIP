drop policy if exists "trip admins read all bookings" on public.bookings;
create policy "trip admins read all bookings" on public.bookings for select to authenticated using ((select public.is_trip_admin()));
