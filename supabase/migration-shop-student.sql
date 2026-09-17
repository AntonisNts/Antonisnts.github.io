-- ===========================================================================
--  SHOP MODULE — the student portal
--  ---------------------------------------------------------------------------
--  Part of the shop module. The reason, in the owner's words: "some parents may
--  have only one kid in one school only" -- and those families use the student
--  portal, which is a code and a PIN rather than an account. Until now the shop
--  existed only for people who had signed up.
--
--  The student portal has no login, so `auth.email()` is null and every
--  shop_*_mine function returns nothing. What it has instead is a share code
--  and a PIN, already verified the same way the payment link and the stamp
--  verify them: public.stamp_student_card, which is rate limited and does the
--  checking itself rather than taking the page's word for it.
--
--  Nothing here re-implements what an order is. shop_order_place is split into
--  an inner writer and two doorways, exactly as payment_claim_open is -- so an
--  order placed by a student and one placed by a parent cannot drift apart.
-- ===========================================================================


-- ===========================================================================
--  1. The writer, and the two doorways
-- ===========================================================================
--
--  shop_order_open is what shop_order_place has always been, minus the part
--  that worked out who was calling. It authorises NOTHING: it is handed a card
--  its caller has already established the right to order against, which is why
--  it is granted to nobody.
-- ---------------------------------------------------------------------------

create or replace function public.shop_order_open(
  p_card_id uuid, p_by text, p_lines jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_card  public.cards%rowtype;
  v_biz   public.businesses%rowtype;
  v_order uuid;
  v_total numeric := 0;
  r       jsonb;
  v_item  public.shop_items%rowtype;
  v_qty   int;
  v_size  text;
  v_got   uuid;
  n       int;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    return jsonb_build_object('error','bad_lines');
  end if;
  n := jsonb_array_length(p_lines);
  if n = 0 or n > 20 then return jsonb_build_object('error','bad_lines'); end if;

  select * into v_card from public.cards where id = p_card_id;
  if not found then return jsonb_build_object('error','no_match'); end if;

  select * into v_biz from public.businesses where id = v_card.business_id;
  if not public.shop_is_enabled(v_biz.id) then
    return jsonb_build_object('error','shop_off');
  end if;

  insert into public.shop_orders(business_id, card_id, ordered_by, total, note)
    values (v_biz.id, v_card.id, p_by, 0,
            nullif(btrim(coalesce(p_note,'')),''))
    returning id into v_order;

  for r in select * from jsonb_array_elements(p_lines) loop
    v_qty  := coalesce((r->>'qty')::int, 0);
    v_size := nullif(btrim(coalesce(r->>'size','')),'');
    if v_qty < 1 or v_qty > 50 then
      raise exception using errcode = 'check_violation', message = 'bad_qty';
    end if;

    select * into v_item from public.shop_items
     where id = (r->>'item_id')::uuid
       and business_id = v_biz.id
       and archived_at is null;
    if not found then
      raise exception using errcode = 'no_data_found', message = 'bad_item';
    end if;

    if jsonb_array_length(v_item.sizes) > 0 then
      if v_size is null or not (v_item.sizes ? v_size) then
        raise exception using errcode = 'no_data_found', message = 'bad_size';
      end if;
    else
      v_size := null;
    end if;

    -- The check and the decrement are one statement, so two people ordering
    -- the last jumper at the same moment cannot both get it -- whichever
    -- portal they came through.
    if v_item.stock is not null then
      update public.shop_items
         set stock = stock - v_qty, updated_at = now()
       where id = v_item.id and stock >= v_qty
       returning id into v_got;
      if v_got is null then
        raise exception using errcode = 'no_data_found', message = 'out_of_stock';
      end if;
    end if;

    insert into public.shop_order_lines(order_id, item_id, item_name, size, qty, unit_price, line_total)
      values (v_order, v_item.id, v_item.name, v_size, v_qty, v_item.price,
              round(v_item.price * v_qty, 2));
    v_total := v_total + round(v_item.price * v_qty, 2);
  end loop;

  update public.shop_orders set total = v_total where id = v_order;

  return jsonb_build_object('ok', true, 'order', v_order, 'total', v_total);
exception
  when no_data_found then
    return jsonb_build_object('error', sqlerrm);
  when check_violation then
    return jsonb_build_object('error', sqlerrm);
end;
$$;


-- The parent's doorway: unchanged behaviour, now one line of proving plus the
-- shared writer.
create or replace function public.shop_order_place(p_card_id uuid, p_lines jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email text := auth.email(); v_ok uuid;
begin
  if v_email is null then return jsonb_build_object('error','not_authenticated'); end if;
  select c.id into v_ok
    from public.cards c
    join public.card_links cl on cl.card_id = c.id
   where c.id = p_card_id and cl.parent_email = v_email;
  if v_ok is null then return jsonb_build_object('error','no_match'); end if;
  return public.shop_order_open(p_card_id, v_email, p_lines, p_note);
end;
$$;


-- The student's doorway. `student:CODE` is the same shape payment claims use,
-- so the school's order queue can say where an order came from.
create or replace function public.shop_order_place_student(
  p_code text, p_pin text, p_lines jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error','no_match'); end if;
  return public.shop_order_open(c.id, 'student:' || c.share_code, p_lines, p_note);
end;
$$;


-- ===========================================================================
--  2. What a student can see
-- ===========================================================================
--
--  One card's worth of the same shape shop_catalogue_mine returns, so the
--  panel that draws it does not have to know which portal it is in. An empty
--  array for a school with the shop off -- not an empty catalogue, nothing --
--  exactly as the parent's version does.
-- ---------------------------------------------------------------------------

create or replace function public.shop_catalogue_student(p_code text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype; b public.businesses%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return '[]'::jsonb; end if;
  select * into b from public.businesses where id = c.business_id;
  if not public.shop_is_enabled(b.id) then return '[]'::jsonb; end if;

  return jsonb_build_array(jsonb_build_object(
    'card_id', c.id, 'student', c.name, 'school', b.name,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'name', i.name, 'description', i.description,
               'price', i.price, 'sizes', i.sizes,
               'out_of_stock', i.stock is not null and i.stock <= 0,
               'image_url', i.image_url)
             order by i.name)
        from public.shop_items i
       where i.business_id = b.id and i.archived_at is null), '[]'::jsonb)));
end;
$$;


create or replace function public.shop_orders_mine_student(p_code text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'card_id', o.card_id, 'student', c.name,
             'status', o.status, 'payment_status', o.payment_status,
             'total', o.total, 'created_at', o.created_at,
             'claim_amount', o.claim_amount, 'claim_date', o.claim_date,
             'lines', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', l.item_name, 'size', l.size,
                        'qty', l.qty, 'line_total', l.line_total))
                 from public.shop_order_lines l where l.order_id = o.id), '[]'::jsonb))
           order by o.created_at desc)
      from public.shop_orders o
     where o.card_id = c.id
       and o.ordered_by = 'student:' || c.share_code
       and (o.status <> 'collected' or o.updated_at > now() - interval '30 days')
  ), '[]'::jsonb);
end;
$$;


-- Telling the school you paid, from the student portal. Settles nothing, same
-- as the parent's version: 'claimed' is not 'paid'.
create or replace function public.shop_order_claim_paid_student(
  p_code text, p_pin text, p_order_id uuid,
  p_amount numeric, p_paid_on date, p_reference text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.cards%rowtype; v_id uuid;
begin
  c := public.stamp_student_card(p_code, p_pin);
  if c.id is null then return jsonb_build_object('error','no_match'); end if;
  if p_amount is null or p_amount <= 0 then return jsonb_build_object('error','bad_amount'); end if;
  if p_paid_on is null or p_paid_on > current_date
     or p_paid_on < current_date - interval '365 days' then
    return jsonb_build_object('error','bad_date');
  end if;

  update public.shop_orders
     set payment_status = 'claimed', claim_amount = round(p_amount,2),
         claim_date = p_paid_on,
         claim_ref = nullif(btrim(coalesce(p_reference,'')),''),
         claimed_at = now(), updated_at = now()
   where id = p_order_id
     and card_id = c.id
     and ordered_by = 'student:' || c.share_code
     and payment_status = 'unpaid' and status <> 'cancelled'
   returning id into v_id;
  if v_id is null then return jsonb_build_object('error','no_match'); end if;
  return jsonb_build_object('ok', true);
end;
$$;


-- ===========================================================================
--  3. Grants
--
--  anon as well as authenticated: the student portal is not signed in at all.
--  Every one of these proves the code and PIN for itself, under the same rate
--  limit as the rest of the student portal.
--
--  shop_order_open is granted to NOBODY. It writes an order without asking who
--  wanted it, which is the whole reason the two doorways exist.
-- ===========================================================================

revoke all on function public.shop_order_open(uuid,text,jsonb,text) from public, anon, authenticated;

revoke all on function public.shop_catalogue_student(text,text)                  from public;
revoke all on function public.shop_orders_mine_student(text,text)                from public;
revoke all on function public.shop_order_place_student(text,text,jsonb,text)     from public;
revoke all on function public.shop_order_claim_paid_student(text,text,uuid,numeric,date,text) from public;

grant execute on function public.shop_catalogue_student(text,text)               to anon, authenticated;
grant execute on function public.shop_orders_mine_student(text,text)             to anon, authenticated;
grant execute on function public.shop_order_place_student(text,text,jsonb,text)  to anon, authenticated;
grant execute on function public.shop_order_claim_paid_student(text,text,uuid,numeric,date,text) to anon, authenticated;


-- ===========================================================================
--  REMOVING THIS
--
--    drop function if exists public.shop_order_claim_paid_student(text,text,uuid,numeric,date,text);
--    drop function if exists public.shop_order_place_student(text,text,jsonb,text);
--    drop function if exists public.shop_orders_mine_student(text,text);
--    drop function if exists public.shop_catalogue_student(text,text);
--
--  shop_order_open and the rewritten shop_order_place stay: they are the
--  parent's path too, and reverting them would mean putting the old copy back.
-- ===========================================================================
