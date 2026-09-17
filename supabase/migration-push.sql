-- ===========================================================================
--  PUSH NOTIFICATIONS
--  ---------------------------------------------------------------------------
--  The problem this solves, in the owner's words: "when the business sends a
--  message the users get notified [on Viber] but when they send in the app
--  it's just a website that the users have to open frequently and check it."
--
--  That was exactly right. Nothing in PayStamp has ever sent a notification.
--  A parent found out about an announcement by deciding to go and look.
--
--  This is the database half: somewhere to keep the browser subscriptions a
--  parent's phone hands out, and one function that works out who a given
--  announcement should reach. The sending itself is an Edge Function --
--  supabase/functions/push-announcement -- because signing a Web Push request
--  needs a private key, and a private key cannot live in a page every parent
--  downloads.
--
--  It alters no existing table. Announcements work exactly as they did; this
--  reads them.
-- ===========================================================================


-- ===========================================================================
--  1. The subscriptions
-- ===========================================================================
--
--  One row per browser, not per person. A parent with a phone and a laptop has
--  two, and both should ring. The endpoint is the identity: it is the URL the
--  push service gave that browser, it is unique, and it is what a re-subscribe
--  collides on.
--
--  parent_email, not user_id, because card_links is keyed on email -- that is
--  what decides which announcements a person is entitled to hear about, so
--  matching on anything else would mean a join that could disagree with the
--  portal.
-- ---------------------------------------------------------------------------

create table if not exists public.push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  parent_email  text not null,
  endpoint      text not null unique,
  -- The browser's public key and auth secret, from PushSubscription.toJSON().
  -- They encrypt the payload TO that browser: without them a push can still be
  -- delivered but can carry nothing, which would mean a notification that
  -- could not say what it was about.
  p256dh        text not null,
  auth          text not null,
  user_agent    text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  -- Set when the push service says this endpoint is gone (404/410). Kept
  -- rather than deleted for a while, so "why did this phone stop ringing" has
  -- an answer.
  gone_at       timestamptz
);

create index if not exists push_subs_email_idx
  on public.push_subscriptions (parent_email) where gone_at is null;

alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from public, anon, authenticated;

-- No policy is written on purpose. Every route in is a function below, as
-- everywhere else in this codebase; a table nobody can select from cannot leak
-- the set of endpoints, which is the one thing here worth protecting -- an
-- endpoint is a capability to make somebody's phone buzz.


-- ===========================================================================
--  2. A parent turning notifications on, and off
-- ===========================================================================

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

  -- The same browser re-subscribing must not create a second row, and a phone
  -- that changed hands must not keep ringing for the previous owner -- so the
  -- endpoint's email is overwritten, not preserved.
  insert into public.push_subscriptions(parent_email, endpoint, p256dh, auth, user_agent)
    values (v_email, p_endpoint, p_p256dh, p_auth, left(coalesce(p_user_agent,''), 300))
  on conflict (endpoint) do update
    set parent_email = excluded.parent_email,
        p256dh       = excluded.p256dh,
        auth         = excluded.auth,
        user_agent   = excluded.user_agent,
        last_seen_at = now(),
        gone_at      = null;

  return jsonb_build_object('ok', true);
end;
$$;


create or replace function public.push_unsubscribe(p_endpoint text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email();
begin
  if v_email is null then return jsonb_build_object('error','not_authenticated'); end if;
  delete from public.push_subscriptions
   where endpoint = p_endpoint and parent_email = v_email;
  return jsonb_build_object('ok', true);
end;
$$;


-- Whether THIS browser is already subscribed, so the switch can show the truth
-- rather than asking the browser, which only knows it has a subscription and
-- not whether we ever stored it.
create or replace function public.push_status(p_endpoint text)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare v_email text := auth.email(); v_on boolean;
begin
  if v_email is null then return jsonb_build_object('on', false); end if;
  select true into v_on from public.push_subscriptions
   where endpoint = p_endpoint and parent_email = v_email and gone_at is null;
  return jsonb_build_object('on', coalesce(v_on, false));
end;
$$;


-- ===========================================================================
--  3. Who an announcement should reach
-- ===========================================================================
--
--  The audience rules are the announcement's own, and they are already written
--  down twice -- in get_my_announcements and in the portal's targeting filter.
--  This is the third place, which is a real risk of drift, so it is spelled out
--  the same way and tested against the same cases:
--
--      card_id  set  -> that one student's parents
--      group_id set  -> that class
--      neither       -> the whole school
--
--  Called only by the Edge Function, with the service role. It returns
--  endpoints, which are capabilities to buzz a phone, so no ordinary caller
--  may have it -- see the grants at the foot.
-- ---------------------------------------------------------------------------

create or replace function public.push_audience(p_announcement_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare a public.announcements%rowtype; b public.businesses%rowtype;
begin
  select * into a from public.announcements where id = p_announcement_id;
  if not found then return jsonb_build_object('error','no_match'); end if;

  -- An announcement that is switched off, or already expired, is not news.
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
      select jsonb_agg(distinct jsonb_build_object(
               'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
        from public.push_subscriptions s
       where s.gone_at is null
         and s.parent_email in (
           select cl.parent_email
             from public.card_links cl
             join public.cards c on c.id = cl.card_id
            where c.business_id = a.business_id
              and (a.card_id  is null or c.id       = a.card_id)
              and (a.group_id is null or c.group_id = a.group_id))
    ), '[]'::jsonb));
end;
$$;


-- A push service answering 404 or 410 means that browser is gone for good --
-- the app was deleted, or notifications were turned off at the OS. Sending to
-- it again is a wasted request every time, forever.
create or replace function public.push_mark_gone(p_endpoint text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.push_subscriptions set gone_at = now()
   where endpoint = p_endpoint and gone_at is null;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  4. Grants
--
--  A parent may subscribe their own browser, unsubscribe it and ask about it.
--  Nobody may ask who else is subscribed: push_audience and push_mark_gone are
--  the Edge Function's, and it calls them with the service role.
-- ===========================================================================

revoke all on function public.push_subscribe(text,text,text,text) from public, anon, authenticated;
revoke all on function public.push_unsubscribe(text)              from public, anon, authenticated;
revoke all on function public.push_status(text)                   from public, anon, authenticated;
revoke all on function public.push_audience(uuid)                 from public, anon, authenticated;
revoke all on function public.push_mark_gone(text)                from public, anon, authenticated;

grant execute on function public.push_subscribe(text,text,text,text) to authenticated;
grant execute on function public.push_unsubscribe(text)              to authenticated;
grant execute on function public.push_status(text)                   to authenticated;

grant execute on function public.push_audience(uuid)  to service_role;
grant execute on function public.push_mark_gone(text) to service_role;


-- ===========================================================================
--  REMOVING THIS
--
--    drop function if exists public.push_mark_gone(text);
--    drop function if exists public.push_audience(uuid);
--    drop function if exists public.push_status(text);
--    drop function if exists public.push_unsubscribe(text);
--    drop function if exists public.push_subscribe(text,text,text,text);
--    drop table if exists public.push_subscriptions;
--
--  and delete the Edge Function and the database webhook that calls it.
--  Nothing outside these objects was changed.
-- ===========================================================================
