create policy "admins manage operators" on public.operators for all to authenticated using ((select public.is_trip_admin())) with check ((select public.is_trip_admin()));
