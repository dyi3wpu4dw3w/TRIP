create or replace function private.link_approved_driver_profile()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
 if new.requested_role <> 'driver' or new.registration_status <> 'active' or nullif(trim(coalesce(new.phone,'')),'') is null then
  return new;
 end if;
 update public.operator_drivers_details d
 set user_id=new.id,status='active'
 from public.operators o
 where d.operator_id=o.id and o.verified=true and d.user_id is null
 and regexp_replace(d.phone,'[^0-9]','','g')=regexp_replace(new.phone,'[^0-9]','','g')
 and private.operator_has_active_subscription(o.id);
 insert into public.operator_drivers(operator_id,driver_id)
 select d.operator_id,new.id from public.operator_drivers_details d
 join public.operators o on o.id=d.operator_id
 where d.user_id=new.id and o.verified=true
 on conflict do nothing;
 return new;
end;
$$;
revoke all on function private.link_approved_driver_profile() from public,anon,authenticated;
drop trigger if exists link_approved_driver_profile on public.profiles;
create trigger link_approved_driver_profile
after insert or update of phone,requested_role,registration_status on public.profiles
for each row execute function private.link_approved_driver_profile();
