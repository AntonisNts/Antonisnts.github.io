-- ============================================================================
--  Migration: bcrypt-hashed PINs  ->  plain-text PINs  (+ role grants)
--  Run this ONCE in the Supabase SQL editor on an existing project that was
--  created with the original schema. Fresh installs of schema.sql already
--  include all of this and do NOT need it.
-- ============================================================================

-- 1. Remove the old hashing trigger + function.
drop trigger  if exists cards_hash_pin on public.cards;
drop function if exists public.hash_card_pin();

-- 2. Switch the cards table to a plain-text PIN.
--    The old trigger wiped plaintext PINs to NULL, so existing (test) cards
--    have no recoverable PIN — backfill them to '0000' so they stay usable.
--    Tell those students their PIN is 0000, or delete & re-add them.
update public.cards set pin = '0000' where pin is null;
alter table public.cards alter column pin set not null;
alter table public.cards drop column if exists pin_hash;

-- 3. Replace the student-access function with plain-text PIN comparison
--    (the old version called crypt(), which errored: "function crypt does not exist").
create or replace function public.get_student_card(p_code text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cards%rowtype;
  b public.businesses%rowtype;
begin
  select * into c from public.cards where share_code = upper(trim(p_code)) limit 1;
  if not found then
    return null;
  end if;
  if c.pin is null or c.pin <> p_pin then
    return null;
  end if;

  select * into b from public.businesses where id = c.business_id;

  return jsonb_build_object(
    'business', jsonb_build_object(
      'name', b.name, 'type', b.type, 'fee', b.fee, 'year', b.year,
      'biz_code', b.biz_code, 'inactive_months', b.inactive_months,
      'levels', b.levels, 'custom_card_image', b.custom_card_image),
    'card', jsonb_build_object(
      'name', c.name, 'level', c.level, 'share_code', c.share_code,
      'payments', c.payments, 'history', c.history)
  );
end;
$$;

revoke all on function public.get_student_card(text, text) from public;
grant  execute on function public.get_student_card(text, text) to anon, authenticated;

-- 4. Role grants (these are what fixed registration failing).
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to anon, authenticated;
