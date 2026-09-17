-- ===========================================================================
--  PUSH NOTIFICATIONS — the school's own side
--  ---------------------------------------------------------------------------
--  A school finds out that something is waiting on them by opening PayStamp and
--  looking: a student has signed up, a parent has ordered a jumper, somebody
--  says they have paid. The badges in the settings sheet are only visible to
--  somebody already in the app, which is the same problem the parents had.
--
--  No schema change. An owner is a signed-in person with an email, so
--  push_subscriptions already holds their subscription exactly as it holds a
--  parent's -- the column is called parent_email because parents came first,
--  but what it means is "the account this browser belongs to". Renaming it in a
--  live database would be cosmetics with downtime attached.
--
--  What is new is one function that answers "who owns this school, and what
--  should they be told", for the three things that can arrive while nobody is
--  looking.
--
--  NO BADGE, deliberately. The number on the icon is the family portal's, and
--  it means unread announcements. A second writer with a different meaning is
--  exactly the drift that made us count it in the database in the first place.
--  An owner gets the banner; the counts they already have are in the app.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  push_owner_alert -- what to say about a row, and who to say it to.
--
--  Called by the Edge Function with the table and the id the webhook carried.
--  Returns the same shape push_audience does, so the sender treats both the
--  same way.
--
--  The wording lives here, with the data, rather than in the sender: a
--  notification is read on a lock screen and its words matter more than most
--  code does.
-- ---------------------------------------------------------------------------

create or replace function public.push_owner_alert(p_table text, p_id uuid)
returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_biz   uuid;
  v_title text;
  v_body  text;
  b       public.businesses%rowtype;
begin
  if p_table = 'registration_requests' then
    select r.business_id,
           'New sign-up',
           btrim(r.first_name || ' ' || coalesce(r.last_name,'')) || ' asked to join'
      into v_biz, v_title, v_body
      from public.registration_requests r
     where r.id = p_id and r.status = 'pending';

  elsif p_table = 'shop_orders' then
    select o.business_id,
           'New order',
           c.name || ' ordered €' || trim(to_char(o.total, 'FM999990.00'))
      into v_biz, v_title, v_body
      from public.shop_orders o
      join public.cards c on c.id = o.card_id
     where o.id = p_id;

  elsif p_table = 'payment_claims' then
    select pc.business_id,
           'Payment to check',
           c.name || ' says they paid €' || trim(to_char(pc.amount, 'FM999990.00'))
      into v_biz, v_title, v_body
      from public.payment_claims pc
      join public.cards c on c.id = pc.card_id
     where pc.id = p_id and pc.status = 'pending';

  else
    return jsonb_build_object('error','unknown_table');
  end if;

  -- The row is gone, or was never in a state worth mentioning. Not a failure:
  -- there is simply nobody to tell.
  if v_biz is null then return jsonb_build_object('error','nothing_to_say'); end if;

  select * into b from public.businesses where id = v_biz;
  if not found then return jsonb_build_object('error','no_business'); end if;

  -- A school waiting to be approved cannot see its own dashboard, so telling
  -- it about an order would be telling it about something it cannot open.
  if b.approval_status <> 'approved' then
    return jsonb_build_object('error','not_approved');
  end if;

  return jsonb_build_object(
    'ok', true,
    'title', b.name,
    'body', v_title || ' · ' || v_body,
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
        from public.push_subscriptions s
        join auth.users u on u.email = s.parent_email
       where s.gone_at is null
         and s.parent_email is not null
         and u.id = b.owner_id
    ), '[]'::jsonb));
end;
$$;


-- Only the sender may ask. The answer is a list of endpoints, and an endpoint
-- is a capability to make somebody's phone buzz.
revoke all on function public.push_owner_alert(text,uuid) from public, anon, authenticated;
grant execute on function public.push_owner_alert(text,uuid) to service_role;


-- ===========================================================================
--  REMOVING THIS
--
--    drop function if exists public.push_owner_alert(text,uuid);
--
--  and delete the push-owner-alert Edge Function and its three webhooks.
--  Nothing else was added or altered; an owner's subscription row is an
--  ordinary one and stops being used the moment nothing asks for it.
-- ===========================================================================
