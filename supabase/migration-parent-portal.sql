-- ============================================================================
--  Migration: parent portal (self-service multi-card accounts)
--  Run this ONCE in the Supabase SQL editor on the existing project.
--  Fresh installs of schema.sql already include all of this.
--
--  Requires: "Confirm email" ON in Supabase Auth (access is keyed to the
--  verified email, auth.email()).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Link table (function-internal: no direct access)
-- ----------------------------------------------------------------------------
create table if not exists public.card_links (
  id           bigint generated always as identity primary key,
  card_id      uuid not null references public.cards(id) on delete cascade,
  parent_email text not null,
  created_at   timestamptz not null default now(),
  unique (card_id, parent_email)
);
create index if not exists card_links_email_idx on public.card_links(parent_email);

alter table public.card_links enable row level security;
revoke all on table public.card_links from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- link_card: verify code + PIN (rate-limited), link to caller's email.
-- ----------------------------------------------------------------------------
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
  return jsonb_build_object('ok', true, 'name', c.name);
end;
$$;

-- ----------------------------------------------------------------------------
-- get_my_cards: caller's linked cards, curated (NO pin, NO phone).
-- ----------------------------------------------------------------------------
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
        'share_code', r.share_code, 'payments', r.payments, 'history', r.history),
      'business', jsonb_build_object(
        'name', r.b_name, 'type', r.b_type, 'fee', r.b_fee, 'year', r.b_year,
        'biz_code', r.b_code, 'inactive_months', r.b_inactive,
        'levels', r.b_levels, 'custom_card_image', r.b_image)
    );
  end loop;
  return result;
end;
$$;

-- ----------------------------------------------------------------------------
-- unlink_card: caller removes their own link only.
-- ----------------------------------------------------------------------------
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

-- ----------------------------------------------------------------------------
-- Grants: logged-in users only (never anon). Default EXECUTE was revoked by
-- the security-hardening migration, so these explicit grants are required.
-- ----------------------------------------------------------------------------
grant execute on function public.link_card(text, text) to authenticated;
grant execute on function public.get_my_cards()        to authenticated;
grant execute on function public.unlink_card(uuid)     to authenticated;

-- ============================================================================
--  Done. Sanity checks (optional, while logged in as a parent):
--    select public.get_my_cards();             -- [] until you link a card
--    select public.link_card('CODE','PIN');    -- {"ok": true, ...} on success
-- ============================================================================
