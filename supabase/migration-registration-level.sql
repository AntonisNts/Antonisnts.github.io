-- ============================================================================
--  Migration: approving a registration can set the student's LEVEL
--  ----------------------------------------------------------------------------
--  THE BUG THIS FIXES
--
--  approve_registration wrote `level = null`, and the app resolves a fee as:
--
--      cardFee(card, biz) = (card.level && card.level.fee) ? card.level.fee
--                                                          : biz.fee
--
--  so every self-registered student silently landed on the business's single
--  default monthly fee, regardless of the levels the school had defined. A
--  school with Beginner €50 / Medium €60 / Advance €70 got none of them until
--  someone opened the student and set the level by hand.
--
--  Groups and levels are different things in PayStamp: a group is WHEN a
--  student comes (schedule + teacher), a level is WHAT THEY PAY. The public
--  form asks about the group because that is a question a family can answer.
--  The level is the school's judgement, so it belongs at approval — beside the
--  class the owner already confirms — and not on the public form, where
--  choosing a level would mean the family choosing their own price.
--
--  ----------------------------------------------------------------------------
--  WHY THE LEVEL IS LOOKED UP HERE RATHER THAN SENT IN
--
--  The caller passes a level ID, not a {id,name,fee} object, and this function
--  reads the matching entry out of businesses.levels. The browser therefore
--  cannot state a fee — it can only name one of the school's own levels. An
--  unknown ID leaves the level null, exactly as an unknown group leaves the
--  student ungrouped: visible and fixable, never quietly wrong.
--
--  ----------------------------------------------------------------------------
--  THE DROP IS NOT OPTIONAL
--
--  `create or replace function` matches on the argument list, so adding a
--  parameter creates a SECOND function rather than replacing the first. With
--  p_level_id defaulting to null, a four-argument call would then match both
--  and PostgREST would fail with "Could not choose the best candidate
--  function". The old signature is dropped first so exactly one remains.
--
--  Safe to run while the app is live: the drop and create are one transaction
--  in the SQL editor, and the only caller is the Registration screen.
--
--  Run ONCE in the Supabase SQL editor.
-- ============================================================================

drop function if exists public.approve_registration(uuid, text, text, uuid);

create or replace function public.approve_registration(
  p_request_id uuid,
  p_share_code text,
  p_pin        text,
  p_group_id   uuid default null,     -- owner may override the requested group
  p_level_id   text default null      -- one of businesses.levels[].id, or null
) returns jsonb
language plpgsql
set search_path = public
as $function$
declare
  v_req   public.registration_requests%rowtype;
  v_card  public.cards%rowtype;
  v_group uuid;
  v_level jsonb := null;
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

  -- Level resolution. The whole stored element is copied, so the snapshot on
  -- the card is byte-for-byte one of the school's own levels — the same shape
  -- doAddCard writes ({id,name,fee}). No match => null => the business default
  -- fee, which is the behaviour every existing student already has.
  if p_level_id is not null then
    select e into v_level
      from public.businesses b,
           lateral jsonb_array_elements(coalesce(b.levels, '[]'::jsonb)) e
     where b.id = v_req.business_id
       and e ->> 'id' = p_level_id
     limit 1;
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
     v_level,
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
                               'group_id', v_card.group_id,
                               'level', v_card.level));
end;
$function$;

-- ---------------------------------------------------------------------------
--  Close the PUBLIC execute default, while we are here
--
--  Postgres grants EXECUTE on a new function to PUBLIC automatically, and
--  every role inherits PUBLIC. So `grant execute ... to authenticated` never
--  restricted anything: anon could already CALL approve_registration. Nothing
--  came of it — the function is SECURITY INVOKER, so as anon it dies on
--  "permission denied for table registration_requests" and writes nothing —
--  but it is surface that need not exist, and the error names an internal
--  table to an anonymous caller.
--
--  Revoking from PUBLIC first makes the grants below mean what they say. The
--  two public functions are re-granted to anon because the /join/ page is
--  supposed to reach them; approve_registration is not.
-- ---------------------------------------------------------------------------
revoke all on function public.approve_registration(uuid,text,text,uuid,text) from public;
revoke all on function public.submit_registration(text,text,text,text,text,date,uuid,text) from public;
revoke all on function public.get_registration_form(text) from public;

grant execute on function public.approve_registration(uuid,text,text,uuid,text)  to authenticated;
grant execute on function public.get_registration_form(text)                     to anon, authenticated;
grant execute on function public.submit_registration(text,text,text,text,text,date,uuid,text) to anon, authenticated;


-- ============================================================================
--  SANITY CHECKS
--
--  1) exactly ONE approve_registration exists, with five parameters.
--     Two rows here is the overload trap and WILL break the Approve button:
--       select p.oid::regprocedure as signature
--         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--        where n.nspname = 'public' and p.proname = 'approve_registration';
--
--  2) it is callable by logged-in owners, and by nobody else:
--       select has_function_privilege('authenticated',
--         'public.approve_registration(uuid,text,text,uuid,text)', 'execute') as owner_ok,
--              has_function_privilege('anon',
--         'public.approve_registration(uuid,text,text,uuid,text)', 'execute') as anon_ok;
--     Expect owner_ok = true, anon_ok = false.
--
--  3) your levels are what the picker will offer — id, name and fee:
--       select jsonb_pretty(levels) from public.businesses;
--
--  4) end to end, from the app: approve a pending registration with a level
--     chosen, then confirm the snapshot landed on the student rather than a
--     null:
--       select name, level from public.cards order by created_at desc limit 1;
--     Expect something like {"id": "...", "name": "Medium", "fee": 60}.
--     Their stamp card's "Monthly Fee" should then read €60, not the default.
--
--  ROLLBACK (returns approve_registration to the four-argument version that
--  always wrote a null level):
--       drop function if exists public.approve_registration(uuid,text,text,uuid,text);
--     then re-run the approve_registration block from
--     supabase/migration-self-registration.sql.
-- ============================================================================
