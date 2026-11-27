revoke update on public.parcels from authenticated;
grant update(status,price_sdg,updated_at,operator_id) on public.parcels to authenticated;
