alter table public.trips
  add column if not exists driver_id uuid references public.profiles(id) on delete set null;

create index if not exists trips_driver_id_idx on public.trips(driver_id);

drop policy if exists "paid booking participants read booking conversations" on public.conversations;
create policy "paid booking participants read booking conversations"
on public.conversations for select to authenticated
using (
  (select public.is_trip_admin())
  or (
    booking_id is not null
    and exists (
      select 1
      from public.bookings b
      join public.trips t on t.id=b.trip_id
      join public.operators o on o.id=t.operator_id
      join public.payments p on p.booking_id=b.id
      where b.id=conversations.booking_id
        and b.status='confirmed'
        and p.status='succeeded'
        and (
          b.passenger_id=(select auth.uid())
          or o.owner_id=(select auth.uid())
          or conversations.driver_user_id=(select auth.uid())
        )
    )
  )
);

create or replace function public.ensure_paid_booking_conversations(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_passenger_id uuid;
  v_trip_id uuid;
  v_operator_id uuid;
  v_owner_id uuid;
  v_driver_id uuid;
begin
  select b.passenger_id, b.trip_id, t.operator_id, o.owner_id, t.driver_id
    into v_passenger_id, v_trip_id, v_operator_id, v_owner_id, v_driver_id
  from public.bookings b
  join public.trips t on t.id=b.trip_id
  join public.operators o on o.id=t.operator_id
  where b.id=p_booking_id
    and b.status='confirmed'
    and o.verified=true
    and exists(select 1 from public.payments p where p.booking_id=b.id and p.status='succeeded');

  if v_passenger_id is null or v_operator_id is null or v_owner_id is null then
    return;
  end if;

  insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id)
  values('booking_operator',p_booking_id,v_passenger_id,v_operator_id,v_owner_id)
  on conflict (booking_id) where kind='booking_operator' do nothing;

  if v_driver_id is not null and exists (
    select 1 from public.operator_drivers od
    where od.operator_id=v_operator_id and od.driver_id=v_driver_id
  ) then
    insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id,driver_user_id)
    values('booking_driver',p_booking_id,v_passenger_id,v_operator_id,v_owner_id,v_driver_id)
    on conflict (booking_id,driver_user_id) where kind='booking_driver' do nothing;
  end if;
end;
$$;

revoke all on function public.ensure_paid_booking_conversations(uuid) from public, anon, authenticated;

create or replace function public.on_booking_or_payment_change_create_conversations()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_booking_id uuid;
begin
  if tg_table_name='bookings' then
    v_booking_id := new.id;
  else
    v_booking_id := new.booking_id;
  end if;
  if v_booking_id is not null then
    perform public.ensure_paid_booking_conversations(v_booking_id);
  end if;
  return new;
end;
$$;
revoke all on function public.on_booking_or_payment_change_create_conversations() from public, anon, authenticated;

drop trigger if exists create_paid_booking_conversations_after_confirm on public.bookings;
create trigger create_paid_booking_conversations_after_confirm
after insert or update of status on public.bookings
for each row execute function public.on_booking_or_payment_change_create_conversations();

drop trigger if exists create_paid_booking_conversations_after_payment on public.payments;
create trigger create_paid_booking_conversations_after_payment
after insert or update of status on public.payments
for each row when (new.status='succeeded')
execute function public.on_booking_or_payment_change_create_conversations();

do $$
declare r record;
begin
  for r in
    select b.id
    from public.bookings b
    where b.status='confirmed'
      and exists(select 1 from public.payments p where p.booking_id=b.id and p.status='succeeded')
  loop
    perform public.ensure_paid_booking_conversations(r.id);
  end loop;
end $$;