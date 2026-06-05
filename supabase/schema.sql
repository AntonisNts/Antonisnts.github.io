-- ============================================================================
--  StampCard — Supabase schema
--  Run this in the Supabase dashboard:  SQL Editor → New query → paste → Run.
--  Safe to run more than once (idempotent).
-- ============================================================================

-- ---- Extensions ------------------------------------------------------------
-- pgcrypto gives us gen_random_uuid().
create extension if not exists pgcrypto;

-- ============================================================================
--  Tables
-- ============================================================================
--  Teachers log in through Supabase Auth (auth.users), so we do NOT store a
--  teacher password here — Supabase hashes and manages it. Each business is
--  owned by exactly one auth user. Student PINs are stored as plain text on
--  purpose — they are teacher-assigned, shareable 4-digit codes (not passwords).
--
--  payments / history / levels / inactive_months are kept as JSONB so the
--  existing front-end calculation helpers keep working unchanged.

create table if not exists public.businesses (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null default auth.uid()
                       references auth.users(id) on delete cascade,
  biz_code          text unique not null,              -- display code, e.g. BIZ-860E20
  name              text not null,
  type              text not null,
  fee               numeric not null check (fee >= 0),
  year              int  not null,
  contact_email     text,
  inactive_months   jsonb not null default '[]'::jsonb,
  levels            jsonb not null default '[]'::jsonb,
  custom_card_image text,                               -- URL into the card-images bucket
  created_at        timestamptz not null default now()
);

create table if not exists public.cards (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  name         text not null,
  level        jsonb,                                   -- {id,name,fee} snapshot or null
  share_code   text unique not null,                    -- globally unique student code
  pin          text not null,                           -- plain-text 4-digit code (teacher-assigned, shareable)
  payments     jsonb not null default '{}'::jsonb,
  history      jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists businesses_owner_idx on public.businesses(owner_id);
create index if not exists cards_business_id_idx on public.cards(business_id);

-- ============================================================================
--  Row-Level Security  (the heart of multi-tenant isolation)
-- ============================================================================
--  With RLS on, the database itself refuses to return rows that don't belong
--  to the logged-in teacher — independent of any front-end bug.

alter table public.businesses enable row level security;
alter table public.cards      enable row level security;

-- Businesses: a teacher only ever sees / changes their own businesses.
drop policy if exists businesses_select_own on public.businesses;
create policy businesses_select_own on public.businesses
  for select using (owner_id = auth.uid());

drop policy if exists businesses_insert_own on public.businesses;
create policy businesses_insert_own on public.businesses
  for insert with check (owner_id = auth.uid());

drop policy if exists businesses_update_own on public.businesses;
create policy businesses_update_own on public.businesses
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists businesses_delete_own on public.businesses;
create policy businesses_delete_own on public.businesses
  for delete using (owner_id = auth.uid());

-- Cards: accessible only when the parent business belongs to the teacher.
drop policy if exists cards_select_own on public.cards;
create policy cards_select_own on public.cards
  for select using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid()));

drop policy if exists cards_insert_own on public.cards;
create policy cards_insert_own on public.cards
  for insert with check (exists (
    select 1 from public.businesses b
    where b.id = business_id and b.owner_id = auth.uid()));

drop policy if exists cards_update_own on public.cards;
create policy cards_update_own on public.cards
  for update using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid()));

drop policy if exists cards_delete_own on public.cards;
create policy cards_delete_own on public.cards
  for delete using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid()));

-- ============================================================================
--  Student access  (no login — code + PIN only)
-- ============================================================================
--  Students are NOT auth users and have NO direct table access. This single
--  SECURITY DEFINER function validates the PIN server-side and returns only
--  the one matching card. A wrong code OR wrong PIN both return null, so it
--  never reveals which codes exist.

create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cards%rowtype;
  b public.businesses%rowtype;
begin
  select * into c from public.cards where share_code = upper(trim(p_code)) limit 1;
  if not found then
    return null;
  end if;
  if c.pin is null or c.pin <> p_pin then
    return null;
  end if;

  select * into b from public.businesses where id = c.business_id;

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name',              b.name,
      'type',              b.type,
      'fee',               b.fee,
      'year',              b.year,
      'biz_code',          b.biz_code,
      'inactive_months',   b.inactive_months,
      'levels',            b.levels,
      'custom_card_image', b.custom_card_image
    ),
    'card', jsonb_build_object(
      'name',       c.name,
      'level',      c.level,
      'share_code', c.share_code,
      'payments',   c.payments,
      'history',    c.history
    )
  );
end;
$$;

revoke all on function public.get_student_card(text, text) from public;
grant  execute on function public.get_student_card(text, text) to anon, authenticated;

-- ============================================================================
--  Role grants
-- ============================================================================
--  RLS decides WHICH rows a user can touch; these grants decide whether the
--  role can touch the tables/functions at all. Without them, registration and
--  reads fail with permission errors. Row visibility is still governed by the
--  RLS policies above — these grants do not bypass them.

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- ============================================================================
--  Storage policies for the  card-images  bucket
-- ============================================================================
--  FIRST create a PUBLIC bucket named "card-images" in the dashboard
--  (Storage → New bucket → name: card-images → Public). THEN run this block.

drop policy if exists card_images_public_read on storage.objects;
create policy card_images_public_read on storage.objects
  for select using (bucket_id = 'card-images');

drop policy if exists card_images_auth_write on storage.objects;
create policy card_images_auth_write on storage.objects
  for insert to authenticated with check (bucket_id = 'card-images');

drop policy if exists card_images_auth_update on storage.objects;
create policy card_images_auth_update on storage.objects
  for update to authenticated using (bucket_id = 'card-images');

drop policy if exists card_images_auth_delete on storage.objects;
create policy card_images_auth_delete on storage.objects
  for delete to authenticated using (bucket_id = 'card-images');

-- ============================================================================
--  Done. Quick sanity check (optional):
--    select * from public.businesses;   -- should be empty, no error
-- ============================================================================
