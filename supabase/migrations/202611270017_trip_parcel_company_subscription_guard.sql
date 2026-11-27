drop policy if exists "parcels company reads assigned" on public.parcels;
create policy "parcels company reads assigned" on public.parcels for select to authenticated using (
 (select public.is_trip_admin())
 or exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()) and o.verified=true and private.operator_has_active_subscription(o.id))
);
drop policy if exists "parcels company updates assigned" on public.parcels;
create policy "parcels company updates assigned" on public.parcels for update to authenticated
using ((select public.is_trip_admin()) or exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()) and o.verified=true and private.operator_has_active_subscription(o.id)))
with check ((select public.is_trip_admin()) or exists(select 1 from public.operators o where o.id=parcels.operator_id and o.owner_id=(select auth.uid()) and o.verified=true and private.operator_has_active_subscription(o.id)));
