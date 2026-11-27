alter table public.profiles
  add column if not exists residence text not null default '',
  add column if not exists requested_role text not null default 'passenger'
    check (requested_role in ('passenger','operator','driver')),
  add column if not exists registration_status text not null default 'active'
    check (registration_status in ('active','pending_review'));

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
begin
  v_role := coalesce(new.raw_user_meta_data->>'requested_role','passenger');
  if v_role not in ('passenger','operator','driver') then
    v_role := 'passenger';
  end if;

  insert into public.profiles(id,full_name,phone,residence,requested_role,registration_status)
  values(
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',''),
    nullif(trim(coalesce(new.raw_user_meta_data->>'phone','')),''),
    coalesce(new.raw_user_meta_data->>'residence',''),
    v_role,
    case when v_role='passenger' then 'active' else 'pending_review' end
  );
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke update on public.profiles from authenticated;
grant update(full_name,phone,residence) on public.profiles to authenticated;
