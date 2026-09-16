-- ===========================================================================
--  The stamp in the student portal
--  -------------------------------------------------------------------------
--  The trigger worked in the family portal and did nothing in the student one.
--  Not a bug: the student portal has no login at all. It is opened with a
--  share code and a PIN, get_student_card() checks those anonymously, and
--  there is no auth.email() and no card_links row for stamp_begin_geometry to
--  work from. It could never have worked as written.
--
--  So this is a second identity path, not a fix. Two things make it narrower
--  than the family one, and both are deliberate:
--
--    - The session is bound to ONE card: the card already open on the screen.
--      It cannot be pointed at another student even at the same school, so the
--      worst it can touch is the record the person is already looking at.
--    - The code and PIN are re-checked HERE, under the same rate limit, rather
--      than trusted because the page says it checked them.
--
--  Worth stating plainly, because it changes what a student PIN is worth:
--  those PINs are deliberately plain-text shareable codes, and until now they
--  granted only viewing. With this they also permit recording a payment --
--  but ONLY together with a press of the school's physical stamp, which is the
--  authorisation, exactly as it is everywhere else in this feature. A school
--  that wants more than that has require_pin_on_confirm.
--
--  Additive. One nullable column, one relaxed constraint, three functions.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. A confirmation can now belong to a card rather than to a parent
-- ---------------------------------------------------------------------------

alter table public.stamp_confirmations
  add column if not exists card_id uuid references public.cards(id) on delete cascade;

alter table public.stamp_confirmations
  alter column parent_email drop not null;

-- Exactly one of the two identities, never both and never neither.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stamp_confirmations_one_identity') then
    alter table public.stamp_confirmations
      add constraint stamp_confirmations_one_identity
      check ((parent_email is not null and card_id is null)
          or (parent_email is null and card_id is not null));
  end if;
end $$;


-- ===========================================================================
--  2. Writing the payment, extracted so there is one of it
-- ===========================================================================
--
--  This is the body stamp_confirm already had, lifted out unchanged so the
--  student path cannot drift from the parent path. It does NO authorisation of
--  its own -- it is handed a card that the caller has already established the
--  right to write to -- which is why it is granted to nobody.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_apply_payment(
  p_card_id uuid, p_amount numeric, p_trigger text, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_card   public.cards%rowtype;
  v_biz    public.businesses%rowtype;
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
  select * into v_card from public.cards where id = p_card_id;
  if not found then return jsonb_build_object('error', 'no_match'); end if;
  select * into v_biz from public.businesses where id = v_card.business_id;

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
      'paid', b.full_month, 'partial', not b.full_month, 'amount', b.new_total), true);
    v_months := v_months || to_jsonb(b.mi);
  end loop;

  if not v_hit then
    return jsonb_build_object('error', 'nothing_due', 'name', v_card.name);
  end if;

  v_n := coalesce(jsonb_array_length(v_card.history), 0) + 1;
  v_entry := jsonb_build_object(
    'n', v_n, 'amount', round(p_amount, 2),
    'date', to_char(now() at time zone 'UTC', 'DD/MM/YYYY'),
    'snapshot', v_snap, 'months', v_months, 'receipt_sent_at', null,
    'trigger_source', p_trigger, 'confirmed_by', p_by);

  update public.cards
     set payments = v_pmts,
         history  = jsonb_build_array(v_entry) || coalesce(v_card.history, '[]'::jsonb)
   where id = v_card.id;

  return jsonb_build_object('ok', true, 'n', v_n, 'name', v_card.name,
                            'amount', round(p_amount, 2), 'months', v_months,
                            'trigger', p_trigger);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_confirm, rewritten over it. Same checks in the same order; only the
--  writing moved out. The existing suite is what says so.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_confirm(
  p_confirmation uuid, p_card_id uuid, p_amount numeric, p_pin text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
  v_conf  public.stamp_confirmations%rowtype;
  v_biz   public.businesses%rowtype;
  v_card  public.cards%rowtype;
  v_spent uuid;
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;
  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('error', 'bad_amount');
  end if;

  select * into v_conf from public.stamp_confirmations where id = p_confirmation;
  if not found or v_conf.parent_email is distinct from v_email then
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
      return jsonb_build_object('error', 'bad_pin', 'burned', v_conf.pin_fails + 1 >= 3);
    end if;
  end if;

  update public.stamp_confirmations
     set used_at = now()
   where id = v_conf.id and used_at is null and expires_at > now()
   returning id into v_spent;
  if v_spent is null then
    return jsonb_build_object('error', 'expired');
  end if;

  select c.* into v_card
    from public.cards c
    join public.card_links cl on cl.card_id = c.id
   where c.id = p_card_id
     and cl.parent_email = v_email
     and c.business_id = v_conf.business_id;
  if not found then
    return jsonb_build_object('error', 'no_match');
  end if;

  return public.stamp_apply_payment(v_card.id, p_amount, v_conf.trigger_source, v_email);
end;
$$;


-- ===========================================================================
--  3. The student portal's way in
-- ===========================================================================

-- ---------------------------------------------------------------------------
--  stamp_student_card -- code + PIN, under the SAME rate limit the portal's
--  own login uses, returning the card or nothing. Shared by the two functions
--  below so the check cannot be done two slightly different ways.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_student_card(p_code text, p_pin text)
returns public.cards
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(trim(p_code));
  v_fails int;
  c public.cards%rowtype;
begin
  delete from public.pin_attempts where attempted_at < now() - interval '1 day';
  select count(*) into v_fails from public.pin_attempts
   where share_code = v_code and attempted_at > now() - interval '15 minutes';
  if v_fails >= 5 then return null; end if;

  select * into c from public.cards where share_code = v_code limit 1;
  if not found or c.pin is null or c.pin <> p_pin then
    insert into public.pin_attempts(share_code) values (v_code);
    return null;
  end if;
  delete from public.pin_attempts where share_code = v_code;
  return c;
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_begin_geometry_student -- a press on an open student card.
--
--  Only that card's own school is considered, so there is no "which school"
--  question to get wrong and no way to probe another school's pattern.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_begin_geometry_student(
  p_code text, p_pin text, p_points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c      public.cards%rowtype;
  v_biz  public.businesses%rowtype;
  g      public.stamp_geometries%rowtype;
  n      int;
  v_conf uuid;
  v_exp  timestamptz;
  v_skip int[];
  v_first record;
  v_amt  numeric;
  v_label text;
begin
  if p_points is null or jsonb_typeof(p_points) <> 'array' then
    return jsonb_build_object('error', 'no_match');
  end if;
  n := jsonb_array_length(p_points);
  if n < 4 or n > 8 then
    return jsonb_build_object('error', 'no_match');
  end if;

  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error', 'no_match'); end if;

  select * into v_biz from public.businesses where id = c.business_id;
  select * into g     from public.stamp_geometries where business_id = c.business_id;
  if not found then return jsonb_build_object('error', 'no_match'); end if;

  if public.stamp_geometry_match(p_points, g.points, g.tolerance) is null then
    return jsonb_build_object('error', 'no_match');
  end if;

  delete from public.stamp_confirmations where created_at < now() - interval '1 day';

  v_skip := (
    select coalesce(array_agg(x::int), '{}')
      from (
        select jsonb_array_elements_text(coalesce(v_biz.inactive_months, '[]'::jsonb)) as x
        union all
        select jsonb_array_elements_text(coalesce(c.paused_months, '[]'::jsonb))
      ) s);

  select b.mi, b.applying into v_first
    from public.stamp_calc_breakdown(coalesce(c.payments,'{}'::jsonb), 999999,
           v_biz.year, v_skip, c.enrollment_start_month, c.level, c.fee_history, v_biz.fee) b
   order by b.mi limit 1;
  if not found then v_amt := 0; v_label := null;
  else
    v_amt := greatest(v_first.applying, 0);
    v_label := (array['January','February','March','April','May','June','July',
                      'August','September','October','November','December'])[v_first.mi + 1];
  end if;

  v_exp := now() + interval '60 seconds';
  insert into public.stamp_confirmations(business_id, card_id, trigger_source, expires_at)
    values (v_biz.id, c.id, 'stamp', v_exp)
    returning id into v_conf;

  return jsonb_build_object(
    'ok', true, 'confirmation', v_conf, 'expires_at', v_exp, 'trigger', 'stamp',
    'require_pin', v_biz.require_pin_on_confirm,
    'business_name', v_biz.name, 'type', v_biz.type,
    'accent', v_biz.accent, 'icon', v_biz.icon, 'year', v_biz.year,
    'students', jsonb_build_array(jsonb_build_object(
      'card_id', c.id, 'name', c.name, 'amount', v_amt, 'month', v_label)));
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_confirm_student -- spend a student-portal session.
--
--  The code and PIN are checked again, and the card they resolve to must be
--  the card the session was opened against. Passing a different student's code
--  gets nothing, and so does passing a different session.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_confirm_student(
  p_confirmation uuid, p_code text, p_pin text,
  p_amount numeric, p_owner_pin text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c       public.cards%rowtype;
  v_conf  public.stamp_confirmations%rowtype;
  v_biz   public.businesses%rowtype;
  v_spent uuid;
begin
  if p_amount is null or p_amount <= 0 then
    return jsonb_build_object('error', 'bad_amount');
  end if;

  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error', 'no_match'); end if;

  select * into v_conf from public.stamp_confirmations where id = p_confirmation;
  if not found or v_conf.card_id is distinct from c.id then
    return jsonb_build_object('error', 'expired');
  end if;
  if v_conf.used_at is not null or v_conf.expires_at <= now() then
    return jsonb_build_object('error', 'expired');
  end if;

  select * into v_biz from public.businesses where id = v_conf.business_id;

  if v_biz.require_pin_on_confirm then
    if p_owner_pin is null or v_biz.confirm_pin is null or p_owner_pin <> v_biz.confirm_pin then
      update public.stamp_confirmations
         set pin_fails = pin_fails + 1,
             used_at   = case when pin_fails + 1 >= 3 then now() else used_at end
       where id = v_conf.id;
      return jsonb_build_object('error', 'bad_pin', 'burned', v_conf.pin_fails + 1 >= 3);
    end if;
  end if;

  update public.stamp_confirmations
     set used_at = now()
   where id = v_conf.id and used_at is null and expires_at > now()
   returning id into v_spent;
  if v_spent is null then
    return jsonb_build_object('error', 'expired');
  end if;

  -- 'student:CODE' rather than an email, so the history says where it came
  -- from. It is also what stamp_undo checks, which is why an anonymous
  -- confirmation cannot be undone through the family portal by someone else.
  return public.stamp_apply_payment(c.id, p_amount, 'stamp', 'student:' || c.share_code);
end;
$$;


-- ---------------------------------------------------------------------------
--  stamp_undo_student -- the same ten-minute window, for the same card.
-- ---------------------------------------------------------------------------

create or replace function public.stamp_undo_student(
  p_code text, p_pin text, p_n int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c     public.cards%rowtype;
  v_top jsonb;
  v_when timestamptz;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error', 'no_match'); end if;

  v_top := c.history -> 0;
  if v_top is null
     or (v_top->>'n')::int is distinct from p_n
     or v_top->>'confirmed_by' is distinct from ('student:' || c.share_code)
     or coalesce(v_top->>'trigger_source','manual') = 'manual'
     or v_top->'snapshot' is null then
    return jsonb_build_object('error', 'cannot_undo');
  end if;

  select max(created_at) into v_when
    from public.stamp_confirmations where card_id = c.id;
  if v_when is null or v_when < now() - interval '10 minutes' then
    return jsonb_build_object('error', 'cannot_undo');
  end if;

  update public.cards
     set payments = v_top->'snapshot',
         history  = coalesce(c.history - 0, '[]'::jsonb)
   where id = c.id;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  4. Grants
--
--  These three are the only functions in the whole feature granted to anon,
--  and only because the student portal has no login by design -- the same
--  reason get_student_card is. Each one re-checks the share code and PIN
--  itself under the shared rate limit rather than trusting the grant.
-- ===========================================================================

revoke all on function public.stamp_apply_payment(uuid,numeric,text,text)          from public, anon, authenticated;
revoke all on function public.stamp_student_card(text,text)                        from public, anon, authenticated;

revoke all on function public.stamp_begin_geometry_student(text,text,jsonb)        from public;
revoke all on function public.stamp_confirm_student(uuid,text,text,numeric,text)   from public;
revoke all on function public.stamp_undo_student(text,text,int)                    from public;

grant execute on function public.stamp_begin_geometry_student(text,text,jsonb)      to anon, authenticated;
grant execute on function public.stamp_confirm_student(uuid,text,text,numeric,text) to anon, authenticated;
grant execute on function public.stamp_undo_student(text,text,int)                  to anon, authenticated;

-- stamp_apply_payment does no authorisation of its own and stamp_student_card
-- is the check itself; neither is callable from outside.


-- ===========================================================================
--  ROLLBACK
--    drop function if exists public.stamp_undo_student(text,text,int);
--    drop function if exists public.stamp_confirm_student(uuid,text,text,numeric,text);
--    drop function if exists public.stamp_begin_geometry_student(text,text,jsonb);
--    drop function if exists public.stamp_student_card(text,text);
--    -- then re-run migration-stamp-confirm.sql to restore the inlined
--    -- stamp_confirm, and drop stamp_apply_payment.
-- ===========================================================================
