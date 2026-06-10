-- ============================================================================
--  Migration: security hardening (audit fixes #1, #2, #3)
--  Run this ONCE in the Supabase SQL editor on the existing project.
--  Fresh installs of schema.sql already include all of this.
--
--  #1  Rate-limit student PIN attempts (5 failures / 15 min per code)
--  #2  Tenant-scope card-images storage writes (no cross-business overwrite)
--  #3  Per-function grants instead of blanket EXECUTE for anon
-- ============================================================================

-- ----------------------------------------------------------------------------
-- #1  PIN rate-limiting
-- ----------------------------------------------------------------------------
-- Failed attempts are logged per code (including unknown codes, so a
-- "locked" reply never confirms a code exists). After 5 failures within
-- 15 minutes the code is locked and get_student_card returns
-- {"locked": true} until the window passes. Success clears the history.

create table if not exists public.pin_attempts (
  id           bigint generated always as identity primary key,
  share_code   text not null,
  attempted_at timestamptz not null default now()
);
create index if not exists pin_attempts_code_time_idx
  on public.pin_attempts(share_code, attempted_at);

-- Nobody touches this table directly — only the SECURITY DEFINER function
-- (which runs as the table owner). RLS on + zero policies = no access.
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
      'history',    c.history
    )
  );
end;
$$;

-- ----------------------------------------------------------------------------
-- #3  Function grants: default-deny, allow only what the app calls
-- ----------------------------------------------------------------------------
-- Postgres grants EXECUTE to PUBLIC by default on every new function — stop
-- that for future functions, strip it from existing ones, then re-allow only
-- get_student_card.

alter default privileges in schema public revoke execute on functions from public;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_student_card(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- #2  Tenant-scoped storage policies for card-images
-- ----------------------------------------------------------------------------
-- The app uploads to "<business_id>/card-...". These policies only allow
-- touching objects whose top-level folder is a business the logged-in
-- teacher owns. Public READ stays as-is (finding #4, owner's decision).

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
--  Done. Sanity checks (optional):
--    select * from public.pin_attempts;        -- should error for non-admins
--    select public.get_student_card('X','0');  -- should return null
-- ============================================================================
