-- ===========================================================================
--  Registration throttle: count against the link, not a forged header
--  ---------------------------------------------------------------------------
--  Additive and idempotent. No DROP TABLE, no DELETE of real rows, no data
--  migration. Safe to run on the live project; safe to re-run.
--
--  One fix, from the read-only audit: submit_registration throttled on a
--  header the caller controls.
--
--  The audit also flagged seven functions as missing a PUBLIC revoke. That was
--  WRONG and nothing is shipped for it — migration-security-hardening.sql:96-97
--  already runs `alter default privileges ... revoke execute on functions from
--  public` plus a blanket `revoke execute on all functions`, which covers them.
--  Verified on the replica: anon has no EXECUTE on any of the seven.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. Registration throttle
--
--  The old limit counted against `split_part(x-forwarded-for, ',', 1)` — the
--  first element of a header the sender writes. Rotating that value produced a
--  fresh bucket every request, so the 6/hour ceiling never applied to anyone
--  who bothered to forge it.
--
--  Two ceilings now, and a submission has to pass both:
--
--    per link   40/hour   the token cannot be forged — a valid one is required
--                         to submit at all — so this ceiling always holds. Set
--                         high enough that a real intake evening (a class of
--                         parents signing up at once) never hits it.
--    per IP      6/hour   tighter, but only as trustworthy as the header. Kept
--                         because it still stops unsophisticated flooding.
--
--  Bucket names are now prefixed ('link:' / 'ip:'). Old unprefixed rows simply
--  stop matching, which restarts the window once — harmless.
--
--  Everything else in this function is byte-for-byte the current definition.
-- ---------------------------------------------------------------------------

create or replace function public.submit_registration(
  p_token      text,
  p_first_name text,
  p_last_name  text,
  p_phone      text default null,
  p_email      text default null,
  p_dob        date default null,
  p_group_id   uuid default null,
  p_hp         text default null      -- honeypot: must arrive empty
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_link       public.registration_links%rowtype;
  v_biz        public.businesses%rowtype;
  v_ip         text;
  v_ipbucket   text;
  v_linkbucket text;
  v_recent     int;
  v_group      uuid := null;
  v_id         uuid;
begin
  -- Honeypot. Answer as though it worked; write nothing.
  if p_hp is not null and length(btrim(p_hp)) > 0 then
    return jsonb_build_object('ok', true);
  end if;

  if p_first_name is null or length(btrim(p_first_name)) = 0
     or p_last_name is null or length(btrim(p_last_name)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  select * into v_link
    from public.registration_links
   where token = p_token and is_active
   limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invalid_link');
  end if;

  select * into v_biz from public.businesses where id = v_link.business_id;
  if not found or v_biz.approval_status <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'invalid_link');
  end if;

  v_ip := nullif(btrim(split_part(
            coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
            ',', 1)), '');
  v_linkbucket := 'link:' || v_link.token;
  v_ipbucket   := 'ip:'   || coalesce(v_ip, 'none');

  delete from public.reg_attempts where attempted_at < now() - interval '1 day';

  -- Unforgeable ceiling first: this is the one that actually holds.
  select count(*) into v_recent
    from public.reg_attempts
   where bucket = v_linkbucket and attempted_at > now() - interval '1 hour';
  if v_recent >= 40 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- Then the per-IP ceiling, which a forged header can still slip.
  select count(*) into v_recent
    from public.reg_attempts
   where bucket = v_ipbucket and attempted_at > now() - interval '1 hour';
  if v_recent >= 6 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into public.reg_attempts(bucket) values (v_linkbucket), (v_ipbucket);

  -- Never trust the submitted group.
  if v_link.group_id is not null then
    v_group := v_link.group_id;                       -- link is for one class
  elsif p_group_id is not null then
    select g.id into v_group
      from public.groups g
     where g.id = p_group_id and g.business_id = v_link.business_id;
    -- unknown or someone else's group => left null, owner assigns on approval
  end if;

  insert into public.registration_requests
    (link_id, business_id, group_id, first_name, last_name, phone, email, date_of_birth)
  values
    (v_link.id, v_link.business_id, v_group,
     btrim(p_first_name), btrim(p_last_name),
     nullif(btrim(coalesce(p_phone, '')), ''),
     nullif(btrim(coalesce(p_email, '')), ''),
     p_dob)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

revoke all on function public.submit_registration(text,text,text,text,text,date,uuid,text) from public;
grant  execute on function public.submit_registration(text,text,text,text,text,date,uuid,text) to anon, authenticated;


-- ---------------------------------------------------------------------------
--  ROLLBACK (only if needed)
--
--    Re-run migration-self-registration.sql to restore the single-bucket
--    throttle. Nothing else in this file needs undoing.
-- ---------------------------------------------------------------------------
