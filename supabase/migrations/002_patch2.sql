-- =====================================================================
-- AVAZ · patch 2
-- company accounts · whole buildings · bulk & long bookings · AI usage limit
-- Safe to run more than once.
-- =====================================================================

-- ---------- company accounts ----------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('worker','host','company'));
alter table public.profiles add column if not exists cr text;
alter table public.profiles add column if not exists workforce int;
alter table public.profiles drop constraint if exists profiles_cr_check;
alter table public.profiles add constraint profiles_cr_check check (cr is null or cr ~ '^[0-9]{10}$');
alter table public.profiles drop constraint if exists profiles_workforce_check;
alter table public.profiles add constraint profiles_workforce_check check (workforce is null or workforce between 1 and 100000);

-- ---------- whole buildings & capacity ----------
-- capacity = how many workers one unit houses (for a whole building: the whole building)
alter table public.listings drop constraint if exists listings_type_check;
alter table public.listings add constraint listings_type_check check (type in ('bed','room','studio','apt','compound','building'));
alter table public.listings add column if not exists capacity int;
alter table public.listings add column if not exists apartments int;
alter table public.listings drop constraint if exists listings_capacity_check;
alter table public.listings add constraint listings_capacity_check check (capacity is null or capacity between 1 and 10000);
alter table public.listings drop constraint if exists listings_apartments_check;
alter table public.listings add constraint listings_apartments_check check (apartments is null or apartments between 1 and 1000);
alter table public.listings drop constraint if exists listings_price_check;
alter table public.listings add constraint listings_price_check check (price > 0 and price < 10000000);

-- ---------- bulk and long-term bookings ----------
alter table public.bookings drop constraint if exists bookings_units_check;
alter table public.bookings add constraint bookings_units_check check (units between 1 and 2000);
alter table public.bookings drop constraint if exists bookings_months_check;
alter table public.bookings add constraint bookings_months_check check (months between 1 and 60);

-- ---------- search log: who searched and for how many ----------
alter table public.searches add column if not exists who text;
alter table public.searches add column if not exists workers int;
alter table public.searches drop constraint if exists searches_who_check;
alter table public.searches add constraint searches_who_check check (who is null or who in ('worker','company'));

-- ---------- bookings: workers and companies can request ----------
create or replace function public.bookings_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.listings; g text; r text;
begin
  select * into l from public.listings where id = new.listing;
  if not found or l.archived then raise exception 'listing_unavailable'; end if;
  select gender, role into g, r from public.profiles where id = new.worker;
  if r is null or r not in ('worker','company') then raise exception 'tenants_only'; end if;
  if (l.gender = 'men' and g = 'f') or (l.gender = 'women' and g is distinct from 'f') then
    raise exception 'gender_mismatch';
  end if;
  if new.units > l.free then raise exception 'not_enough_units'; end if;
  if exists (select 1 from public.bookings
             where listing = new.listing and worker = new.worker and status in ('pending','confirmed')) then
    raise exception 'duplicate_request';
  end if;
  new.host := l.host;
  new.status := 'pending';
  new.created_at := now();
  new.ended_at := null;
  return new;
end $$;

-- ---------- smart features: daily limit per user ----------
create table if not exists public.ai_usage (
  user_id  uuid not null references auth.users(id) on delete cascade,
  day      date not null default current_date,
  n        int  not null default 0,
  primary key (user_id, day)
);
alter table public.ai_usage enable row level security;   -- no policies: only ai_take() touches it

create or replace function public.ai_take() returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cnt int;
begin
  if uid is null then return false; end if;
  insert into public.ai_usage (user_id, day, n) values (uid, current_date, 1)
  on conflict (user_id, day) do update set n = public.ai_usage.n + 1
  returning n into cnt;
  return cnt <= 40;
end $$;
revoke all on function public.ai_take() from public, anon;
grant execute on function public.ai_take() to authenticated;
