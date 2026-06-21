-- ============================================================================
--  Migration: Business Announcements (v1)
--  Run ONCE in the Supabase SQL editor, AFTER the storage bucket is created
--  (see the storage section at the bottom). Purely additive: one new table,
--  new RLS, two RPCs (one new, one extended), and storage policies. Does NOT
--  touch students/cards, payments, fee_history, or the approval gate.
-- ============================================================================

-- 1. Table ------------------------------------------------------------------
create table if not exists public.announcements (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  title       text not null,
  body        text,
  image_url   text,                              -- nullable; Supabase Storage public URL
  is_pinned   boolean not null default false,    -- pinned items surface first
  is_active   boolean not null default true,
  expires_at  timestamptz,                       -- nullable; past => treated as inactive
  created_at  timestamptz not null default now()
);

create index if not exists announcements_biz_active_idx
  on public.announcements (business_id, is_active, created_at desc);

alter table public.announcements enable row level security;

-- 2. RLS --------------------------------------------------------------------
-- Owner: full CRUD on rows for a business they own (same approved-owner check
-- the cards policies already use — no new auth pattern).
drop policy if exists announcements_select_own on public.announcements;
create policy announcements_select_own on public.announcements
  for select using (exists (
    select 1 from public.businesses b
    where b.id = announcements.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists announcements_insert_own on public.announcements;
create policy announcements_insert_own on public.announcements
  for insert with check (exists (
    select 1 from public.businesses b
    where b.id = business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists announcements_update_own on public.announcements;
create policy announcements_update_own on public.announcements
  for update using (exists (
    select 1 from public.businesses b
    where b.id = announcements.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists announcements_delete_own on public.announcements;
create policy announcements_delete_own on public.announcements
  for delete using (exists (
    select 1 from public.businesses b
    where b.id = announcements.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

-- Parent (authenticated, read-only): only ACTIVE, non-expired rows for a
-- business they're linked to via card_links. Defense-in-depth — the app reads
-- through the get_my_announcements() RPC below, but this keeps a direct query
-- safe too.
drop policy if exists announcements_select_parent on public.announcements;
create policy announcements_select_parent on public.announcements
  for select to authenticated using (
    is_active
    and (expires_at is null or expires_at > now())
    and business_id in (
      select c.business_id from public.card_links cl
      join public.cards c on c.id = cl.card_id
      where cl.parent_email = auth.email())
  );

-- 3. Parent RPC -------------------------------------------------------------
-- Mirrors get_my_cards(): returns the active, non-expired announcements for
-- every business the caller is linked to, pinned first then newest first.
create or replace function public.get_my_announcements()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r record;
begin
  if v_email is null then return result; end if;
  for r in
    select a.id, a.business_id, a.title, a.body, a.image_url, a.is_pinned, a.created_at,
           b.name as b_name
    from public.announcements a
    join public.businesses b on b.id = a.business_id
    where a.is_active
      and (a.expires_at is null or a.expires_at > now())
      and a.business_id in (
        select c.business_id from public.card_links cl
        join public.cards c on c.id = cl.card_id
        where cl.parent_email = v_email)
    order by a.is_pinned desc, a.created_at desc
  loop
    result := result || jsonb_build_object(
      'id', r.id, 'business_id', r.business_id, 'business_name', r.b_name,
      'title', r.title, 'body', r.body, 'image_url', r.image_url,
      'is_pinned', r.is_pinned, 'created_at', r.created_at);
  end loop;
  return result;
end;
$$;
revoke all on function public.get_my_announcements() from public, anon;
grant execute on function public.get_my_announcements() to authenticated;

-- 4. Student RPC (extend) ---------------------------------------------------
-- get_student_card() is the anonymous code+PIN reader. Re-create it with the
-- SAME body as the fee-history migration, plus an `announcements` array
-- (active, non-expired, pinned-first) for the card's business. Students are
-- not auth users, so this RPC is their only read path.
create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(trim(p_code));
  v_fails int;
  c public.cards%rowtype;
  b public.businesses%rowtype;
  v_ann jsonb;
begin
  delete from public.pin_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_fails from public.pin_attempts
   where share_code = v_code and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then return jsonb_build_object('locked', true); end if;

  select * into c from public.cards where share_code = v_code limit 1;
  if not found or c.pin is null or c.pin <> p_pin then
    insert into public.pin_attempts(share_code) values (v_code);
    return null;
  end if;

  delete from public.pin_attempts where share_code = v_code;
  select * into b from public.businesses where id = c.business_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'title', a.title, 'body', a.body,
           'image_url', a.image_url, 'is_pinned', a.is_pinned,
           'created_at', a.created_at) order by a.is_pinned desc, a.created_at desc), '[]'::jsonb)
    into v_ann
    from public.announcements a
    where a.business_id = b.id
      and a.is_active
      and (a.expires_at is null or a.expires_at > now());

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name, 'type', b.type, 'fee', b.fee, 'year', b.year,
      'biz_code', b.biz_code, 'inactive_months', b.inactive_months,
      'levels', b.levels, 'custom_card_image', b.custom_card_image),
    'card', jsonb_build_object(
      'name', c.name, 'level', c.level, 'share_code', c.share_code,
      'payments', c.payments, 'history', c.history,
      'enrollment_start_month', c.enrollment_start_month,
      'paused_months', c.paused_months,
      'fee_history', c.fee_history),
    'announcements', v_ann
  );
end;
$$;
grant execute on function public.get_student_card(text, text) to anon, authenticated;

-- ============================================================================
-- 5. Storage bucket  announcement-images
--    FIRST create a PUBLIC bucket named "announcement-images" in the dashboard
--    (Storage → New bucket → name: announcement-images → Public). THEN run:
-- ============================================================================
drop policy if exists ann_images_public_read on storage.objects;
create policy ann_images_public_read on storage.objects
  for select using (bucket_id = 'announcement-images');

drop policy if exists ann_images_auth_write on storage.objects;
create policy ann_images_auth_write on storage.objects
  for insert to authenticated with check (
    bucket_id = 'announcement-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));

drop policy if exists ann_images_auth_update on storage.objects;
create policy ann_images_auth_update on storage.objects
  for update to authenticated using (
    bucket_id = 'announcement-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()))
  with check (
    bucket_id = 'announcement-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));

drop policy if exists ann_images_auth_delete on storage.objects;
create policy ann_images_auth_delete on storage.objects
  for delete to authenticated using (
    bucket_id = 'announcement-images'
    and (storage.foldername(name))[1] in
        (select id::text from public.businesses where owner_id = auth.uid()));

-- ============================================================================
--  Done. Sanity check:
--    select id, business_id, title, is_pinned, is_active, expires_at
--      from public.announcements order by created_at desc;
-- ============================================================================
