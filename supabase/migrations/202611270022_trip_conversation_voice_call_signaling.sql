create table if not exists public.conversation_call_signals (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  call_id uuid not null,
  signal_type text not null check (signal_type in ('offer','answer','ice','hangup','reject')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists conversation_call_signals_lookup_idx
  on public.conversation_call_signals(conversation_id, created_at desc);
alter table public.conversation_call_signals enable row level security;
drop policy if exists "call participants read signaling" on public.conversation_call_signals;
create policy "call participants read signaling"
on public.conversation_call_signals for select to authenticated
using (exists (
  select 1 from public.conversations c
  where c.id = conversation_id
    and (c.passenger_id = (select auth.uid())
      or c.operator_user_id = (select auth.uid())
      or c.driver_user_id = (select auth.uid())
      or (select public.is_trip_admin()))
));
drop policy if exists "call participants send signaling" on public.conversation_call_signals;
create policy "call participants send signaling"
on public.conversation_call_signals for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and exists (
    select 1 from public.conversations c
    where c.id = conversation_id
      and (c.passenger_id = (select auth.uid())
        or c.operator_user_id = (select auth.uid())
        or c.driver_user_id = (select auth.uid())
        or (select public.is_trip_admin()))
  )
);
grant select, insert on public.conversation_call_signals to authenticated;
alter publication supabase_realtime add table public.conversation_call_signals;
