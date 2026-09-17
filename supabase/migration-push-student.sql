-- ===========================================================================
--  PUSH NOTIFICATIONS — the student portal
--  ---------------------------------------------------------------------------
--  "What about in the student portal? Shouldn't we also have the turn
--   notifications on in case a user has only the student portal?"
--
--  Yes. A family with one child at one school never makes an account, and
--  push_subscribe reads auth.email(), so for them the switch could not work.
--
--  A subscription is identified by a CARD here rather than an email, because a
--  student has no email. That is the whole change: one nullable column, and
--  the same functions again with stamp_student_card doing the proving instead
--  of auth.email().
--
--  WHAT THIS DOES NOT DO: the number on the app icon. The count has to be that
--  person's unread total, and the student portal records what has been read in
--  localStorage on the device -- the database has never been told. Rather than
--  invent a number that would be wrong, a student subscription carries no
--  badge at all and the icon stays bare. The notification itself arrives
--  exactly as it does for a parent. Giving students the number too means
--  recording "seen" server-side, which is its own piece of work.
-- ===========================================================================


-- ===========================================================================
--  1. A subscription can belong to a card instead of an email
-- ===========================================================================

alter table public.push_subscriptions
  add column if not exists card_id uuid references public.cards(id) on delete cascade;

alter table public.push_subscriptions
  alter column parent_email drop not null;

-- Exactly one owner, never both and never neither. Without this a row could
-- exist that no audience query would ever find, and nobody would know why that
-- phone had gone quiet.
alter table public.push_subscriptions
  drop constraint if exists push_subs_one_owner;
alter table public.push_subscriptions
  add constraint push_subs_one_owner check (
    (parent_email is not null and card_id is null) or
    (parent_email is null and card_id is not null));

create index if not exists push_subs_card_idx
  on public.push_subscriptions (card_id) where gone_at is null;


-- ===========================================================================
--  2. The same three functions, proved the student portal's way
-- ===========================================================================

create or replace function public.push_subscribe_student(
  p_code text, p_pin text, p_endpoint text, p_p256dh text, p_auth text,
  p_user_agent text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error','no_match'); end if;
  if p_endpoint is null or length(p_endpoint) < 12 or length(p_endpoint) > 2000
     or p_endpoint !~ '^https://' then
    return jsonb_build_object('error','bad_endpoint');
  end if;
  if p_p256dh is null or p_auth is null
     or length(p_p256dh) > 200 or length(p_auth) > 100 then
    return jsonb_build_object('error','bad_keys');
  end if;

  -- The endpoint is the browser's, so whoever subscribed it last owns it --
  -- including when a phone moves from a parent's account to a student's card,
  -- or the other way. parent_email is cleared for exactly that reason.
  insert into public.push_subscriptions(card_id, parent_email, endpoint, p256dh, auth, user_agent)
    values (c.id, null, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent,''), 300))
  on conflict (endpoint) do update
    set card_id      = excluded.card_id,
        parent_email = null,
        p256dh       = excluded.p256dh,
        auth         = excluded.auth,
        user_agent   = excluded.user_agent,
        last_seen_at = now(),
        gone_at      = null;

  return jsonb_build_object('ok', true);
end;
$$;


create or replace function public.push_unsubscribe_student(
  p_code text, p_pin text, p_endpoint text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error','no_match'); end if;
  delete from public.push_subscriptions
   where endpoint = p_endpoint and card_id = c.id;
  return jsonb_build_object('ok', true);
end;
$$;


create or replace function public.push_status_student(
  p_code text, p_pin text, p_endpoint text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype; v_on boolean;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('on', false); end if;
  select true into v_on from public.push_subscriptions
   where endpoint = p_endpoint and card_id = c.id and gone_at is null;
  return jsonb_build_object('on', coalesce(v_on, false));
end;
$$;


-- The parent's own subscribe has to clear card_id for the same reason the
-- student's clears parent_email: a phone that moves between the two portals
-- would otherwise end up with both owners set, and the check constraint above
-- would refuse the write. Without the constraint it would instead have been
-- delivered to twice, which is the version nobody notices.
create or replace function public.push_subscribe(
  p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return jsonb_build_object('error','not_authenticated'); end if;
  if p_endpoint is null or length(p_endpoint) < 12 or length(p_endpoint) > 2000
     or p_endpoint !~ '^https://' then
    return jsonb_build_object('error','bad_endpoint');
  end if;
  if p_p256dh is null or p_auth is null
     or length(p_p256dh) > 200 or length(p_auth) > 100 then
    return jsonb_build_object('error','bad_keys');
  end if;

  insert into public.push_subscriptions(parent_email, card_id, endpoint, p256dh, auth, user_agent)
    values (v_email, null, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent,''), 300))
  on conflict (endpoint) do update
    set parent_email = excluded.parent_email,
        card_id      = null,
        p256dh       = excluded.p256dh,
        auth         = excluded.auth,
        user_agent   = excluded.user_agent,
        last_seen_at = now(),
        gone_at      = null;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.push_subscribe(text,text,text,text) from public, anon;
grant execute on function public.push_subscribe(text,text,text,text) to authenticated;


-- ===========================================================================
--  3. The audience, now two kinds of subscriber
-- ===========================================================================
--
--  A card-based subscription is matched against the announcement's target
--  directly -- the same three rules, applied to the one card rather than to
--  every card a parent has.
--
--  `badge` is null for those, and the worker leaves the icon alone when it is:
--  see the header. An email subscription still carries its count.
-- ---------------------------------------------------------------------------

create or replace function public.push_audience(p_announcement_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare a public.announcements%rowtype; b public.businesses%rowtype;
begin
  select * into a from public.announcements where id = p_announcement_id;
  if not found then return jsonb_build_object('error','no_match'); end if;

  if not a.is_active or (a.expires_at is not null and a.expires_at <= now()) then
    return jsonb_build_object('error','not_active');
  end if;

  select * into b from public.businesses where id = a.business_id;
  if not found then return jsonb_build_object('error','no_business'); end if;

  return jsonb_build_object(
    'ok', true,
    'title', a.title,
    'body', a.body,
    'school', b.name,
    'subscriptions', coalesce((
      select jsonb_agg(x) from (
        -- Parents, by email, with their unread count.
        select jsonb_build_object(
                 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
                 'badge', public.push_unread_count(s.parent_email)) as x
          from public.push_subscriptions s
         where s.gone_at is null
           and s.parent_email is not null
           and s.parent_email in (
             select cl.parent_email
               from public.card_links cl
               join public.cards c on c.id = cl.card_id
              where c.business_id = a.business_id
                and (a.card_id  is null or c.id       = a.card_id)
                and (a.group_id is null or c.group_id = a.group_id))
        union all
        -- Students, by card, with no count -- the database has never been told
        -- what they have read.
        select jsonb_build_object(
                 'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth) as x
          from public.push_subscriptions s
          join public.cards c on c.id = s.card_id
         where s.gone_at is null
           and s.card_id is not null
           and c.business_id = a.business_id
           and (a.card_id  is null or c.id       = a.card_id)
           and (a.group_id is null or c.group_id = a.group_id)
      ) q
    ), '[]'::jsonb));
end;
$$;


-- ===========================================================================
--  4. Grants
--
--  anon as well as authenticated, because the student portal has no session at
--  all. Each of these calls stamp_student_card first, which is rate limited and
--  checks the PIN itself.
--
--  A code and a PIN already open that student's card, their fees and their
--  school's announcements. Being able to have those announcements pushed to
--  the phone is the same information arriving sooner, not new information.
-- ===========================================================================

revoke all on function public.push_subscribe_student(text,text,text,text,text,text) from public;
revoke all on function public.push_unsubscribe_student(text,text,text)              from public;
revoke all on function public.push_status_student(text,text,text)                   from public;

grant execute on function public.push_subscribe_student(text,text,text,text,text,text) to anon, authenticated;
grant execute on function public.push_unsubscribe_student(text,text,text)              to anon, authenticated;
grant execute on function public.push_status_student(text,text,text)                   to anon, authenticated;

revoke all on function public.push_audience(uuid) from public, anon, authenticated;
grant execute on function public.push_audience(uuid) to service_role;


-- ===========================================================================
--  REMOVING THIS
--
--    drop function if exists public.push_status_student(text,text,text);
--    drop function if exists public.push_unsubscribe_student(text,text,text);
--    drop function if exists public.push_subscribe_student(text,text,text,text,text,text);
--    delete from public.push_subscriptions where card_id is not null;
--    alter table public.push_subscriptions drop constraint if exists push_subs_one_owner;
--    alter table public.push_subscriptions drop column if exists card_id;
--    alter table public.push_subscriptions alter column parent_email set not null;
--
--  then re-run push_audience from migration-push-badge.sql.
-- ===========================================================================
