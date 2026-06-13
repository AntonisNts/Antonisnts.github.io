-- ============================================================================
--  Migration: parent-side child grouping
--  Run ONCE in the Supabase SQL editor. Follows the existing parent-portal
--  pattern (function-internal tables + SECURITY DEFINER functions keyed to
--  auth.email(), granted to authenticated only).
--  NEVER deletes card or payment data. Deleting a child only nulls child_id.
--  Depends on the parent-portal migration (card_links, get_my_cards, etc.).
-- ============================================================================

-- ---- children table (function-internal: no direct access) ------------------
create table if not exists public.children (
  id           uuid primary key default gen_random_uuid(),
  parent_email text not null,
  name         text not null,
  created_at   timestamptz not null default now()
);
create index if not exists children_email_idx on public.children(parent_email);
alter table public.children enable row level security;
revoke all on table public.children from public, anon, authenticated;

-- ---- card_links gets an optional child_id ----------------------------------
-- ON DELETE SET NULL: deleting a child unassigns its cards, never deletes them.
alter table public.card_links
  add column if not exists child_id uuid references public.children(id) on delete set null;

-- ---- link_card: now also returns the linked card_id (for assignment) -------
create or replace function public.link_card(p_code text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code  text := upper(trim(p_code));
  v_email text := auth.email();
  v_fails int;
  c public.cards%rowtype;
begin
  if v_email is null then return jsonb_build_object('error', 'not_authenticated'); end if;

  delete from public.pin_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_fails from public.pin_attempts
   where share_code = v_code and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then return jsonb_build_object('locked', true); end if;

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

-- ---- get_my_cards: now also returns each card's child_id -------------------
create or replace function public.get_my_cards()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_email text := auth.email();
  result  jsonb := '[]'::jsonb;
  r record;
begin
  if v_email is null then return result; end if;
  for r in
    select c.id, c.name, c.level, c.share_code, c.payments, c.history,
           c.enrollment_start_month, cl.child_id,
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
        'id', r.id, 'name', r.name, 'level', r.level, 'share_code', r.share_code,
        'payments', r.payments, 'history', r.history,
        'enrollment_start_month', r.enrollment_start_month, 'child_id', r.child_id),
      'business', jsonb_build_object(
        'name', r.b_name, 'type', r.b_type, 'fee', r.b_fee, 'year', r.b_year,
        'biz_code', r.b_code, 'inactive_months', r.b_inactive,
        'levels', r.b_levels, 'custom_card_image', r.b_image)
    );
  end loop;
  return result;
end;
$$;

-- ---- child operations (all caller-scoped via auth.email()) -----------------
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
  -- when assigning (not unassigning), the child must belong to the caller
  if p_child_id is not null and not exists (
       select 1 from public.children where id = p_child_id and parent_email = v_email) then
    return jsonb_build_object('ok', false, 'error', 'not_your_child');
  end if;
  update public.card_links set child_id = p_child_id
    where card_id = p_card_id and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---- grants (authenticated only; default EXECUTE was revoked by hardening) --
grant execute on function public.get_my_cards()                  to authenticated;
grant execute on function public.link_card(text, text)           to authenticated;
grant execute on function public.get_my_children()               to authenticated;
grant execute on function public.create_child(text)              to authenticated;
grant execute on function public.rename_child(uuid, text)        to authenticated;
grant execute on function public.delete_child(uuid)              to authenticated;
grant execute on function public.assign_card(uuid, uuid)         to authenticated;

-- ============================================================================
--  Done. No card/payment data touched. Sanity check (as a logged-in parent):
--    select public.get_my_children();   -- [] until you create one
-- ============================================================================
