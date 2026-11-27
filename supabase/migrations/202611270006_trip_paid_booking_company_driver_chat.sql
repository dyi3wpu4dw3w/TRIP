alter table public.conversations
  add column if not exists booking_id uuid references public.bookings(id) on delete cascade;

alter table public.conversations drop constraint if exists conversations_kind_check;
alter table public.conversations
  add constraint conversations_kind_check
  check (kind in ('support','operator_driver','booking_operator','booking_driver'));

alter table public.conversations drop constraint if exists conversations_check;
alter table public.conversations
  add constraint conversations_booking_shape_check check (
    (kind='support' and booking_id is null and passenger_id is not null and operator_id is null and operator_user_id is null and driver_user_id is null)
    or
    (kind='operator_driver' and booking_id is null and passenger_id is null and operator_id is not null and operator_user_id is not null and driver_user_id is not null and operator_user_id <> driver_user_id)
    or
    (kind='booking_operator' and booking_id is not null and passenger_id is not null and operator_id is not null and operator_user_id is not null and driver_user_id is null)
    or
    (kind='booking_driver' and booking_id is not null and passenger_id is not null and operator_id is not null and operator_user_id is not null and driver_user_id is not null)
  );

create index if not exists conversations_booking_idx on public.conversations(booking_id, created_at desc);
create unique index if not exists conversations_one_booking_operator
  on public.conversations(booking_id) where kind='booking_operator';
create unique index if not exists conversations_one_booking_driver
  on public.conversations(booking_id, driver_user_id) where kind='booking_driver';

create policy "paid booking participants read booking conversations"
on public.conversations for select to authenticated
using (
  (select public.is_trip_admin())
  or (
    booking_id is not null
    and exists (
      select 1 from public.bookings b
      join public.trips t on t.id=b.trip_id
      join public.operators o on o.id=t.operator_id
      where b.id=conversations.booking_id
        and b.status='confirmed'
        and (
          b.passenger_id=(select auth.uid())
          or o.owner_id=(select auth.uid())
          or conversations.driver_user_id=(select auth.uid())
        )
    )
  )
);

create or replace function public.create_paid_booking_conversations()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_operator_id uuid; v_owner_id uuid;
begin
  if new.status <> 'confirmed' then return new; end if;
  if not exists (select 1 from public.payments p where p.booking_id=new.id and p.status='succeeded') then return new; end if;
  select t.operator_id, o.owner_id into v_operator_id, v_owner_id
  from public.trips t join public.operators o on o.id=t.operator_id
  where t.id=new.trip_id and o.verified=true;
  if v_operator_id is null or v_owner_id is null then return new; end if;
  if not exists (select 1 from public.conversations c where c.booking_id=new.id and c.kind='booking_operator') then
    insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id)
    values('booking_operator',new.id,new.passenger_id,v_operator_id,v_owner_id);
  end if;
  insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id,driver_user_id)
  select 'booking_driver',new.id,new.passenger_id,v_operator_id,v_owner_id,od.driver_id
  from public.operator_drivers od
  where od.operator_id=v_operator_id and not exists (
    select 1 from public.conversations c where c.booking_id=new.id and c.kind='booking_driver' and c.driver_user_id=od.driver_id
  );
  return new;
end;
$$;
revoke all on function public.create_paid_booking_conversations() from public, anon, authenticated;
drop trigger if exists create_paid_booking_conversations_after_confirm on public.bookings;
create trigger create_paid_booking_conversations_after_confirm
after insert or update of status on public.bookings
for each row when (new.status='confirmed')
execute function public.create_paid_booking_conversations();