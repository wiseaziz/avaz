-- =====================================================================
-- AVAZ · hardening after the Supabase security advisor
-- Safe to run more than once.
-- =====================================================================

-- public counts: a function only signed-in users can call (replaces the view)
drop view if exists public.user_stats;
create or replace function public.user_stats_list()
returns table (user_id uuid, stays int, requests int, answered int)
language sql stable security definer set search_path = public as $$
  select p.id,
    (select count(*) from public.bookings b where b.worker = p.id and b.status = 'completed')::int,
    (select count(*) from public.bookings b where b.host = p.id and b.status <> 'cancelled')::int,
    (select count(*) from public.bookings b where b.host = p.id and b.status in ('confirmed','completed','declined'))::int
  from public.profiles p
  where auth.uid() is not null;
$$;
revoke all on function public.user_stats_list() from public, anon;
grant execute on function public.user_stats_list() to authenticated;

-- trigger functions are only meant to run as triggers, never through the API
revoke execute on function public.bookings_before_insert() from public, anon, authenticated;
revoke execute on function public.bookings_before_update() from public, anon, authenticated;
revoke execute on function public.reviews_before_insert()  from public, anon, authenticated;
revoke execute on function public.reviews_after_insert()   from public, anon, authenticated;
revoke execute on function public.profiles_guard()         from public, anon, authenticated;
revoke execute on function public.listings_guard()         from public, anon, authenticated;
