alter table public.bookings add column if not exists ticket_number bigint, add column if not exists ticket_token uuid;
create sequence if not exists public.trip_ticket_number_seq start with 100000 increment by 1;
create unique index if not exists bookings_ticket_number_uidx on public.bookings(ticket_number) where ticket_number is not null;
create unique index if not exists bookings_ticket_token_uidx on public.bookings(ticket_token) where ticket_token is not null;
alter table public.payments add column if not exists booking_group_id uuid;
alter table public.payments alter column booking_id drop not null;
alter table public.payments drop constraint if exists payments_booking_id_key;
alter table public.payments drop constraint if exists payments_booking_or_group_check;
alter table public.payments add constraint payments_booking_or_group_check check ((booking_id is not null and booking_group_id is null) or (booking_id is null and booking_group_id is not null));
create unique index if not exists payments_booking_group_uidx on public.payments(booking_group_id) where booking_group_id is not null;
drop policy if exists "payments read own" on public.payments;
create policy "payments read own" on public.payments for select to authenticated using (
 (select public.is_trip_admin()) or exists(select 1 from public.bookings b where b.passenger_id=(select auth.uid()) and
 (b.id=payments.booking_id or (payments.booking_group_id is not null and b.booking_group_id=payments.booking_group_id)))
);
revoke all on public.payments from anon;
revoke insert,update,delete on public.payments from authenticated;
grant select on public.payments to authenticated;
create or replace function public.ensure_paid_booking_conversations(p_booking_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_passenger_id uuid; v_operator_id uuid; v_owner_id uuid; v_driver_id uuid;
begin
 select b.passenger_id,t.operator_id,o.owner_id,t.driver_id into v_passenger_id,v_operator_id,v_owner_id,v_driver_id
 from public.bookings b join public.trips t on t.id=b.trip_id join public.operators o on o.id=t.operator_id
 where b.id=p_booking_id and b.status='confirmed' and o.verified=true
 and exists(select 1 from public.payments p where p.status='succeeded' and (p.booking_id=b.id or (p.booking_group_id is not null and p.booking_group_id=b.booking_group_id)));
 if v_passenger_id is null or v_operator_id is null or v_owner_id is null then return; end if;
 insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id) values('booking_operator',p_booking_id,v_passenger_id,v_operator_id,v_owner_id) on conflict (booking_id) where kind='booking_operator' do nothing;
 if v_driver_id is not null and exists(select 1 from public.operator_drivers od where od.operator_id=v_operator_id and od.driver_id=v_driver_id) then
  insert into public.conversations(kind,booking_id,passenger_id,operator_id,operator_user_id,driver_user_id) values('booking_driver',p_booking_id,v_passenger_id,v_operator_id,v_owner_id,v_driver_id) on conflict (booking_id,driver_user_id) where kind='booking_driver' do nothing;
 end if;
end;
$$;
revoke all on function public.ensure_paid_booking_conversations(uuid) from public,anon,authenticated;
drop policy if exists "paid booking participants read booking conversations" on public.conversations;
create policy "paid booking participants read booking conversations" on public.conversations for select to authenticated using (
 (select public.is_trip_admin()) or (booking_id is not null and exists(
 select 1 from public.bookings b join public.trips t on t.id=b.trip_id join public.operators o on o.id=t.operator_id
 where b.id=conversations.booking_id and b.status='confirmed'
 and exists(select 1 from public.payments p where p.status='succeeded' and (p.booking_id=b.id or (p.booking_group_id is not null and p.booking_group_id=b.booking_group_id)))
 and (b.passenger_id=(select auth.uid()) or o.owner_id=(select auth.uid()) or conversations.driver_user_id=(select auth.uid()))
 ))
);
create or replace function private.issue_paid_booking_tickets()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if new.status<>'succeeded' then return new; end if;
 for v_id in select b.id from public.bookings b where ((new.booking_id is not null and b.id=new.booking_id) or (new.booking_group_id is not null and b.booking_group_id=new.booking_group_id)) and b.status in ('pending','confirmed') for update
 loop
  update public.bookings set status='confirmed',ticket_number=coalesce(ticket_number,nextval('public.trip_ticket_number_seq')),ticket_token=coalesce(ticket_token,gen_random_uuid()) where id=v_id;
 end loop;
 return new;
end;
$$;
revoke all on function private.issue_paid_booking_tickets() from public,anon,authenticated;
drop trigger if exists zz_issue_paid_booking_tickets on public.payments;
create trigger zz_issue_paid_booking_tickets after insert or update of status on public.payments for each row when (new.status='succeeded') execute function private.issue_paid_booking_tickets();
create or replace function public.verify_trip_ticket(p_ticket_token uuid)
returns table(ticket_number bigint,booking_code text,passenger_name text,origin_city text,destination_city text,departure_at timestamptz,seat_number integer,booking_status text)
language sql stable security invoker set search_path='' as $$
 select b.ticket_number,b.booking_code,b.passenger_name,t.origin_city,t.destination_city,t.departure_at,b.seat_number,b.status::text
 from public.bookings b join public.trips t on t.id=b.trip_id join public.operators o on o.id=t.operator_id
 where b.ticket_token=p_ticket_token and b.status='confirmed'
 and exists(select 1 from public.payments p where p.status='succeeded' and (p.booking_id=b.id or (p.booking_group_id is not null and p.booking_group_id=b.booking_group_id)))
 and ((select public.is_trip_admin()) or o.owner_id=(select auth.uid()));
$$;
revoke all on function public.verify_trip_ticket(uuid) from public,anon;
grant execute on function public.verify_trip_ticket(uuid) to authenticated;
