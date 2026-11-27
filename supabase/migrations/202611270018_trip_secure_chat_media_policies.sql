drop policy if exists "trip chat participants upload media" on storage.objects;
create policy "trip chat participants upload media" on storage.objects for insert to authenticated with check (
 bucket_id='trip-chat-media' and exists(select 1 from public.conversations c where c.id::text=split_part(name,'/',1)
 and (c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid())))
);
drop policy if exists "trip chat participants read media" on storage.objects;
create policy "trip chat participants read media" on storage.objects for select to authenticated using (
 bucket_id='trip-chat-media' and exists(select 1 from public.conversations c where c.id::text=split_part(name,'/',1)
 and (c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid())))
);
