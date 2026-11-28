
create or replace function private.submit_trip_payment_proof(
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

create or replace function private.review_trip_payment_submission(
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
  select * into v_submission from public.trip_payment_submissions where id=p_submission_id for update;
  if not found then raise exception 'Payment submission not found'; end if;
  if v_submission.status<>'pending' then raise exception 'This submission has already been reviewed'; end if;
  if p_approved then
    select count(*),coalesce(sum(b.amount_sdg),0)::numeric(14,2) into v_count,v_total
    from public.bookings b where b.booking_group_id=v_submission.booking_group_id
      and b.passenger_id=v_submission.passenger_id and b.status='pending';
    if v_count=0 or v_total<>v_submission.amount_sdg then
      raise exception 'Booking amount or status no longer matches this payment proof';
    end if;
    if exists(select 1 from public.payments p where p.booking_group_id=v_submission.booking_group_id and p.status='succeeded') then
      raise exception 'A successful payment already exists';
    end if;
    insert into public.payments(booking_group_id,provider,provider_reference,amount_sdg,currency,status)
    values(v_submission.booking_group_id,v_submission.provider,v_submission.provider_reference,v_submission.amount_sdg,'SDG','succeeded');
    update public.trip_payment_submissions set status='approved',reviewed_by=v_admin_id,reviewed_at=now(),
      admin_note=btrim(coalesce(p_admin_note,'')) where id=p_submission_id;
    return 'approved';
  else
    update public.trip_payment_submissions set status='rejected',reviewed_by=v_admin_id,reviewed_at=now(),
      admin_note=btrim(coalesce(p_admin_note,'')) where id=p_submission_id;
    return 'rejected';
  end if;
end;
$$;

revoke all on function private.submit_trip_payment_proof(uuid,text,text,text) from public, anon, authenticated;
revoke all on function private.review_trip_payment_submission(uuid,boolean,text) from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.submit_trip_payment_proof(uuid,text,text,text) to authenticated;
grant execute on function private.review_trip_payment_submission(uuid,boolean,text) to authenticated;

create or replace function public.submit_trip_payment_proof(
  p_booking_group_id uuid,p_provider text,p_provider_reference text,p_note text default ''
)
returns uuid language sql security invoker set search_path = ''
as $$ select private.submit_trip_payment_proof($1,$2,$3,$4); $$;

create or replace function public.review_trip_payment_submission(
  p_submission_id uuid,p_approved boolean,p_admin_note text default ''
)
returns text language sql security invoker set search_path = ''
as $$ select private.review_trip_payment_submission($1,$2,$3); $$;

revoke all on function public.submit_trip_payment_proof(uuid,text,text,text) from public, anon;
revoke all on function public.review_trip_payment_submission(uuid,boolean,text) from public, anon;
grant execute on function public.submit_trip_payment_proof(uuid,text,text,text) to authenticated;
grant execute on function public.review_trip_payment_submission(uuid,boolean,text) to authenticated;
