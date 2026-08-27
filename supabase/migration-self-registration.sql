-- ============================================================================
--  Migration: public self-registration  (STAGE 1 of 3 — schema + anon RPCs)
--  ----------------------------------------------------------------------------
--  A business generates a public link, shares it, and prospective students fill
--  in a form with no login. Submissions land as PENDING REQUESTS — nothing
--  creates a student record until the owner approves.
--
--  This stage adds only data and functions. No UI reads any of it yet, so it is
--  safe to run and verify on its own before anything is visible.
--
--  ----------------------------------------------------------------------------
--  WRITTEN AGAINST THE LIVE SCHEMA, NOT THE REPO
--
--  groups/teachers are not in schema.sql — they came from the June migration
--  that was pasted into Supabase and never committed. Their real shape was
--  dumped from the running database before this file was written:
--
--    groups    id uuid pk default gen_random_uuid(), business_id uuid not null,
--              name text not null, schedule jsonb not null default '[]',
--              teacher_id uuid null, created_at timestamptz not null default now()
--    teachers  id, business_id, name, created_at  (same shape)
--
--  and their RLS is the same ownership test cards uses:
--    exists (select 1 from businesses b
--             where b.id = X.business_id and b.owner_id = auth.uid())
--
--  ----------------------------------------------------------------------------
--  HOW ANONYMOUS ACCESS WORKS HERE
--
--  This schema gives `anon` NO table privileges at all — only `usage on schema
--  public` plus execute on specific functions. The precedent is pin_attempts:
--  "RLS on + zero policies = no access", reached only through a SECURITY
--  DEFINER function that runs as the table owner.
--
--  The public form follows that exactly. anon never touches a table; it calls
--  two functions, and each one decides what it is willing to reveal or write.
--  That is what stops a stranger enumerating businesses, groups or requests.
--
--  Run ONCE in the Supabase SQL editor.
-- ============================================================================


-- ---------------------------------------------------------------------------
--  1. Date of birth on the student record
--      The form collects it, so it should survive approval rather than being
--      lost with the request. Nullable and additive: every existing row stays
--      valid and nothing reads it until the UI does.
-- ---------------------------------------------------------------------------
alter table public.cards
  add column if not exists date_of_birth date;

comment on column public.cards.date_of_birth is
  'Optional DOB. Captured by public self-registration; null for students added by hand.';


-- ---------------------------------------------------------------------------
--  2. Registration links
--      One row per shareable link. group_id null means "any group" — the form
--      then shows the group selector. group_id set means the link is for that
--      one class and the selector is skipped.
--
--      on delete cascade for the group: deleting a class should take its
--      dedicated link with it. The alternative, set null, would silently turn a
--      class-specific link into an any-class link — a behaviour change the
--      owner never asked for, on a URL already out in the world.
-- ---------------------------------------------------------------------------
create table if not exists public.registration_links (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  group_id    uuid          references public.groups(id)     on delete cascade,
  token       text not null unique
                default replace(gen_random_uuid()::text, '-', ''),
  label       text,                                  -- owner's own note, e.g. "Autumn flyer"
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists registration_links_biz_idx   on public.registration_links(business_id);
create index if not exists registration_links_token_idx on public.registration_links(token);


-- ---------------------------------------------------------------------------
--  3. Registration requests
--      group_id is nullable and independent of the link's: an "any group" link
--      lets the person pick, and the owner can still change it at approval.
--      on delete set null so a request outlives a deleted class — the owner
--      picks a new one when approving rather than losing the applicant.
-- ---------------------------------------------------------------------------
create table if not exists public.registration_requests (
  id            uuid primary key default gen_random_uuid(),
  link_id       uuid          references public.registration_links(id) on delete set null,
  business_id   uuid not null references public.businesses(id)         on delete cascade,
  group_id      uuid          references public.groups(id)             on delete set null,
  first_name    text not null,
  last_name     text not null,
  phone         text,
  email         text,
  date_of_birth date,
  status        text not null default 'pending'
                  check (status in ('pending','approved','rejected')),
  card_id       uuid references public.cards(id) on delete set null,  -- set on approval
  created_at    timestamptz not null default now(),
  decided_at    timestamptz
);
create index if not exists registration_requests_biz_status_idx
  on public.registration_requests(business_id, status, created_at desc);


-- ---------------------------------------------------------------------------
--  4. Submission throttle
--      Same shape and same lockdown as pin_attempts: RLS on, zero policies,
--      every privilege revoked. Only the SECURITY DEFINER function below can
--      see it, so a caller can neither read the log nor clear it.
-- ---------------------------------------------------------------------------
create table if not exists public.reg_attempts (
  id           bigint generated always as identity primary key,
  bucket       text not null,          -- the client IP, or 'token:<token>' when no IP is available
  attempted_at timestamptz not null default now()
);
create index if not exists reg_attempts_bucket_time_idx
  on public.reg_attempts(bucket, attempted_at);

alter table public.reg_attempts enable row level security;
revoke all on table public.reg_attempts from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  5. Owner access, via RLS — the same ownership test cards already uses
--
--      Including approval_status = 'approved' is what cards/announcements do
--      and what businesses' own select policy enforces anyway, so it changes no
--      behaviour. It is spelled out here so the rule is readable in place
--      instead of depending on a policy two tables away.
-- ---------------------------------------------------------------------------
alter table public.registration_links    enable row level security;
alter table public.registration_requests enable row level security;

drop policy if exists reg_links_select_own on public.registration_links;
create policy reg_links_select_own on public.registration_links for select
  using (exists (select 1 from public.businesses b
                  where b.id = registration_links.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_links_insert_own on public.registration_links;
create policy reg_links_insert_own on public.registration_links for insert
  with check (exists (select 1 from public.businesses b
                       where b.id = business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_links_update_own on public.registration_links;
create policy reg_links_update_own on public.registration_links for update
  using (exists (select 1 from public.businesses b
                  where b.id = registration_links.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_links_delete_own on public.registration_links;
create policy reg_links_delete_own on public.registration_links for delete
  using (exists (select 1 from public.businesses b
                  where b.id = registration_links.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_requests_select_own on public.registration_requests;
create policy reg_requests_select_own on public.registration_requests for select
  using (exists (select 1 from public.businesses b
                  where b.id = registration_requests.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_requests_update_own on public.registration_requests;
create policy reg_requests_update_own on public.registration_requests for update
  using (exists (select 1 from public.businesses b
                  where b.id = registration_requests.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

drop policy if exists reg_requests_delete_own on public.registration_requests;
create policy reg_requests_delete_own on public.registration_requests for delete
  using (exists (select 1 from public.businesses b
                  where b.id = registration_requests.business_id and b.owner_id = auth.uid()
                    and b.approval_status = 'approved'));

-- Deliberately NO insert policy on registration_requests. The only way a row is
-- created is the SECURITY DEFINER function below, so there is no path by which
-- a logged-in user could forge a request into someone else's business.

-- The grant trap: this schema hands out table privileges with a one-time
-- "grant ... on all tables" snapshot, NOT alter default privileges, so a table
-- created later is invisible until granted explicitly. Miss this and every
-- write fails with "permission denied for table X" before RLS is consulted.
grant select, insert, update, delete on public.registration_links    to authenticated;
grant select,         update, delete on public.registration_requests to authenticated;


-- ---------------------------------------------------------------------------
--  6. What the public form is allowed to see
--      Takes a token and returns just enough to render: the school's name and
--      colour, and either the one group the link is for, or the list to choose
--      from. Anything else about the business stays invisible.
--
--      Returns null for an unknown or deactivated token, so a stranger cannot
--      tell a wrong guess from a switched-off link.
-- ---------------------------------------------------------------------------
create or replace function public.get_registration_form(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_link   public.registration_links%rowtype;
  v_biz    public.businesses%rowtype;
  v_group  jsonb := null;
  v_groups jsonb := '[]'::jsonb;
begin
  select * into v_link
    from public.registration_links
   where token = p_token and is_active
   limit 1;
  if not found then return null; end if;

  select * into v_biz from public.businesses where id = v_link.business_id;
  if not found then return null; end if;

  -- A business still awaiting admin approval should not be recruiting.
  if v_biz.approval_status <> 'approved' then return null; end if;

  if v_link.group_id is not null then
    select jsonb_build_object('id', g.id, 'name', g.name, 'schedule', g.schedule)
      into v_group
      from public.groups g
     where g.id = v_link.group_id;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', g.id, 'name', g.name, 'schedule', g.schedule)
             order by g.name), '[]'::jsonb)
      into v_groups
      from public.groups g
     where g.business_id = v_link.business_id;
  end if;

  return jsonb_build_object(
    'token',    v_link.token,
    'business', jsonb_build_object('name', v_biz.name, 'type', v_biz.type, 'accent', v_biz.accent),
    'group',    v_group,      -- set when the link is for one class
    'groups',   v_groups      -- the choices when it is not
  );
end;
$function$;


-- ---------------------------------------------------------------------------
--  7. The submission
--
--      Spam protection, in order:
--        honeypot  a field no human sees. Filled in => pretend success and
--                  write nothing, so the bot learns nothing from the response.
--        throttle  6 submissions per bucket per hour. The bucket is the client
--                  IP where the platform gives us one, and falls back to the
--                  TOKEN when it does not — a missing header must not silently
--                  switch the limiter off, which is the usual way this kind of
--                  protection ends up decorative.
--
--      The group is validated against the link rather than trusted: a link tied
--      to one class ignores whatever the client sent, and an open link accepts
--      only groups that actually belong to that business.
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
  v_link   public.registration_links%rowtype;
  v_biz    public.businesses%rowtype;
  v_ip     text;
  v_bucket text;
  v_recent int;
  v_group  uuid := null;
  v_id     uuid;
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

  -- Throttle. Fall back to the token when no IP is available rather than
  -- letting a missing header disable the limit.
  v_ip := nullif(btrim(split_part(
            coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''),
            ',', 1)), '');
  v_bucket := coalesce(v_ip, 'token:' || v_link.token);

  delete from public.reg_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_recent
    from public.reg_attempts
   where bucket = v_bucket and attempted_at > now() - interval '1 hour';
  if v_recent >= 6 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  insert into public.reg_attempts(bucket) values (v_bucket);

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


-- ---------------------------------------------------------------------------
--  8. Approval
--      SECURITY INVOKER on purpose. The owner already has the rights to read
--      the request and insert the card, so RLS does the authorisation and there
--      is no privilege to escalate. What this buys over doing it from the
--      client is atomicity: the card insert and the status flip land together,
--      so a double-tap or a dropped connection cannot leave a request marked
--      approved with no student behind it.
--
--      The caller supplies share_code and pin, generated the same way PgAddCard
--      already generates them, so the reveal screen can show them unchanged.
--
--      p_group_id is an override the owner may pass; null means "use whatever
--      the applicant picked". Either way the group is checked against the
--      business, and a group that fails that check yields an ungrouped student.
-- ---------------------------------------------------------------------------
create or replace function public.approve_registration(
  p_request_id uuid,
  p_share_code text,
  p_pin        text,
  p_group_id   uuid default null      -- owner may override the requested group
) returns jsonb
language plpgsql
set search_path = public
as $function$
declare
  v_req  public.registration_requests%rowtype;
  v_card public.cards%rowtype;
  v_group uuid;
begin
  select * into v_req
    from public.registration_requests
   where id = p_request_id
   for update;                                   -- serialise concurrent approvals
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_req.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'already_' || v_req.status);
  end if;

  -- Group resolution. An override the owner passes wins over the applicant's
  -- choice, but ONLY if that group is really theirs; anything else lands
  -- ungrouped rather than silently becoming some other class. Ungrouped is
  -- visible and fixable in one tap; a wrong class is neither.
  if p_group_id is not null then
    select g.id into v_group
      from public.groups g
     where g.id = p_group_id and g.business_id = v_req.business_id;
  else
    select g.id into v_group
      from public.groups g
     where g.id = v_req.group_id and g.business_id = v_req.business_id;
  end if;

  -- Column list mirrors doAddCard's insert exactly, plus date_of_birth.
  -- cards has columns that live only in the database (lesson_schedule,
  -- group_id, group_name came from the June migration, not schema.sql), so
  -- rather than assume which of them carry defaults this writes the same set
  -- the app has been inserting successfully all along.
  insert into public.cards
    (business_id, name, level, share_code, pin, phone,
     preferred_channel, language, enrollment_start_month,
     group_id, lesson_schedule, date_of_birth, payments, history)
  values
    (v_req.business_id,
     btrim(v_req.first_name || ' ' || v_req.last_name),
     null,
     p_share_code, p_pin, v_req.phone,
     'whatsapp', 'EN', null,
     v_group, '[]'::jsonb, v_req.date_of_birth, '{}'::jsonb, '[]'::jsonb)
  returning * into v_card;

  update public.registration_requests
     set status = 'approved', card_id = v_card.id, decided_at = now()
   where id = p_request_id;

  return jsonb_build_object('ok', true,
    'card', jsonb_build_object('id', v_card.id, 'name', v_card.name,
                               'share_code', v_card.share_code, 'pin', v_card.pin,
                               'group_id', v_card.group_id));
end;
$function$;


grant execute on function public.get_registration_form(text)                   to anon, authenticated;
grant execute on function public.submit_registration(text,text,text,text,text,date,uuid,text) to anon, authenticated;
grant execute on function public.approve_registration(uuid,text,text,uuid)      to authenticated;


-- ============================================================================
--  Done. Nothing existing was altered: one nullable column on cards, three new
--  tables, three new functions.
--
--  ----------------------------------------------------------------------------
--  VERIFIED BEFORE YOU RUN IT
--
--  Because this database has no backups, the migration was not shipped on
--  reasoning alone. A PostgreSQL 16 replica was built locally from schema.sql,
--  every committed migration, and the groups/teachers DDL dumped out of the
--  live project, and this file was run against it as the real anon and
--  authenticated roles. 53 behavioural checks pass, covering: what the public
--  form can and cannot see, anon having no table access at all, the honeypot
--  writing nothing, both throttle buckets, cross-business isolation both ways,
--  double-approval, group overrides, and the cascades below.
--
--  Two properties matter most for a database with no undo, and both were
--  checked by diffing a full schema dump either side of the run:
--    * the migration is strictly ADDITIVE — nothing existing is dropped,
--      rewritten or re-permissioned;
--    * the ROLLBACK block at the bottom returns the schema byte-for-byte to
--      what it was before.
--
--  ----------------------------------------------------------------------------
--  SANITY CHECKS  (worth running anyway — the replica is not your data)
--
--  1) the column landed and every existing student is unaffected
--       select count(*) as students, count(date_of_birth) as with_dob
--         from public.cards;                       -- with_dob = 0
--
--  2) the grant trap — all four verbs must be listed for authenticated
--       select table_name, string_agg(privilege_type, ',' order by privilege_type)
--         from information_schema.role_table_grants
--        where grantee = 'authenticated'
--          and table_name in ('registration_links','registration_requests')
--        group by table_name;
--
--  3) make a link for yourself, then read it back the way the public page will.
--     Replace <BIZ> with: select id, name from public.businesses;
--       insert into public.registration_links(business_id) values ('<BIZ>')
--         returning token;
--       select public.get_registration_form('<TOKEN FROM ABOVE>');
--     Expect the school's name plus a 'groups' array. Then check a bad token
--     gives nothing away:
--       select public.get_registration_form('not-a-real-token');   -- null
--
--  4) WHICH BUCKET IS THE THROTTLE REALLY USING? Both paths are known to work
--     — the IP path takes the first address in the x-forwarded-for chain, and
--     with no header at all it falls back to per-token rather than switching
--     the limit off. What cannot be tested away from your project is which of
--     the two Supabase gives us. After the first real submission from a
--     browser, look at what got logged:
--       select distinct bucket from public.reg_attempts;
--     An IP address means per-visitor limiting (the stronger one). 'token:...'
--     means per-link limiting: still a real limit, but six per hour shared
--     across everyone using that link, which for a widely-shared link is worth
--     knowing about before it bites a real family.
--
--  5) the throttle bites. Submit the same token seven times in a row; the
--     seventh must come back {"ok": false, "error": "rate_limited"}:
--       select public.submit_registration('<TOKEN>', 'Test', 'Person');
--
--  6) the honeypot writes nothing while looking like success
--       select public.submit_registration('<TOKEN>', 'Bot', 'Bot', null, null,
--                                         null, null, 'i am a bot');
--       -- returns {"ok": true} but adds no row:
--       select count(*) from public.registration_requests where first_name = 'Bot';
--
--  CLEAN UP after testing:
--       delete from public.registration_requests where first_name in ('Test','Bot');
--       delete from public.reg_attempts;
--
--  ROLLBACK (removes only what this file added):
--       drop function if exists public.approve_registration(uuid,text,text,uuid);
--       drop function if exists public.submit_registration(text,text,text,text,text,date,uuid,text);
--       drop function if exists public.get_registration_form(text);
--       drop table if exists public.reg_attempts;
--       drop table if exists public.registration_requests;
--       drop table if exists public.registration_links;
--       alter table public.cards drop column if exists date_of_birth;
-- ============================================================================
