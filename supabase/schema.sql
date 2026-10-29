-- =====================================================================
-- AVAZ · database schema for Supabase
-- Paste this whole file into: Supabase → SQL Editor → New query → Run
-- It can be run again safely; it only creates what is missing.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null check (role in ('worker','host')),
  name        text not null check (char_length(name) between 1 and 80),
  nat         text,
  job         text,
  lang        text,
  gender      text check (gender in ('m','f')),
  av          jsonb,
  city        text,
  prefs       jsonb not null default '{}'::jsonb,
  verified    boolean not null default false,
  created_at  timestamptz not null default now()
);

-- phone numbers are private: visible to the owner, and to the other side of a confirmed stay
create table if not exists public.contacts (
  id     uuid primary key references public.profiles(id) on delete cascade,
  phone  text not null check (char_length(phone) between 6 and 20)
);

create table if not exists public.listings (
  id          uuid primary key default gen_random_uuid(),
  host        uuid not null references public.profiles(id) on delete cascade,
  name        jsonb not null,
  type        text not null check (type in ('bed','room','studio','apt','compound')),
  city        text not null check (city in ('riyadh','jeddah','dammam','jubail')),
  district    text not null check (char_length(district) between 1 and 80),
  near        jsonb not null default '{}'::jsonb,
  gender      text not null check (gender in ('men','women','family')),
  price       int  not null check (price > 0 and price < 100000),
  total       int  not null check (total between 1 and 2000),
  free        int  not null check (free >= 0),
  amen        text[] not null default '{}',
  rules       text[] not null default '{}',
  langs       text[] not null default '{}',
  licensed    boolean not null default false,
  descr       jsonb not null default '{}'::jsonb,
  media       jsonb not null default '[]'::jsonb,
  views       int  not null default 0,
  archived    boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint listings_free_le_total check (free <= total)
);

create table if not exists public.bookings (
  id          uuid primary key default gen_random_uuid(),
  listing     uuid not null references public.listings(id) on delete cascade,
  worker      uuid not null references public.profiles(id) on delete cascade,
  host        uuid not null references public.profiles(id) on delete cascade,
  units       int  not null default 1 check (units between 1 and 50),
  months      int  not null default 1 check (months between 1 and 24),
  move_in     date not null,
  status      text not null default 'pending'
              check (status in ('pending','confirmed','completed','declined','cancelled')),
  created_at  timestamptz not null default now(),
  ended_at    timestamptz
);

create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  booking     uuid not null references public.bookings(id) on delete cascade,
  from_id     uuid not null references public.profiles(id) on delete cascade,
  to_id       uuid not null references public.profiles(id) on delete cascade,
  listing     uuid references public.listings(id) on delete set null,
  kind        text not null check (kind in ('w2h','h2w')),
  sc          jsonb not null,
  overall     numeric(2,1) not null,
  body        text not null,
  body_lang   text,
  revealed    boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint reviews_one_per_side unique (booking, kind)
);

create table if not exists public.saved (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  listing     uuid not null references public.listings(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, listing)
);

-- anonymous search log used for the hosts' demand analysis (no user id stored)
create table if not exists public.searches (
  id          bigint generated always as identity primary key,
  city        text,
  type        text,
  budget      int,
  nat         text,
  amen        text[] not null default '{}',
  created_at  timestamptz not null default now()
);

create index if not exists listings_host_idx   on public.listings (host);
create index if not exists bookings_worker_idx on public.bookings (worker);
create index if not exists bookings_host_idx   on public.bookings (host);
create index if not exists bookings_listing_idx on public.bookings (listing);
create index if not exists reviews_to_idx      on public.reviews (to_id);
create index if not exists reviews_listing_idx on public.reviews (listing);
create index if not exists searches_time_idx   on public.searches (created_at desc);

-- ---------- public counts (no private rows exposed) ----------
create or replace view public.user_stats as
select p.id as user_id,
  (select count(*) from public.bookings b where b.worker = p.id and b.status = 'completed')::int as stays,
  (select count(*) from public.bookings b where b.host = p.id and b.status <> 'cancelled')::int as requests,
  (select count(*) from public.bookings b where b.host = p.id and b.status in ('confirmed','completed','declined'))::int as answered
from public.profiles p;

-- ---------- guard: users cannot change protected profile fields ----------
create or replace function public.profiles_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;          -- dashboard / admin
  if tg_op = 'INSERT' then
    new.verified := false;
    new.created_at := now();
  else
    new.id := old.id;
    new.role := old.role;
    new.verified := old.verified;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- ---------- guard: hosts cannot fake views or move listings ----------
create or replace function public.listings_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated','anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.views := 0;
    new.archived := false;
    new.created_at := now();
  else
    new.host := old.host;
    new.views := old.views;
    new.created_at := old.created_at;
    if old.archived then new.archived := true; end if;
  end if;
  return new;
end $$;
drop trigger if exists listings_guard on public.listings;
create trigger listings_guard before insert or update on public.listings
  for each row execute function public.listings_guard();

-- ---------- bookings: new requests ----------
create or replace function public.bookings_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare l public.listings; g text; r text;
begin
  select * into l from public.listings where id = new.listing;
  if not found or l.archived then raise exception 'listing_unavailable'; end if;
  select gender, role into g, r from public.profiles where id = new.worker;
  if r is distinct from 'worker' then raise exception 'workers_only'; end if;
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
drop trigger if exists bookings_before_insert on public.bookings;
create trigger bookings_before_insert before insert on public.bookings
  for each row execute function public.bookings_before_insert();

-- ---------- bookings: allowed status changes ----------
-- pending → confirmed (host) · pending → declined (host) · pending → cancelled (worker)
-- confirmed → completed (either side; frees the units and opens the 14-day rating window)
create or replace function public.bookings_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return new; end if;                  -- dashboard / admin
  if new.listing <> old.listing or new.worker <> old.worker or new.host <> old.host
     or new.units <> old.units or new.months <> old.months or new.move_in <> old.move_in
     or new.created_at <> old.created_at then
    raise exception 'immutable_fields';
  end if;
  new.ended_at := old.ended_at;
  if new.status = old.status then return new; end if;

  if old.status = 'pending' and new.status = 'confirmed' and uid = old.host then
    update public.listings set free = free - old.units
     where id = old.listing and free >= old.units and not archived;
    if not found then raise exception 'not_enough_units'; end if;
  elsif old.status = 'pending' and new.status = 'declined' and uid = old.host then
    null;
  elsif old.status = 'pending' and new.status = 'cancelled' and uid = old.worker then
    null;
  elsif old.status = 'confirmed' and new.status = 'completed' and uid in (old.worker, old.host) then
    new.ended_at := now();
    update public.listings set free = least(total, free + old.units) where id = old.listing;
  else
    raise exception 'invalid_transition';
  end if;
  return new;
end $$;
drop trigger if exists bookings_before_update on public.bookings;
create trigger bookings_before_update before update on public.bookings
  for each row execute function public.bookings_before_update();

-- ---------- reviews: strict two-way rating ----------
-- only after a completed stay, within 14 days, one per side, five required scores (1–5),
-- overall computed here, a written reason for any score of 2 or less, never editable,
-- hidden from the other side until both have rated (or 14 days pass).
create or replace function public.reviews_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare b public.bookings; keys text[]; k text; v int; total int := 0; low boolean := false; clean jsonb := '{}'::jsonb;
begin
  select * into b from public.bookings where id = new.booking;
  if not found then raise exception 'booking_not_found'; end if;
  if b.status <> 'completed' then raise exception 'stay_not_completed'; end if;
  if b.ended_at < now() - interval '14 days' then raise exception 'rating_window_closed'; end if;
  if new.kind = 'w2h' then
    if new.from_id <> b.worker then raise exception 'not_allowed'; end if;
    new.to_id := b.host;
    keys := array['clean','accuracy','host','safety','value'];
  else
    if new.from_id <> b.host then raise exception 'not_allowed'; end if;
    new.to_id := b.worker;
    keys := array['pay','room','rules','neighbors','property'];
  end if;
  if exists (select 1 from public.reviews where booking = new.booking and kind = new.kind) then
    raise exception 'already_rated';
  end if;
  foreach k in array keys loop
    begin
      v := (new.sc ->> k)::int;
    exception when others then
      raise exception 'invalid_scores';
    end;
    if v is null or v < 1 or v > 5 then raise exception 'invalid_scores'; end if;
    total := total + v;
    if v <= 2 then low := true; end if;
    clean := clean || jsonb_build_object(k, v);
  end loop;
  new.sc := clean;
  new.overall := round(total / 5.0, 1);
  new.body := btrim(coalesce(new.body, ''));
  if char_length(new.body) < 15 then raise exception 'comment_too_short'; end if;
  if (low or new.overall <= 2) and char_length(new.body) < 30 then raise exception 'reason_required'; end if;
  if char_length(new.body) > 2000 then new.body := left(new.body, 2000); end if;
  new.listing := b.listing;
  new.revealed := false;
  new.created_at := now();
  return new;
end $$;
drop trigger if exists reviews_before_insert on public.reviews;
create trigger reviews_before_insert before insert on public.reviews
  for each row execute function public.reviews_before_insert();

create or replace function public.reviews_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.reviews where booking = new.booking and kind <> new.kind) then
    update public.reviews set revealed = true where booking = new.booking;
  end if;
  return null;
end $$;
drop trigger if exists reviews_after_insert on public.reviews;
create trigger reviews_after_insert after insert on public.reviews
  for each row execute function public.reviews_after_insert();

-- ---------- functions the app calls ----------
create or replace function public.bump_view(lid uuid) returns void
language sql security definer set search_path = public as $$
  update public.listings set views = views + 1
   where id = lid and host is distinct from auth.uid() and auth.uid() is not null;
$$;

-- removes a listing; if it ever had bookings it is hidden instead, so its reviews stay
create or replace function public.remove_listing(lid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare h uuid;
begin
  select host into h from public.listings where id = lid;
  if h is null or h <> auth.uid() then raise exception 'not_allowed'; end if;
  if exists (select 1 from public.bookings where listing = lid) then
    update public.bookings set status = 'declined' where listing = lid and status = 'pending';
    update public.listings set archived = true where id = lid;
    return 'archived';
  end if;
  delete from public.listings where id = lid;
  return 'deleted';
end $$;

-- ---------- row level security ----------
alter table public.profiles enable row level security;
alter table public.contacts enable row level security;
alter table public.listings enable row level security;
alter table public.bookings enable row level security;
alter table public.reviews  enable row level security;
alter table public.saved    enable row level security;
alter table public.searches enable row level security;

drop policy if exists profiles_read   on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_read   on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists contacts_read   on public.contacts;
drop policy if exists contacts_insert on public.contacts;
drop policy if exists contacts_update on public.contacts;
create policy contacts_read on public.contacts for select to authenticated using (
  id = auth.uid() or exists (
    select 1 from public.bookings b
     where b.status in ('confirmed','completed')
       and ((b.worker = auth.uid() and b.host = contacts.id) or (b.host = auth.uid() and b.worker = contacts.id))));
create policy contacts_insert on public.contacts for insert to authenticated with check (id = auth.uid());
create policy contacts_update on public.contacts for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists listings_read   on public.listings;
drop policy if exists listings_insert on public.listings;
drop policy if exists listings_update on public.listings;
create policy listings_read   on public.listings for select to authenticated using (true);
create policy listings_insert on public.listings for insert to authenticated with check (
  host = auth.uid() and exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'host'));
create policy listings_update on public.listings for update to authenticated using (host = auth.uid()) with check (host = auth.uid());

drop policy if exists bookings_read   on public.bookings;
drop policy if exists bookings_insert on public.bookings;
drop policy if exists bookings_update on public.bookings;
create policy bookings_read   on public.bookings for select to authenticated using (worker = auth.uid() or host = auth.uid());
create policy bookings_insert on public.bookings for insert to authenticated with check (worker = auth.uid());
create policy bookings_update on public.bookings for update to authenticated using (worker = auth.uid() or host = auth.uid());

drop policy if exists reviews_read   on public.reviews;
drop policy if exists reviews_insert on public.reviews;
create policy reviews_read on public.reviews for select to authenticated using (
  revealed or from_id = auth.uid() or created_at < now() - interval '14 days');
create policy reviews_insert on public.reviews for insert to authenticated with check (from_id = auth.uid());

drop policy if exists saved_own on public.saved;
create policy saved_own on public.saved for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists searches_insert on public.searches;
drop policy if exists searches_read   on public.searches;
create policy searches_insert on public.searches for insert to authenticated with check (true);
create policy searches_read   on public.searches for select to authenticated using (created_at > now() - interval '60 days');

-- ---------- privileges ----------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke delete on public.listings, public.bookings, public.reviews, public.searches, public.profiles from authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant select on public.user_stats to authenticated;
revoke all on function public.bump_view(uuid), public.remove_listing(uuid) from public, anon;
grant execute on function public.bump_view(uuid), public.remove_listing(uuid) to authenticated;

-- ---------- photo & video storage ----------
insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do update set public = true;

drop policy if exists "avaz media upload" on storage.objects;
drop policy if exists "avaz media read own" on storage.objects;
drop policy if exists "avaz media delete" on storage.objects;
create policy "avaz media upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avaz media read own" on storage.objects for select to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avaz media delete" on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ======= patch 2 (also in migrations/002_patch2.sql) =======
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

-- ======= hardening (also in migrations/003_hardening.sql) =======
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
