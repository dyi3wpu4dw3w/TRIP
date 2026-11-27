create or replace function private.sync_company_drivers(p_operator_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not exists(select 1 from public.operators o where o.id=p_operator_id and o.verified=true)
    or not private.operator_has_active_subscription(p_operator_id) then return; end if;
 update public.operator_drivers_details d set user_id=p.id,status='active'
 from public.profiles p where d.operator_id=p_operator_id and d.user_id is null
 and p.requested_role='driver' and p.registration_status='active'
 and regexp_replace(d.phone,'[^0-9]','','g')=regexp_replace(p.phone,'[^0-9]','','g');
 insert into public.operator_drivers(operator_id,driver_id)
 select p_operator_id,d.user_id from public.operator_drivers_details d
 where d.operator_id=p_operator_id and d.user_id is not null on conflict do nothing;
end;
$$;
revoke all on function private.sync_company_drivers(uuid) from public,anon,authenticated;

create or replace function private.link_approved_driver_profile()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_operator uuid;
begin
 if new.requested_role='driver' and new.registration_status='active' and nullif(trim(coalesce(new.phone,'')),'') is not null then
  for v_operator in select distinct d.operator_id from public.operator_drivers_details d
   where regexp_replace(d.phone,'[^0-9]','','g')=regexp_replace(new.phone,'[^0-9]','','g')
  loop perform private.sync_company_drivers(v_operator); end loop;
 end if;
 return new;
end;
$$;
revoke all on function private.link_approved_driver_profile() from public,anon,authenticated;

create or replace function private.sync_drivers_after_company_change()
returns trigger language plpgsql security definer set search_path=''
as $$
begin perform private.sync_company_drivers(new.id); return new; end;
$$;
revoke all on function private.sync_drivers_after_company_change() from public,anon,authenticated;
drop trigger if exists sync_company_drivers_after_verification on public.operators;
create trigger sync_company_drivers_after_verification after update of verified on public.operators
for each row when (new.verified=true) execute function private.sync_drivers_after_company_change();

create or replace function private.sync_drivers_after_subscription_change()
returns trigger language plpgsql security definer set search_path=''
as $$
begin perform private.sync_company_drivers(new.operator_id); return new; end;
$$;
revoke all on function private.sync_drivers_after_subscription_change() from public,anon,authenticated;
drop trigger if exists sync_company_drivers_after_subscription on public.operator_subscriptions;
create trigger sync_company_drivers_after_subscription after insert or update of status,ends_at on public.operator_subscriptions
for each row when (new.status='active') execute function private.sync_drivers_after_subscription_change();

drop trigger if exists link_approved_driver_profile on public.profiles;
create trigger link_approved_driver_profile after insert or update of phone,requested_role,registration_status
on public.profiles for each row execute function private.link_approved_driver_profile();
