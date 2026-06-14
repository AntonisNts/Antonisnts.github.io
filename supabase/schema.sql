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
  phone        text,                                    -- optional contact number for Viber/WhatsApp reminders
  enrollment_start_month text,                           -- 'YYYY-MM' or null; per-student billing start
  preferred_channel      text,                           -- 'whatsapp' | 'viber' | 'sms'
  language               text,                           -- 'EN' | 'EL' (receipt language)
  paused_months          jsonb not null default '[]'::jsonb, -- per-student mid-year pause (same shape as inactive_months)
  fee_history            jsonb not null default '[]'::jsonb, -- [{from:<0-11>,fee:<num>}] periods; [] = single fee
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
--  Student access  (no login — code + PIN only)  +  PIN rate-limiting
-- ============================================================================
--  Students are NOT auth users and have NO direct table access. This single
--  SECURITY DEFINER function validates the PIN server-side and returns only
--  the one matching card. A wrong code OR wrong PIN both return null, so it
--  never reveals which codes exist.
--
--  Rate-limiting: failed attempts are logged per code (including unknown
--  codes, so a "locked" reply never confirms a code exists). After 5
--  failures within 15 minutes the code is locked and the function returns
--  {"locked": true} until the window passes. A successful login clears the
--  failure history for that code.

create table if not exists public.pin_attempts (
  id           bigint generated always as identity primary key,
  share_code   text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists pin_attempts_code_time_idx
  on public.pin_attempts(share_code, attempted_at);

-- Nobody touches this table directly — only the SECURITY DEFINER function
-- below (which runs as the table owner). RLS on + zero policies = no access.
alter table public.pin_attempts enable row level security;
revoke all on table public.pin_attempts from public, anon, authenticated;

create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code  text := upper(trim(p_code));
  v_fails int;
  c public.cards%rowtype;
  b public.businesses%rowtype;
begin
  -- housekeeping: drop stale attempt rows so the table stays tiny
  delete from public.pin_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_fails
  from public.pin_attempts
  where share_code = v_code
    and attempted_at > now() - interval '15 minutes';

  if v_fails >= 5 then
    return jsonb_build_object('locked', true);
  end if;

  select * into c from public.cards where share_code = v_code limit 1;
  if not found or c.pin is null or c.pin <> p_pin then
    insert into public.pin_attempts(share_code) values (v_code);
    return null;
  end if;

  -- success: clear this code's failure history
  delete from public.pin_attempts where share_code = v_code;

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
      'history',    c.history,
      'enrollment_start_month', c.enrollment_start_month,
      'paused_months', c.paused_months,
      'fee_history', c.fee_history
    )
  );
end;
$$;

revoke all on function public.get_student_card(text, text) from public;
grant  execute on function public.get_student_card(text, text) to anon, authenticated;

-- ============================================================================
--  Parent portal  (self-service multi-card accounts)
-- ============================================================================
--  A parent/student logs in (Supabase Auth, email confirmed) and links cards
--  themselves by proving share_code + PIN. Links are keyed to the verified
--  email (auth.email()). Teacher workflow is unchanged; the anonymous
--  get_student_card() path above still works for non-account access.

create table if not exists public.card_links (
  id           bigint generated always as identity primary key,
  card_id      uuid not null references public.cards(id) on delete cascade,
  parent_email text not null,
  created_at   timestamptz not null default now(),
  unique (card_id, parent_email)
);
create index if not exists card_links_email_idx on public.card_links(parent_email);

-- Function-internal table: no direct access, only the SECURITY DEFINER
-- functions below (which run as owner) read/write it.
alter table public.card_links enable row level security;
revoke all on table public.card_links from public, anon, authenticated;

-- Parent children (function-internal: no direct access). Grouping is owned by
-- the parent, not inferred from student names.
create table if not exists public.children (
  id           uuid primary key default gen_random_uuid(),
  parent_email text not null,
  name         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists children_email_idx on public.children(parent_email);
alter table public.children enable row level security;
revoke all on table public.children from public, anon, authenticated;

-- A linked card may be assigned to one child. ON DELETE SET NULL means
-- deleting a child unassigns its cards — it never deletes a card.
alter table public.card_links
  add column if not exists child_id uuid references public.children(id) on delete set null;

-- link_card: verify code + PIN (rate-limited), then link the card to the
-- caller's verified email. Requires an authenticated, confirmed user.
create or replace function public.link_card(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code  text := upper(trim(p_code));
  v_email text := auth.email();
  v_fails int;
  c public.cards%rowtype;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  delete from public.pin_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_fails from public.pin_attempts
   where share_code = v_code and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then
    return jsonb_build_object('locked', true);
  end if;

  select * into c from public.cards where share_code = v_code limit 1;
  if not found or c.pin is null or c.pin <> p_pin then
    insert into public.pin_attempts(share_code) values (v_code);
    return jsonb_build_object('ok', false);
  end if;

  delete from public.pin_attempts where share_code = v_code;
  insert into public.card_links(card_id, parent_email)
    values (c.id, v_email)
    on conflict (card_id, parent_email) do nothing;
  return jsonb_build_object('ok', true, 'name', c.name, 'card_id', c.id);
end;
$$;

-- get_my_cards: all cards linked to the caller's email, with curated fields
-- (NO pin, NO phone) so parents never see those.
create or replace function public.get_my_cards()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r record;
begin
  if v_email is null then
    return result;
  end if;
  for r in
    select c.id, c.name, c.level, c.share_code, c.payments, c.history,
           c.enrollment_start_month, c.paused_months, c.fee_history, cl.child_id,
           b.name as b_name, b.type as b_type, b.fee as b_fee, b.year as b_year,
           b.biz_code as b_code, b.inactive_months as b_inactive,
           b.levels as b_levels, b.custom_card_image as b_image
    from public.card_links cl
    join public.cards c       on c.id = cl.card_id
    join public.businesses b  on b.id = c.business_id
    where cl.parent_email = v_email
    order by c.name
  loop
    result := result || jsonb_build_object(
      'card', jsonb_build_object(
        'id', r.id, 'name', r.name, 'level', r.level,
        'share_code', r.share_code, 'payments', r.payments, 'history', r.history,
        'enrollment_start_month', r.enrollment_start_month,
        'paused_months', r.paused_months, 'fee_history', r.fee_history, 'child_id', r.child_id),
      'business', jsonb_build_object(
        'name', r.b_name, 'type', r.b_type, 'fee', r.b_fee, 'year', r.b_year,
        'biz_code', r.b_code, 'inactive_months', r.b_inactive,
        'levels', r.b_levels, 'custom_card_image', r.b_image)
    );
  end loop;
  return result;
end;
$$;

-- unlink_card: the caller removes their own link (cannot affect others').
create or replace function public.unlink_card(p_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
begin
  if v_email is null then
    return jsonb_build_object('ok', false);
  end if;
  delete from public.card_links where card_id = p_card_id and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;

-- Child operations (all caller-scoped via auth.email()).
create or replace function public.get_my_children()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email(); result jsonb := '[]'::jsonb; r record;
begin
  if v_email is null then return result; end if;
  for r in select id, name from public.children where parent_email = v_email order by name loop
    result := result || jsonb_build_object('id', r.id, 'name', r.name);
  end loop;
  return result;
end;
$$;

create or replace function public.create_child(p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email(); v_name text := trim(p_name); v_id uuid;
begin
  if v_email is null then return jsonb_build_object('ok', false); end if;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'empty_name'); end if;
  insert into public.children(parent_email, name) values (v_email, v_name) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'name', v_name);
end;
$$;

create or replace function public.rename_child(p_id uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email(); v_name text := trim(p_name);
begin
  if v_email is null then return jsonb_build_object('ok', false); end if;
  if v_name = '' then return jsonb_build_object('ok', false, 'error', 'empty_name'); end if;
  update public.children set name = v_name where id = p_id and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.delete_child(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return jsonb_build_object('ok', false); end if;
  -- card_links.child_id is ON DELETE SET NULL: cards are unassigned, never deleted.
  delete from public.children where id = p_id and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.assign_card(p_card_id uuid, p_child_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return jsonb_build_object('ok', false); end if;
  if p_child_id is not null and not exists (
       select 1 from public.children where id = p_child_id and parent_email = v_email) then
    return jsonb_build_object('ok', false, 'error', 'not_your_child');
  end if;
  update public.card_links set child_id = p_child_id
    where card_id = p_card_id and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;

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

-- Function-internal tables: re-revoke after the blanket grant above so
-- re-running this file never re-exposes them.
revoke all on table public.pin_attempts from public, anon, authenticated;
revoke all on table public.card_links  from public, anon, authenticated;
revoke all on table public.children    from public, anon, authenticated;

-- Functions: default-deny. Postgres grants EXECUTE to PUBLIC by default on
-- every new function — stop that for future functions, strip it from
-- existing ones, then allow only what the app actually calls.
alter default privileges in schema public revoke execute on functions from public;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_student_card(text, text) to anon, authenticated;
-- Parent portal: must be logged in (authenticated only, never anon).
grant execute on function public.link_card(text, text) to authenticated;
grant execute on function public.get_my_cards()        to authenticated;
grant execute on function public.unlink_card(uuid)     to authenticated;
grant execute on function public.get_my_children()        to authenticated;
grant execute on function public.create_child(text)       to authenticated;
grant execute on function public.rename_child(uuid, text) to authenticated;
grant execute on function public.delete_child(uuid)       to authenticated;
grant execute on function public.assign_card(uuid, uuid)  to authenticated;

-- ============================================================================
--  Storage policies for the  card-images  bucket
-- ============================================================================
--  FIRST create a PUBLIC bucket named "card-images" in the dashboard
--  (Storage → New bucket → name: card-images → Public). THEN run this block.

drop policy if exists card_images_public_read on storage.objects;
create policy card_images_public_read on storage.objects
  for select using (bucket_id = 'card-images');

--  Writes are tenant-scoped: the app uploads to "<business_id>/card-...",
--  and these policies only allow touching objects whose top-level folder is
--  a business the logged-in teacher owns. Reads stay public (the bucket
--  serves card background images by URL).

drop policy if exists card_images_auth_write on storage.objects;
create policy card_images_auth_write on storage.objects
  for insert to authenticated with check (
    bucket_id = 'card-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid())
  );

drop policy if exists card_images_auth_update on storage.objects;
create policy card_images_auth_update on storage.objects
  for update to authenticated using (
    bucket_id = 'card-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid())
  ) with check (
    bucket_id = 'card-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid())
  );

drop policy if exists card_images_auth_delete on storage.objects;
create policy card_images_auth_delete on storage.objects
  for delete to authenticated using (
    bucket_id = 'card-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid())
  );

-- ============================================================================
--  Done. Quick sanity check (optional):
--    select * from public.businesses;   -- should be empty, no error
-- ============================================================================
