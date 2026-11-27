insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trip-chat-media','trip-chat-media',false,15728640,array['audio/webm','audio/ogg','audio/mp4','audio/mpeg','image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=15728640, allowed_mime_types=excluded.allowed_mime_types;

create policy "chat participants upload media"
on storage.objects for insert to authenticated
with check (
 bucket_id='trip-chat-media'
 and exists (
  select 1 from public.conversations c
  where c.id::text = (storage.foldername(name))[1]
    and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid()))
 )
);

create policy "chat participants read media"
on storage.objects for select to authenticated
using (
 bucket_id='trip-chat-media'
 and exists (
  select 1 from public.conversations c
  where c.id::text = (storage.foldername(name))[1]
    and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid()))
 )
);

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;
