-- ===========================================================================
--  PUSH NOTIFICATIONS — the number on the app icon
--  ---------------------------------------------------------------------------
--  "the notification came great but why doesn't it show 1 as a notification on
--   the home page icon like StoryReel has 197?"
--
--  Because nothing was setting it. A notification and a badge are two separate
--  things: showNotification() puts the banner on the lock screen, and
--  navigator.setAppBadge() puts the number on the icon. An installed web app
--  can do both, and until now this did only the first.
--
--  The number has to be that parent's unread count, not "how many pushes we
--  sent" -- a badge that disagrees with what is inside the app is worse than
--  no badge. So it is counted here, from the same two tables the portal reads,
--  and carried in the push payload per subscription.
--
--  This redefines push_audience only. No table is added or altered.
-- ===========================================================================


-- How many announcements this parent has not read, by the portal's own rules:
-- every note from a school they have a card at, targeted at the whole school,
-- that child's class, or that child; minus the ones they have opened.
--
-- announcement_reads is keyed on auth.uid() and push_subscriptions on email,
-- so auth.users is the join between them.
create or replace function public.push_unread_count(p_email text)
returns int
language sql security definer stable set search_path = public as $$
  select count(*)::int
    from public.announcements a
   where a.is_active
     and (a.expires_at is null or a.expires_at > now())
     and exists (
       select 1
         from public.card_links cl
         join public.cards c on c.id = cl.card_id
        where cl.parent_email = p_email
          and c.business_id = a.business_id
          and (a.card_id  is null or c.id       = a.card_id)
          and (a.group_id is null or c.group_id = a.group_id))
     and not exists (
       select 1
         from public.announcement_reads r
         join auth.users u on u.id = r.parent_id
        where r.announcement_id = a.id and u.email = p_email);
$$;


-- Same as before, with `badge` on each subscription: what that parent's icon
-- should read once this notification lands.
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
      select jsonb_agg(jsonb_build_object(
               'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
               'badge', public.push_unread_count(s.parent_email)))
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


-- The count is per person, so nobody but the sender may ask for it.
revoke all on function public.push_unread_count(text) from public, anon, authenticated;
grant execute on function public.push_unread_count(text) to service_role;

revoke all on function public.push_audience(uuid) from public, anon, authenticated;
grant execute on function public.push_audience(uuid) to service_role;


-- ===========================================================================
--  REMOVING THIS
--
--  Re-run the push_audience definition from migration-push.sql, then:
--    drop function if exists public.push_unread_count(text);
-- ===========================================================================
