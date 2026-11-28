create table if not exists public.trip_payment_submissions (
  id uuid primary key default gen_random_uuid(),
  booking_group_id uuid not null,
  passenger_id uuid not null references public.profiles(id) on delete cascade,
  passenger_name text not null,
  passenger_phone text not null,
  provider text not null check (provider in ('بنكك','ماي كاشي','براڤو')),
  provider_reference text not null check (char_length(btrim(provider_reference)) between 4 and 100),
  amount_sdg numeric(14,2) not null check (amount_sdg > 0),
  note text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  admin_note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists trip_payment_submissions_group_idx
  on public.trip_payment_submissions(booking_group_id, created_at desc);
create index if not exists trip_payment_submissions_passenger_idx
  on public.trip_payment_submissions(passenger_id, created_at desc);
create unique index if not exists trip_payment_submissions_pending_group_uidx
  on public.trip_payment_submissions(booking_group_id) where status='pending';
create unique index if not exists trip_payment_submissions_provider_reference_uidx
  on public.trip_payment_submissions(provider, provider_reference);

alter table public.trip_payment_submissions enable row level security;
drop policy if exists "passengers and admins read payment submissions" on public.trip_payment_submissions;
create policy "passengers and admins read payment submissions"
on public.trip_payment_submissions for select to authenticated
using (passenger_id = (select auth.uid()) or (select public.is_trip_admin()));
revoke all on public.trip_payment_submissions from anon, authenticated;
grant select on public.trip_payment_submissions to authenticated;

create or replace function public.submit_trip_payment_proof(
  p_booking_group_id uuid,
  p_provider text,
  p_provider_reference text,
  p_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_amount numeric(14,2);
  v_name text;
  v_phone text;
  v_submission_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if p_provider not in ('بنكك','ماي كاشي','براڤو') then raise exception 'Unsupported payment provider'; end if;
  if char_length(btrim(coalesce(p_provider_reference,''))) < 4
     or char_length(btrim(coalesce(p_provider_reference,''))) > 100 then
    raise exception 'Enter a valid transfer reference';
  end if;
  if char_length(coalesce(p_note,'')) > 500 then raise exception 'Payment note is too long'; end if;

  select sum(b.amount_sdg)::numeric(14,2),
         min(b.passenger_name),
         min(b.passenger_phone)
    into v_amount, v_name, v_phone
  from public.bookings b
  where b.booking_group_id = p_booking_group_id
    and b.passenger_id = v_user_id
    and b.status = 'pending';

  if coalesce(v_amount,0) <= 0 then
    raise exception 'No pending bookings found for this passenger';
  end if;
  if exists (
    select 1 from public.payments p
    where p.booking_group_id = p_booking_group_id and p.status = 'succeeded'
  ) then raise exception 'This booking has already been paid'; end if;
  if exists (
    select 1 from public.trip_payment_submissions s
    where s.booking_group_id = p_booking_group_id and s.status = 'pending'
  ) then raise exception 'A payment proof is already awaiting review'; end if;

  insert into public.trip_payment_submissions(
    booking_group_id, passenger_id, passenger_name, passenger_phone,
    provider, provider_reference, amount_sdg, note
  ) values (
    p_booking_group_id, v_user_id, coalesce(v_name,''), coalesce(v_phone,''),
    p_provider, btrim(p_provider_reference), v_amount, btrim(coalesce(p_note,''))
  ) returning id into v_submission_id;

  return v_submission_id;
end;
$$;

revoke all on function public.submit_trip_payment_proof(uuid,text,text,text) from public, anon;
grant execute on function public.submit_trip_payment_proof(uuid,text,text,text) to authenticated;

create or replace function public.review_trip_payment_submission(
  p_submission_id uuid,
  p_approved boolean,
  p_admin_note text default ''
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_submission public.trip_payment_submissions%rowtype;
  v_total numeric(14,2);
  v_count integer;
  v_admin_id uuid := auth.uid();
begin
  if v_admin_id is null or not public.is_trip_admin() then
    raise exception 'Administrator access required';
  end if;
  if char_length(coalesce(p_admin_note,'')) > 500 then
    raise exception 'Admin note is too long';
  end if;

  select * into v_submission
  from public.trip_payment_submissions
  where id = p_submission_id
  for update;

  if not found then raise exception 'Payment submission not found'; end if;
  if v_submission.status <> 'pending' then raise exception 'This submission has already been reviewed'; end if;

  if p_approved then
    select count(*), coalesce(sum(b.amount_sdg),0)::numeric(14,2)
      into v_count, v_total
    from public.bookings b
    where b.booking_group_id = v_submission.booking_group_id
      and b.passenger_id = v_submission.passenger_id
      and b.status = 'pending';

    if v_count = 0 or v_total <> v_submission.amount_sdg then
      raise exception 'Booking amount or status no longer matches this payment proof';
    end if;
    if exists (
      select 1 from public.payments p
      where p.booking_group_id = v_submission.booking_group_id and p.status = 'succeeded'
    ) then raise exception 'A successful payment already exists'; end if;

    insert into public.payments(
      booking_group_id, provider, provider_reference, amount_sdg, currency, status
    ) values (
      v_submission.booking_group_id, v_submission.provider,
      v_submission.provider_reference, v_submission.amount_sdg, 'SDG', 'succeeded'
    );

    update public.trip_payment_submissions
    set status='approved', reviewed_by=v_admin_id, reviewed_at=now(),
        admin_note=btrim(coalesce(p_admin_note,''))
    where id=p_submission_id;
    return 'approved';
  else
    update public.trip_payment_submissions
    set status='rejected', reviewed_by=v_admin_id, reviewed_at=now(),
        admin_note=btrim(coalesce(p_admin_note,''))
    where id=p_submission_id;
    return 'rejected';
  end if;
end;
$$;

revoke all on function public.review_trip_payment_submission(uuid,boolean,text) from public, anon;
grant execute on function public.review_trip_payment_submission(uuid,boolean,text) to authenticated;

create index if not exists idx_operators_owner_id_fk on public.operators(owner_id);
create index if not exists idx_operator_members_user_id_fk on public.operator_members(user_id);
create index if not exists idx_buses_operator_id_fk on public.buses(operator_id);
create index if not exists idx_trips_bus_id_fk on public.trips(bus_id);
create index if not exists idx_trips_operator_id_fk on public.trips(operator_id);
create index if not exists idx_bookings_passenger_id_fk on public.bookings(passenger_id);
create index if not exists idx_payments_booking_id_fk on public.payments(booking_id);
create index if not exists idx_parcels_sender_id_fk on public.parcels(sender_id);
create index if not exists idx_operator_drivers_driver_id_fk on public.operator_drivers(driver_id);
create index if not exists idx_conversations_driver_user_id_fk on public.conversations(driver_user_id);
create index if not exists idx_conversations_operator_id_fk on public.conversations(operator_id);
create index if not exists idx_messages_sender_id_fk on public.messages(sender_id);
create index if not exists idx_operator_subscriptions_reviewed_by_fk on public.operator_subscriptions(reviewed_by);
create index if not exists idx_operator_drivers_details_user_id_fk on public.operator_drivers_details(user_id);
create index if not exists idx_driver_trip_locations_driver_id_fk on public.driver_trip_locations(driver_id);
create index if not exists idx_conversation_call_signals_sender_id_fk on public.conversation_call_signals(sender_id);
