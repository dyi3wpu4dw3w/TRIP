create table if not exists public.operator_drivers (
  operator_id uuid not null references public.operators(id) on delete cascade,
  driver_id uuid not null references public.profiles(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  primary key(operator_id,driver_id)
);
alter table public.operator_drivers enable row level security;
create or replace function public.is_trip_admin() returns boolean language sql stable set search_path = '' as $$ select coalesce((auth.jwt()->'app_metadata'->>'role') = 'admin', false); $$;
revoke all on function public.is_trip_admin() from public, anon;
grant execute on function public.is_trip_admin() to authenticated;
create policy "operator drivers visible to related parties" on public.operator_drivers for select to authenticated using (driver_id=(select auth.uid()) or exists(select 1 from public.operators o where o.id=operator_drivers.operator_id and o.owner_id=(select auth.uid())) or (select public.is_trip_admin()));
create policy "operator owner assigns drivers" on public.operator_drivers for insert to authenticated with check (exists(select 1 from public.operators o where o.id=operator_drivers.operator_id and o.owner_id=(select auth.uid()) and o.verified=true) or (select public.is_trip_admin()));
create policy "operator owner removes drivers" on public.operator_drivers for delete to authenticated using (exists(select 1 from public.operators o where o.id=operator_drivers.operator_id and o.owner_id=(select auth.uid())) or (select public.is_trip_admin()));
grant select,insert,delete on public.operator_drivers to authenticated;
create table if not exists public.conversations (
 id uuid primary key default gen_random_uuid(),
 kind text not null check(kind in ('support','operator_driver')),
 passenger_id uuid references public.profiles(id) on delete cascade,
 operator_id uuid references public.operators(id) on delete cascade,
 operator_user_id uuid references public.profiles(id) on delete cascade,
 driver_user_id uuid references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now(),
 check ((kind='support' and passenger_id is not null and operator_id is null and operator_user_id is null and driver_user_id is null) or (kind='operator_driver' and passenger_id is null and operator_id is not null and operator_user_id is not null and driver_user_id is not null and operator_user_id <> driver_user_id))
);
create index if not exists conversations_passenger_idx on public.conversations(passenger_id,created_at desc);
create index if not exists conversations_operator_driver_idx on public.conversations(operator_user_id,driver_user_id,created_at desc);
create table if not exists public.messages (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.conversations(id) on delete cascade,
 sender_id uuid not null references public.profiles(id) on delete cascade,
 message_type text not null default 'text' check(message_type in ('text','voice','image')),
 body text,
 storage_path text,
 created_at timestamptz not null default now(),
 read_at timestamptz,
 check ((message_type='text' and nullif(trim(coalesce(body,'')),'') is not null and storage_path is null) or (message_type in ('voice','image') and storage_path is not null))
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at);
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
create policy "conversation participants and admins read" on public.conversations for select to authenticated using ((select public.is_trip_admin()) or passenger_id=(select auth.uid()) or operator_user_id=(select auth.uid()) or driver_user_id=(select auth.uid()));
create policy "passengers open support conversations" on public.conversations for insert to authenticated with check (kind='support' and passenger_id=(select auth.uid()) and operator_id is null and operator_user_id is null and driver_user_id is null and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.requested_role='passenger'));
create policy "related company and driver open direct conversations" on public.conversations for insert to authenticated with check (kind='operator_driver' and exists(select 1 from public.operator_drivers od join public.operators o on o.id=od.operator_id where od.operator_id=conversations.operator_id and od.driver_id=conversations.driver_user_id and o.owner_id=conversations.operator_user_id and ((select auth.uid())=conversations.operator_user_id or (select auth.uid())=conversations.driver_user_id)));
create policy "conversation participants read messages" on public.messages for select to authenticated using (exists(select 1 from public.conversations c where c.id=messages.conversation_id and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid()))));
create policy "participants send messages" on public.messages for insert to authenticated with check (sender_id=(select auth.uid()) and exists(select 1 from public.conversations c where c.id=messages.conversation_id and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid()))));
create policy "participants mark messages read" on public.messages for update to authenticated using (exists(select 1 from public.conversations c where c.id=messages.conversation_id and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid())))) with check (exists(select 1 from public.conversations c where c.id=messages.conversation_id and ((select public.is_trip_admin()) or c.passenger_id=(select auth.uid()) or c.operator_user_id=(select auth.uid()) or c.driver_user_id=(select auth.uid()))));
grant select,insert on public.conversations to authenticated;
grant select,insert on public.messages to authenticated;
grant update(read_at) on public.messages to authenticated;
