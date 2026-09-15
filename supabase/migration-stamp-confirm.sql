-- ===========================================================================
--  Trigger-agnostic payment confirmation  (NFC / QR / stamp)
--  -------------------------------------------------------------------------
--  A parent taps their phone on the school's tag, or scans the QR on the
--  owner's screen, and the payment they just handed over in cash is recorded.
--
--  The whole design turns on one constraint: a parent has NO write access to
--  public.cards. Row-level security restricts that table to the owning
--  business, and that is not negotiable -- it is the wall between schools.
--  So every step here is a security-definer function, and crucially
--  stamp_confirm() COMPUTES THE PAYMENT ITSELF. It never accepts a payments
--  blob from the browser. If it did, one tap would let a parent post a
--  whole year as paid, and the physical tag would be protecting nothing.
--
--  That is why calc_breakdown below is a port of calcBreakdown() from the
--  app rather than a call into it. The two have to agree; the test suite
--  (supabase/test/test-stamp-confirm.sql) pins the arithmetic.
--
--  Additive and idempotent. Two new tables, two new columns on businesses,
--  no data migration. Safe to run on the live project; safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. Business settings
--
--  require_pin_on_confirm defaults OFF, so running this file changes nothing
--  about how the app behaves until an owner turns it on.
--
--  confirm_pin is a NEW secret, not the student PIN and not the login
--  password. Student PINs are deliberately plain-text shareable codes; this
--  one gates recording money, so it is the owner's alone. It lives on
--  businesses, which parents cannot select at all (their only read path is
--  get_my_cards, a definer function that never returns it).
-- ---------------------------------------------------------------------------

alter table public.businesses
  add column if not exists require_pin_on_confirm boolean not null default false;
alter table public.businesses
  add column if not exists confirm_pin text;

-- The student-limit migration revoked table-level UPDATE and reissued it over
-- named columns. Whether or not that has run, these two columns are set
-- through set_confirm_settings() below rather than by a direct update, so
-- they are deliberately NOT added to that grant: the function validates that
-- a PIN exists before the requirement can be switched on.


-- ---------------------------------------------------------------------------
--  2. Tokens
--
--  One secret per business, revocable and regenerable. A separate table
--  rather than a column on businesses for two reasons: the token must be
--  resolvable by a parent who cannot read the businesses row at all, and
--  revoking has to leave a trail rather than overwrite one.
--
--  The partial unique index is what enforces "one active token": a second
--  live row for the same business cannot exist. Rotation therefore has to
--  revoke before it inserts, and does.
-- ---------------------------------------------------------------------------

create table if not exists public.stamp_tokens (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  token       text not null unique,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz
);

create unique index if not exists stamp_tokens_one_active
  on public.stamp_tokens(business_id) where revoked_at is null;

alter table public.stamp_tokens enable row level security;
revoke all on table public.stamp_tokens from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  3. Confirmation sessions
--
--  Created by stamp_begin, spent by stamp_confirm, valid for 60 seconds and
--  once only. Holding the tag against a phone is the authorisation; this row
--  is what stops that authorisation being replayed after the phone has left
--  the counter.
--
--  pin_fails exists because the PIN check has to happen BEFORE the session is
--  spent -- an owner who fat-fingers their own PIN should get another go, not
--  be told to tap again. Three wrong tries burns the session, which caps the
--  brute force at three guesses per physical tap.
-- ---------------------------------------------------------------------------

create table if not exists public.stamp_confirmations (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  parent_email   text not null,
  trigger_source text not null check (trigger_source in ('nfc','qr','stamp')),
  pin_fails      int  not null default 0,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  used_at        timestamptz
);

create index if not exists stamp_confirmations_email_idx
  on public.stamp_confirmations(parent_email, created_at desc);

alter table public.stamp_confirmations enable row level security;
revoke all on table public.stamp_confirmations from public, anon, authenticated;


-- ===========================================================================
--  4. The payment arithmetic, ported from the app
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  fee_for_month -- feeForMonth() in app/index.html.
--
--  fee_history is [{from:<0-11>, fee:<num>}]. The fee in force for month mi is
--  the latest period starting at or before mi; before the first period, the
--  earliest one applies. With no history at all, the level's fee wins over the
--  business default.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_fee_for_month(
  p_level jsonb, p_fee_history jsonb, p_biz_fee numeric, p_mi int)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  v_base     numeric;
  v_best     jsonb := null;
  v_earliest jsonb := null;
  r          jsonb;
begin
  v_base := coalesce((p_level->>'fee')::numeric, p_biz_fee);

  if p_fee_history is null or jsonb_array_length(p_fee_history) = 0 then
    return v_base;
  end if;

  for r in select jsonb_array_elements(p_fee_history) loop
    if v_earliest is null or (r->>'from')::int < (v_earliest->>'from')::int then
      v_earliest := r;
    end if;
    if (r->>'from')::int <= p_mi
       and (v_best is null or (r->>'from')::int > (v_best->>'from')::int) then
      v_best := r;
    end if;
  end loop;

  return (coalesce(v_best, v_earliest)->>'fee')::numeric;
end;
$$;


-- ---------------------------------------------------------------------------
--  calc_breakdown -- calcBreakdown() in app/index.html.
--
--  Spreads an amount over the unpaid billable months of a year, earliest
--  first. Returns one row per month it touches, in month order.
--
--  The 0.01 thresholds and the two-decimal rounding are the JS function's,
--  kept identical on purpose: the same payment has to land the same way
--  whether the owner typed it into the dashboard or a parent tapped a tag.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_calc_breakdown(
  p_payments   jsonb,
  p_amount     numeric,
  p_year       int,
  p_skip       int[],      -- business inactive_months + card paused_months
  p_enroll     text,       -- 'YYYY-MM' or null
  p_level      jsonb,
  p_fee_history jsonb,
  p_biz_fee    numeric)
returns table (mi int, applying numeric, new_total numeric, full_month boolean, fee numeric)
language plpgsql
stable
set search_path = public
as $$
declare
  v_rem     numeric := round(coalesce(p_amount,0), 2);
  v_ym      text;
  v_p       jsonb;
  v_fee     numeric;
  v_already numeric;
  v_owed    numeric;
  v_apply   numeric;
  v_new     numeric;
  i         int;
begin
  for i in 0..11 loop
    exit when v_rem < 0.01;

    if p_skip is not null and i = any(p_skip) then continue; end if;

    v_ym := p_year::text || '-' || lpad((i+1)::text, 2, '0');
    if p_enroll is not null and v_ym < p_enroll then continue; end if;

    v_p := coalesce(p_payments -> v_ym, '{}'::jsonb);
    if coalesce((v_p->>'paid')::boolean, false) then continue; end if;

    v_fee     := public.stamp_fee_for_month(p_level, p_fee_history, p_biz_fee, i);
    v_already := round(coalesce((v_p->>'amount')::numeric, 0), 2);
    v_owed    := round(v_fee - v_already, 2);
    if v_owed < 0.01 then continue; end if;

    v_apply := round(least(v_rem, v_owed), 2);
    v_rem   := round(v_rem - v_apply, 2);
    v_new   := round(v_already + v_apply, 2);

    mi         := i;
    applying   := v_apply;
    new_total  := v_new;
    full_month := v_new >= v_fee - 0.01;
    fee        := v_fee;
    return next;
  end loop;
end;
$$;


-- ===========================================================================
--  5. Owner-side: managing the token and the settings
-- ===========================================================================

-- URL-safe 24-character secret. base64 of 18 random bytes, with the two
-- characters that would need escaping in a URL swapped out.
--
-- search_path includes `extensions` because gen_random_bytes belongs to
-- pgcrypto, and Supabase installs pgcrypto into its own `extensions` schema
-- rather than into public. Pinned to public alone this raises
-- "function gen_random_bytes(integer) does not exist" on the live project
-- while passing anywhere pgcrypto happens to sit in public. gen_random_uuid()
-- is unaffected -- that one is core Postgres, not pgcrypto, which is why the
-- tables built fine and only this failed.
--
-- A schema named in search_path that does not exist is ignored rather than an
-- error, so this is correct on both layouts.
create or replace function public.stamp_new_token_value()
returns text
language sql
volatile
set search_path = public, extensions
as $$
  select replace(replace(encode(gen_random_bytes(18), 'base64'), '/', '_'), '+', '-');
$$;


-- ---------------------------------------------------------------------------
--  stamp_token_get -- the caller's own active token, creating one on first
--  use so an owner never has to think about "generating" anything.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_token_get()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz   public.businesses%rowtype;
  v_token text;
  v_made  timestamptz;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('error', 'no_business');
  end if;

  select token, created_at into v_token, v_made
    from public.stamp_tokens
   where business_id = v_biz.id and revoked_at is null
   limit 1;

  if v_token is null then
    v_token := public.stamp_new_token_value();
    insert into public.stamp_tokens(business_id, token) values (v_biz.id, v_token)
      returning created_at into v_made;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'created_at', v_made,
    'require_pin', v_biz.require_pin_on_confirm,
    'pin_set', v_biz.confirm_pin is not null);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_token_rotate -- revoke the current token and issue a new one.
--  The old URL stops resolving the instant this returns, which is the point:
--  it is what an owner does when a tag goes missing.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_token_rotate()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz   public.businesses%rowtype;
  v_token text;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('error', 'no_business');
  end if;

  update public.stamp_tokens set revoked_at = now()
   where business_id = v_biz.id and revoked_at is null;

  v_token := public.stamp_new_token_value();
  insert into public.stamp_tokens(business_id, token) values (v_biz.id, v_token);

  return jsonb_build_object('ok', true, 'token', v_token);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_token_revoke -- turn the feature off entirely. No active token means
--  every tag and every QR for this business resolves to nothing.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_token_revoke()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz public.businesses%rowtype;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('error', 'no_business');
  end if;

  update public.stamp_tokens set revoked_at = now()
   where business_id = v_biz.id and revoked_at is null;

  return jsonb_build_object('ok', true);
end;
$$;


-- ---------------------------------------------------------------------------
--  set_confirm_settings -- the PIN requirement and the PIN itself.
--
--  Passing p_pin = null leaves the stored PIN alone, so an owner can toggle
--  the requirement without retyping it. The requirement cannot be switched on
--  while no PIN exists -- otherwise the toggle would lock the owner out of
--  their own confirmations.
-- ---------------------------------------------------------------------------

create or replace function public.set_confirm_settings(
  p_require boolean, p_pin text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz public.businesses%rowtype;
  v_pin text;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then
    return jsonb_build_object('error', 'no_business');
  end if;

  v_pin := v_biz.confirm_pin;

  if p_pin is not null then
    if p_pin = '' then
      v_pin := null;
    elsif p_pin !~ '^[0-9]{4,8}$' then
      return jsonb_build_object('error', 'bad_pin');
    else
      v_pin := p_pin;
    end if;
  end if;

  if p_require and v_pin is null then
    return jsonb_build_object('error', 'pin_required');
  end if;

  update public.businesses
     set require_pin_on_confirm = p_require,
         confirm_pin            = v_pin
   where id = v_biz.id;

  return jsonb_build_object('ok', true, 'require_pin', p_require, 'pin_set', v_pin is not null);
end;
$$;


-- ===========================================================================
--  6. The QR nonce
--
--  The QR on the owner's screen carries a code derived from the token and the
--  current 30-second bucket, so the picture changes twice a minute. The server
--  recomputes it rather than storing it, which is why this needs no table and
--  no round trip to rotate.
--
--  Honest about what it buys: the same token also works bare over NFC, so a
--  rotating QR does not make the token itself harder to misuse. What it does
--  do is let the server tell a scan from a tap WITHOUT trusting the browser
--  to say which it was -- that is where trigger_source 'qr' comes from.
--  One bucket of slack either side covers ordinary clock drift.
-- ===========================================================================

-- hmac() is pgcrypto too; same reason for `extensions` on the search_path.
create or replace function public.stamp_nonce_for(p_token text, p_bucket bigint)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select substring(encode(hmac(p_bucket::text, p_token, 'sha256'), 'hex') from 1 for 10);
$$;

create or replace function public.stamp_nonce_valid(p_token text, p_nonce text)
returns boolean
language plpgsql
stable
set search_path = public
as $$
declare
  v_bucket bigint := floor(extract(epoch from now()) / 30)::bigint;
begin
  if p_nonce is null or p_nonce = '' then return false; end if;
  return p_nonce in (
    public.stamp_nonce_for(p_token, v_bucket),
    public.stamp_nonce_for(p_token, v_bucket - 1),
    public.stamp_nonce_for(p_token, v_bucket + 1));
end;
$$;


-- ===========================================================================
--  7. stamp_begin -- resolve the token, decide who is holding the phone
-- ===========================================================================
--
--  Four outcomes, and which one you get is the whole access-control story:
--
--    not_authenticated -- the caller has no session. The page sends them to
--                         log in and comes back; the token survives in
--                         sessionStorage, not in the URL.
--    owner             -- this is the school's own device. Nothing is
--                         recorded. An owner tapping their own tag is testing
--                         it, not paying themselves.
--    no_match          -- deliberately the SAME answer for "no such token",
--                         "revoked token" and "you are not a customer of this
--                         school". Splitting them would turn the endpoint
--                         into an oracle for guessing tokens.
--    ok                -- a real parent of a real student here. A 60-second
--                         single-use session is opened and returned.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_begin(p_token text, p_nonce text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email   text := auth.email();
  v_uid     uuid := auth.uid();
  v_tok     public.stamp_tokens%rowtype;
  v_biz     public.businesses%rowtype;
  v_trigger text;
  v_conf    uuid;
  v_exp     timestamptz;
  v_year    int;
  v_students jsonb := '[]'::jsonb;
  r         record;
  v_first   record;
  v_skip    int[];
  v_amt     numeric;
  v_label   text;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  select * into v_tok from public.stamp_tokens
   where token = p_token and revoked_at is null limit 1;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  select * into v_biz from public.businesses where id = v_tok.business_id;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  -- The owner's own device. Recording nothing is the correct behaviour, not a
  -- refusal: the tag works, and saying so is the useful answer.
  if v_biz.owner_id = v_uid then
    return jsonb_build_object('owner', true, 'business_name', v_biz.name);
  end if;

  v_year := v_biz.year;

  -- Housekeeping, cheap and bounded: spent and stale sessions are of no
  -- further use to anybody.
  delete from public.stamp_confirmations where created_at < now() - interval '1 day';

  v_trigger := case when public.stamp_nonce_valid(p_token, p_nonce) then 'qr' else 'nfc' end;

  for r in
    select c.id, c.name, c.level, c.payments, c.fee_history,
           c.enrollment_start_month, c.paused_months
      from public.card_links cl
      join public.cards c on c.id = cl.card_id
     where cl.parent_email = v_email
       and c.business_id   = v_biz.id
     order by c.name
  loop
    -- The suggested amount is what this student owes for the earliest month
    -- still outstanding -- their fee for that month, less anything already
    -- part-paid. It is a starting point in an editable field, not a figure
    -- anybody is held to.
    v_skip := (
      select coalesce(array_agg(x::int), '{}')
        from (
          select jsonb_array_elements_text(coalesce(v_biz.inactive_months, '[]'::jsonb)) as x
          union all
          select jsonb_array_elements_text(coalesce(r.paused_months, '[]'::jsonb))
        ) s);

    -- An absurd amount makes the breakdown enumerate every month still owing;
    -- the first row is the earliest, and its `applying` is exactly what that
    -- month is short. No second lookup needed.
    select b.mi, b.applying
      into v_first
      from public.stamp_calc_breakdown(
             coalesce(r.payments,'{}'::jsonb), 999999, v_year, v_skip,
             r.enrollment_start_month, r.level, r.fee_history, v_biz.fee) b
     order by b.mi limit 1;

    if not found then
      v_amt := 0; v_label := null;
    else
      v_amt   := greatest(v_first.applying, 0);
      v_label := (array['January','February','March','April','May','June','July',
                        'August','September','October','November','December'])[v_first.mi + 1];
    end if;

    v_students := v_students || jsonb_build_object(
      'card_id', r.id,
      'name',    r.name,
      'amount',  v_amt,
      'month',   v_label);
  end loop;

  if jsonb_array_length(v_students) = 0 then
    return jsonb_build_object('error', 'no_match');
  end if;

  v_exp := now() + interval '60 seconds';
  insert into public.stamp_confirmations(business_id, parent_email, trigger_source, expires_at)
    values (v_biz.id, v_email, v_trigger, v_exp)
    returning id into v_conf;

  return jsonb_build_object(
    'ok',            true,
    'confirmation',  v_conf,
    'expires_at',    v_exp,
    'trigger',       v_trigger,
    'require_pin',   v_biz.require_pin_on_confirm,
    'business_name', v_biz.name,
    -- type/accent/icon are what bizPal() needs to colour the page in the
    -- school's own palette. accent is a theme NAME, not a colour, so it is
    -- fed through bizPal rather than into --accent directly.
    'type',          v_biz.type,
    'accent',        v_biz.accent,
    'icon',          v_biz.icon,
    'year',          v_year,
    'students',      v_students);
end;
$$;


-- ===========================================================================
--  8. stamp_confirm -- spend the session and write the payment
-- ===========================================================================
--
--  Order matters here and is deliberate:
--
--    1. Load the session WITHOUT spending it, and check it is the caller's,
--       unspent and unexpired.
--    2. Check the PIN. A wrong PIN must not cost the owner the session, so
--       this happens first; three wrong tries burn it.
--    3. Spend the session with a conditional UPDATE. Two taps racing each
--       other both reach this line; exactly one updates a row, and the other
--       gets nothing back and stops. That -- not a prior SELECT -- is what
--       makes it single-use.
--    4. Only then compute and write the payment.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_confirm(
  p_confirmation uuid,
  p_card_id      uuid,
  p_amount       numeric,
  p_pin          text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email  text := auth.email();
  v_conf   public.stamp_confirmations%rowtype;
  v_biz    public.businesses%rowtype;
  v_card   public.cards%rowtype;
  v_spent  uuid;
  v_skip   int[];
  v_pmts   jsonb;
  v_snap   jsonb;
  v_months jsonb := '[]'::jsonb;
  v_n      int;
  v_entry  jsonb;
  v_ym     text;
  b        record;
  v_hit    boolean := false;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('error', 'bad_amount');
  end if;

  select * into v_conf from public.stamp_confirmations where id = p_confirmation;
  if not found or v_conf.parent_email <> v_email then
    return jsonb_build_object('error', 'expired');
  end if;
  if v_conf.used_at is not null or v_conf.expires_at <= now() then
    return jsonb_build_object('error', 'expired');
  end if;

  select * into v_biz from public.businesses where id = v_conf.business_id;

  if v_biz.require_pin_on_confirm then
    if p_pin is null or v_biz.confirm_pin is null or p_pin <> v_biz.confirm_pin then
      update public.stamp_confirmations
         set pin_fails = pin_fails + 1,
             used_at   = case when pin_fails + 1 >= 3 then now() else used_at end
       where id = v_conf.id;
      return jsonb_build_object('error', 'bad_pin',
                                'burned', v_conf.pin_fails + 1 >= 3);
    end if;
  end if;

  -- Single-use, enforced by the database rather than by checking first.
  update public.stamp_confirmations
     set used_at = now()
   where id = v_conf.id and used_at is null and expires_at > now()
   returning id into v_spent;
  if v_spent is null then
    return jsonb_build_object('error', 'expired');
  end if;

  -- The card has to be this parent's AND this school's. Either check alone
  -- would be a hole: the first without the second would let a parent of two
  -- schools post one school's tap against the other's student.
  select c.* into v_card
    from public.cards c
    join public.card_links cl on cl.card_id = c.id
   where c.id = p_card_id
     and cl.parent_email = v_email
     and c.business_id = v_conf.business_id;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  v_skip := (
    select coalesce(array_agg(x::int), '{}')
      from (
        select jsonb_array_elements_text(coalesce(v_biz.inactive_months, '[]'::jsonb)) as x
        union all
        select jsonb_array_elements_text(coalesce(v_card.paused_months, '[]'::jsonb))
      ) s);

  v_snap := coalesce(v_card.payments, '{}'::jsonb);
  v_pmts := v_snap;

  for b in
    select * from public.stamp_calc_breakdown(
      v_snap, p_amount, v_biz.year, v_skip,
      v_card.enrollment_start_month, v_card.level, v_card.fee_history, v_biz.fee)
  loop
    v_hit := true;
    v_ym  := v_biz.year::text || '-' || lpad((b.mi + 1)::text, 2, '0');
    v_pmts := jsonb_set(v_pmts, array[v_ym], jsonb_build_object(
      'paid',    b.full_month,
      'partial', not b.full_month,
      'amount',  b.new_total), true);
    v_months := v_months || to_jsonb(b.mi);
  end loop;

  -- Nothing outstanding. The session is already spent, which is right: the
  -- tap happened. There is simply nothing to record against it.
  if not v_hit then
    return jsonb_build_object('error', 'nothing_due', 'name', v_card.name);
  end if;

  v_n := coalesce(jsonb_array_length(v_card.history), 0) + 1;

  -- Same shape the dashboard writes, so undo, receipts and the history list
  -- all read it without knowing where it came from. The two extra keys are
  -- what make a tap distinguishable afterwards.
  v_entry := jsonb_build_object(
    'n',              v_n,
    'amount',         round(p_amount, 2),
    'date',           to_char(now() at time zone 'UTC', 'DD/MM/YYYY'),
    'snapshot',       v_snap,
    'months',         v_months,
    'receipt_sent_at', null,
    'trigger_source', v_conf.trigger_source,
    'confirmed_by',   v_email);

  update public.cards
     set payments = v_pmts,
         history  = jsonb_build_array(v_entry) || coalesce(v_card.history, '[]'::jsonb)
   where id = v_card.id;

  return jsonb_build_object(
    'ok',      true,
    'n',       v_n,
    'name',    v_card.name,
    'amount',  round(p_amount, 2),
    'months',  v_months,
    'trigger', v_conf.trigger_source);
end;
$$;


-- ===========================================================================
--  9. stamp_undo -- take back the entry just made
-- ===========================================================================
--
--  Narrow on purpose. It will only revert an entry that is the newest on the
--  card, was made by a trigger rather than typed into the dashboard, was made
--  by THIS parent, and is less than ten minutes old. Anything older or
--  anything the owner recorded is the owner's to undo from the dashboard,
--  where that already works.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_undo(p_card_id uuid, p_n int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
  v_card  public.cards%rowtype;
  v_top   jsonb;
  v_when  timestamptz;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  select c.* into v_card
    from public.cards c
    join public.card_links cl on cl.card_id = c.id
   where c.id = p_card_id and cl.parent_email = v_email;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  v_top := v_card.history -> 0;
  if v_top is null
     or (v_top->>'n')::int is distinct from p_n
     or v_top->>'confirmed_by' is distinct from v_email
     or coalesce(v_top->>'trigger_source', 'manual') = 'manual'
     or v_top->'snapshot' is null then
    return jsonb_build_object('error', 'cannot_undo');
  end if;

  -- Ten minutes, measured from the session that produced it. The entry's own
  -- 'date' is a day, which is far too coarse to gate an undo on.
  select max(created_at) into v_when
    from public.stamp_confirmations
   where parent_email = v_email and business_id = v_card.business_id;
  if v_when is null or v_when < now() - interval '10 minutes' then
    return jsonb_build_object('error', 'cannot_undo');
  end if;

  update public.cards
     set payments = v_top->'snapshot',
         history  = coalesce(v_card.history - 0, '[]'::jsonb)
   where id = v_card.id;

  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  10. Grants
--
--  EXECUTE was revoked from PUBLIC by the security-hardening migration and by
--  its ALTER DEFAULT PRIVILEGES, so nothing below is callable until it is
--  named here. anon is never granted anything: every one of these needs a
--  logged-in caller, and each checks auth.email()/auth.uid() for itself
--  rather than trusting the grant to have done it.
-- ===========================================================================

revoke all on function public.stamp_new_token_value()                      from public, anon;
revoke all on function public.stamp_fee_for_month(jsonb,jsonb,numeric,int)  from public, anon;
revoke all on function public.stamp_calc_breakdown(jsonb,numeric,int,int[],text,jsonb,jsonb,numeric) from public, anon;
revoke all on function public.stamp_nonce_for(text,bigint)                 from public, anon;
revoke all on function public.stamp_nonce_valid(text,text)                 from public, anon;
revoke all on function public.stamp_token_get()                            from public, anon;
revoke all on function public.stamp_token_rotate()                         from public, anon;
revoke all on function public.stamp_token_revoke()                         from public, anon;
revoke all on function public.set_confirm_settings(boolean,text)           from public, anon;
revoke all on function public.stamp_begin(text,text)                       from public, anon;
revoke all on function public.stamp_confirm(uuid,uuid,numeric,text)        from public, anon;
revoke all on function public.stamp_undo(uuid,int)                         from public, anon;

grant execute on function public.stamp_token_get()                     to authenticated;
grant execute on function public.stamp_token_rotate()                  to authenticated;
grant execute on function public.stamp_token_revoke()                  to authenticated;
grant execute on function public.set_confirm_settings(boolean,text)    to authenticated;
grant execute on function public.stamp_begin(text,text)                to authenticated;
grant execute on function public.stamp_confirm(uuid,uuid,numeric,text) to authenticated;
grant execute on function public.stamp_undo(uuid,int)                  to authenticated;

-- stamp_new_token_value, the two arithmetic helpers and the two nonce helpers
-- are internal to the functions above and are deliberately granted to nobody.


-- ===========================================================================
--  ROLLBACK (only if needed)
--
--    drop function if exists public.stamp_undo(uuid,int);
--    drop function if exists public.stamp_confirm(uuid,uuid,numeric,text);
--    drop function if exists public.stamp_begin(text,text);
--    drop function if exists public.set_confirm_settings(boolean,text);
--    drop function if exists public.stamp_token_revoke();
--    drop function if exists public.stamp_token_rotate();
--    drop function if exists public.stamp_token_get();
--    drop function if exists public.stamp_nonce_valid(text,text);
--    drop function if exists public.stamp_nonce_for(text,bigint);
--    drop function if exists public.stamp_calc_breakdown(jsonb,numeric,int,int[],text,jsonb,jsonb,numeric);
--    drop function if exists public.stamp_fee_for_month(jsonb,jsonb,numeric,int);
--    drop function if exists public.stamp_new_token_value();
--    drop table if exists public.stamp_confirmations;
--    drop table if exists public.stamp_tokens;
--    alter table public.businesses drop column if exists confirm_pin;
--    alter table public.businesses drop column if exists require_pin_on_confirm;
-- ===========================================================================
