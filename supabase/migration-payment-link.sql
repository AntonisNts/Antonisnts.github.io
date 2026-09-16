-- ===========================================================================
--  Payment link and pending claims
--  -------------------------------------------------------------------------
--  A school can publish a link to wherever it takes money -- Revolut, Viva, a
--  bank page, anything. A parent follows it, pays outside PayStamp, and comes
--  back to say so. That claim sits in a queue until the school confirms it
--  against their actual statement.
--
--  THE INVARIANT THIS FILE EXISTS TO PROTECT: a claim is not a payment.
--
--  Nothing here writes to cards.payments. Claims live in their own table, so a
--  student with ten pending claims still owes exactly what they owed before --
--  on their card, in the school's totals, in every overdue calculation, in the
--  export. The only thing that ever moves money is the school confirming, and
--  that goes through stamp_apply_payment, the same writer the tag, the QR and
--  the stamp use. Not a copy of it.
--
--  That is worth stating in the file because it is a property nobody can see
--  by reading one function. supabase/test/test-payment-link.sql asserts it
--  directly: raise a claim, then check the card and the school's owed total
--  are byte-for-byte what they were.
--
--  Additive. Two columns, one table. Safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. Where the money goes
--
--  Who may set it is RLS: businesses_update_own already restricts every write
--  on this table to the owner, and the two columns are added to the same
--  column-level grant the other editable fields use.
--
--  WHAT may be set is a CHECK, deliberately, rather than validation in a
--  function. A constraint holds on every path into the column -- the app, a
--  future admin screen, a hand-written UPDATE in the SQL editor -- whereas
--  validation inside one function only holds for callers who go through that
--  function.
--
--  https only. Not pedantry: this link is shown to parents and leads to a
--  page where they type card details, and `javascript:`, `data:` and plain
--  http all fail the same test.
-- ---------------------------------------------------------------------------

alter table public.businesses add column if not exists payment_link      text;
alter table public.businesses add column if not exists payment_link_name text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'businesses_payment_link_https') then
    alter table public.businesses
      add constraint businesses_payment_link_https
      check (payment_link is null
             or (payment_link ~ '^https://[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}(/[^\s]*)?$'
                 and length(payment_link) <= 500));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'businesses_payment_link_name_len') then
    alter table public.businesses
      add constraint businesses_payment_link_name_len
      check (payment_link_name is null or length(btrim(payment_link_name)) between 1 and 60);
  end if;
end $$;

grant update (payment_link, payment_link_name) on public.businesses to authenticated;


-- ---------------------------------------------------------------------------
--  2. The claims
--
--  claimed_by carries either a parent's email or 'student:CODE', the same two
--  shapes stamp_apply_payment already records in confirmed_by. One column, so
--  the queue does not have to care which portal a claim came from.
--
--  source exists for the Stripe path that is NOT being built now. A webhook
--  would insert a claim with source='stripe' already confirmed, or confirm one
--  it can match; either way it needs somewhere to say the money was verified
--  by a processor rather than by a person reading a statement. One column now
--  is cheaper than a migration later, and it costs nothing to carry.
-- ---------------------------------------------------------------------------

create table if not exists public.payment_claims (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  card_id     uuid not null references public.cards(id)      on delete cascade,
  claimed_by  text not null,
  amount      numeric not null check (amount > 0 and amount <= 100000),
  paid_on     date not null,
  reference   text check (reference is null or length(btrim(reference)) <= 40),
  status      text not null default 'pending'
                check (status in ('pending','confirmed','rejected')),
  source      text not null default 'manual'
                check (source in ('manual','stripe')),
  note        text check (note is null or length(note) <= 300),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  decided_by  uuid references auth.users(id)
);

create index if not exists payment_claims_queue_idx
  on public.payment_claims(business_id, status, created_at desc);
create index if not exists payment_claims_card_idx
  on public.payment_claims(card_id, created_at desc);

alter table public.payment_claims enable row level security;
revoke all on table public.payment_claims from public, anon, authenticated;

-- A claim per card can only be pending once at a time. Without this, a parent
-- tapping "I've paid" twice puts two identical claims in the queue and the
-- school confirms the money twice.
create unique index if not exists payment_claims_one_pending
  on public.payment_claims(card_id) where status = 'pending';


-- ---------------------------------------------------------------------------
--  How stale is stale. Named here rather than buried, because it is a judgement
--  about how long a school can reasonably take to check a statement, not a
--  constant with an obvious right value.
-- ---------------------------------------------------------------------------

create or replace function public.payment_claim_stale_after()
returns interval language sql immutable set search_path = public as $$
  select interval '10 days';
$$;


-- ===========================================================================
--  3. Raising a claim
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  payment_claim_open -- shared by both portals once each has established WHO
--  is asking. It does no authorisation of its own, which is why it is granted
--  to nobody: its callers below do the proving.
-- ---------------------------------------------------------------------------

create or replace function public.payment_claim_open(
  p_card_id uuid, p_by text, p_amount numeric, p_paid_on date, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_card public.cards%rowtype;
  v_biz  public.businesses%rowtype;
  v_id   uuid;
begin
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    return jsonb_build_object('error', 'bad_amount');
  end if;
  -- A date in the future is a typo, not a payment. A year back is generous.
  if p_paid_on is null or p_paid_on > current_date
     or p_paid_on < current_date - interval '365 days' then
    return jsonb_build_object('error', 'bad_date');
  end if;
  if p_reference is not null and length(btrim(p_reference)) > 40 then
    return jsonb_build_object('error', 'bad_reference');
  end if;

  select * into v_card from public.cards where id = p_card_id;
  if not found then return jsonb_build_object('error', 'no_match'); end if;
  select * into v_biz from public.businesses where id = v_card.business_id;

  -- No link, no claim. A school that has not published somewhere to pay is not
  -- expecting anyone to have paid online.
  if v_biz.payment_link is null then
    return jsonb_build_object('error', 'no_link');
  end if;

  insert into public.payment_claims(business_id, card_id, claimed_by, amount, paid_on, reference)
    values (v_card.business_id, v_card.id, p_by, round(p_amount, 2), p_paid_on,
            nullif(btrim(coalesce(p_reference, '')), ''))
    returning id into v_id;

  return jsonb_build_object('ok', true, 'claim', v_id, 'name', v_card.name);
exception when unique_violation then
  -- The partial unique index. Two taps, one claim.
  return jsonb_build_object('error', 'already_pending');
end;
$$;


create or replace function public.payment_claim_create(
  p_card_id uuid, p_amount numeric, p_paid_on date, p_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_email text := auth.email();
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  if not exists (select 1 from public.card_links
                  where card_id = p_card_id and parent_email = v_email) then
    return jsonb_build_object('error', 'no_match');
  end if;
  return public.payment_claim_open(p_card_id, v_email, p_amount, p_paid_on, p_reference);
end;
$$;


create or replace function public.payment_claim_create_student(
  p_code text, p_pin text, p_amount numeric, p_paid_on date, p_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error', 'no_match'); end if;
  return public.payment_claim_open(c.id, 'student:' || c.share_code,
                                   p_amount, p_paid_on, p_reference);
end;
$$;


-- ===========================================================================
--  4. Seeing your own claims
-- ===========================================================================
--
--  A parent needs to know a claim is waiting, and needs to be told when it was
--  turned down and why -- that is the whole of "notifies the parent" until
--  there is somewhere to send a push to. Both portals read the same shape.
-- ---------------------------------------------------------------------------

create or replace function public.payment_claims_mine()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_email text := auth.email();
begin
  if v_email is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', pc.id, 'card_id', pc.card_id, 'name', c.name,
             'amount', pc.amount, 'paid_on', pc.paid_on, 'reference', pc.reference,
             'status', pc.status, 'note', pc.note, 'created_at', pc.created_at)
           order by pc.created_at desc)
      from public.payment_claims pc
      join public.cards c on c.id = pc.card_id
     where pc.claimed_by = v_email
       and (pc.status = 'pending' or pc.decided_at > now() - interval '30 days')
  ), '[]'::jsonb);
end;
$$;


create or replace function public.payment_claims_mine_student(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', pc.id, 'card_id', pc.card_id, 'name', c.name,
             'amount', pc.amount, 'paid_on', pc.paid_on, 'reference', pc.reference,
             'status', pc.status, 'note', pc.note, 'created_at', pc.created_at)
           order by pc.created_at desc)
      from public.payment_claims pc
     where pc.card_id = c.id
       and pc.claimed_by = 'student:' || c.share_code
       and (pc.status = 'pending' or pc.decided_at > now() - interval '30 days')
  ), '[]'::jsonb);
end;
$$;


-- ---------------------------------------------------------------------------
--  Where the Pay online button points.
--
--  Separate small functions rather than adding a field to get_my_cards or
--  get_student_card. Those two have been redefined by three migrations each
--  already, and every redefinition is a chance to drop a field somebody else
--  depends on. A new function cannot break an old one.
-- ---------------------------------------------------------------------------

create or replace function public.payment_links_mine()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_email text := auth.email();
begin
  if v_email is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(distinct jsonb_build_object(
             'card_id', c.id, 'link', b.payment_link, 'name', b.payment_link_name))
      from public.card_links cl
      join public.cards c      on c.id = cl.card_id
      join public.businesses b on b.id = c.business_id
     where cl.parent_email = v_email and b.payment_link is not null
  ), '[]'::jsonb);
end;
$$;


create or replace function public.payment_link_student(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cards%rowtype;
  b public.businesses%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('link', null); end if;
  select * into b from public.businesses where id = c.business_id;
  return jsonb_build_object('link', b.payment_link, 'name', b.payment_link_name);
end;
$$;


-- ===========================================================================
--  5. The school's queue
-- ===========================================================================

create or replace function public.payment_claims_queue()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_biz public.businesses%rowtype;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;

  return jsonb_build_object(
    'ok', true,
    'pending', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pc.id, 'card_id', pc.card_id, 'name', c.name,
               'amount', pc.amount, 'paid_on', pc.paid_on,
               'reference', pc.reference, 'claimed_by', pc.claimed_by,
               'created_at', pc.created_at,
               -- Computed, not stored: a stored flag would need something to
               -- come along and set it, and nothing here runs on a schedule.
               'stale', pc.created_at < now() - public.payment_claim_stale_after())
             order by pc.created_at)
        from public.payment_claims pc
        join public.cards c on c.id = pc.card_id
       where pc.business_id = v_biz.id and pc.status = 'pending'
    ), '[]'::jsonb),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pc.id, 'name', c.name, 'amount', pc.amount,
               'status', pc.status, 'decided_at', pc.decided_at)
             order by pc.decided_at desc)
        from public.payment_claims pc
        join public.cards c on c.id = pc.card_id
       where pc.business_id = v_biz.id and pc.status <> 'pending'
         and pc.decided_at > now() - interval '14 days'
    ), '[]'::jsonb));
end;
$$;


-- ---------------------------------------------------------------------------
--  payment_claim_confirm -- the only thing in this file that moves money.
--
--  It hands the amount to stamp_apply_payment, which is the same writer the
--  tag, the QR and the stamp go through. Not a copy: the breakdown, the
--  rounding, the history entry and the snapshot that makes undo possible are
--  all the ones already in use, so a link payment lands on the card exactly
--  the way every other payment does.
-- ---------------------------------------------------------------------------

create or replace function public.payment_claim_confirm(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz  public.businesses%rowtype;
  v_pc   public.payment_claims%rowtype;
  v_done uuid;
  v_res  jsonb;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;

  select * into v_pc from public.payment_claims
   where id = p_id and business_id = v_biz.id;
  if not found then return jsonb_build_object('error', 'no_match'); end if;

  -- Claimed first, like every other single-use step in this codebase: two
  -- taps on Confirm race here, and exactly one of them updates a row.
  update public.payment_claims
     set status = 'confirmed', decided_at = now(), decided_by = auth.uid()
   where id = v_pc.id and status = 'pending'
   returning id into v_done;
  if v_done is null then
    return jsonb_build_object('error', 'already_decided');
  end if;

  v_res := public.stamp_apply_payment(v_pc.card_id, v_pc.amount, 'link', v_pc.claimed_by);

  -- Nothing was owing. The claim stays confirmed -- the money did arrive, the
  -- card simply had nothing left to put it against -- and the owner is told
  -- rather than left wondering why the card did not move.
  if v_res ? 'error' then
    return jsonb_build_object('ok', true, 'nothing_due', true, 'name', v_res->>'name');
  end if;
  return v_res || jsonb_build_object('ok', true);
end;
$$;


create or replace function public.payment_claim_reject(p_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_biz  public.businesses%rowtype;
  v_done uuid;
begin
  select * into v_biz from public.businesses where owner_id = auth.uid() limit 1;
  if not found then return jsonb_build_object('error', 'no_business'); end if;
  if p_note is not null and length(p_note) > 300 then
    return jsonb_build_object('error', 'bad_note');
  end if;

  -- Ownership first, so "not yours" and "already decided" stay different
  -- answers. Folding them together told another school's owner their reject
  -- had merely come too late, which is both wrong and a small information leak.
  if not exists (select 1 from public.payment_claims
                  where id = p_id and business_id = v_biz.id) then
    return jsonb_build_object('error', 'no_match');
  end if;

  update public.payment_claims
     set status = 'rejected', decided_at = now(), decided_by = auth.uid(),
         note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id and business_id = v_biz.id and status = 'pending'
   returning id into v_done;
  if v_done is null then
    return jsonb_build_object('error', 'already_decided');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  6. Grants
-- ===========================================================================

revoke all on function public.payment_claim_open(uuid,text,numeric,date,text)          from public, anon, authenticated;
revoke all on function public.payment_claim_stale_after()                              from public, anon;

revoke all on function public.payment_claim_create(uuid,numeric,date,text)             from public, anon;
revoke all on function public.payment_claims_mine()                                    from public, anon;
revoke all on function public.payment_claims_queue()                                   from public, anon;
revoke all on function public.payment_claim_confirm(uuid)                              from public, anon;
revoke all on function public.payment_claim_reject(uuid,text)                          from public, anon;

revoke all on function public.payment_claim_create_student(text,text,numeric,date,text) from public;
revoke all on function public.payment_claims_mine_student(text,text)                    from public;

grant execute on function public.payment_claim_create(uuid,numeric,date,text) to authenticated;
grant execute on function public.payment_claims_mine()                        to authenticated;
grant execute on function public.payment_claims_queue()                       to authenticated;
grant execute on function public.payment_claim_confirm(uuid)                  to authenticated;
grant execute on function public.payment_claim_reject(uuid,text)              to authenticated;

-- The student portal has no login, the same way get_student_card has none.
grant execute on function public.payment_claim_create_student(text,text,numeric,date,text) to anon, authenticated;
grant execute on function public.payment_claims_mine_student(text,text)                    to anon, authenticated;
grant execute on function public.payment_link_student(text,text)                           to anon, authenticated;

revoke all on function public.payment_links_mine()               from public, anon;
revoke all on function public.payment_link_student(text,text)    from public;
grant execute on function public.payment_links_mine()            to authenticated;

-- payment_claim_open is the shared body and proves nothing about who is
-- calling; its two callers above do that. Granting it would let any logged-in
-- person raise a claim against any card id they could name.


-- ===========================================================================
--  A NOTE ON THE STRIPE PATH, which is deliberately not built.
--
--  The shape it would take: a webhook endpoint verifies the signature, finds
--  the card from metadata it put on the session, and inserts a claim with
--  source='stripe' and status already 'confirmed', calling stamp_apply_payment
--  with trigger_source 'link' exactly as payment_claim_confirm does. The queue
--  would then only ever hold manual claims, which are the ones that need a
--  human to look at a statement.
--
--  What it needs that does not exist yet: somewhere to run server code. See
--  "The backend is parked" in DECISIONS.md.
--
--  ROLLBACK
--    drop function if exists public.payment_claim_reject(uuid,text);
--    drop function if exists public.payment_claim_confirm(uuid);
--    drop function if exists public.payment_claims_queue();
--    drop function if exists public.payment_claims_mine_student(text,text);
--    drop function if exists public.payment_claims_mine();
--    drop function if exists public.payment_claim_create_student(text,text,numeric,date,text);
--    drop function if exists public.payment_claim_create(uuid,numeric,date,text);
--    drop function if exists public.payment_claim_open(uuid,text,numeric,date,text);
--    drop function if exists public.payment_claim_stale_after();
--    drop table if exists public.payment_claims;
--    alter table public.businesses drop column if exists payment_link_name;
--    alter table public.businesses drop column if exists payment_link;
-- ===========================================================================
