-- ============================================================================
--  Migration: owner-chosen accent colour  (PART A of B)
--  ----------------------------------------------------------------------------
--  Until now a business's colour was derived from its CATEGORY (Swimming ->
--  sky, Music -> mint, ...). A school whose category is "Other" was stuck with
--  violet and could only change colour by mis-stating what it teaches. This
--  lets the owner pick.
--
--  The value is a THEME KEY ("mint", "sky", "green", ...), not a hex colour.
--  The four coordinated colours each key stands for -- accent, the two stamp
--  card gradient stops, and the paid-cell fill -- live in the app (THEMES in
--  app/index.html), so they can be retuned later without touching any data.
--
--  ADDITIVE AND REVERSIBLE: one nullable column. No existing column, table,
--  policy or function is altered, and no row is read, modified or deleted.
--  NULL means "no theme chosen", which the app resolves to the category
--  palette -- exactly today's behaviour. Nothing changes visually for anyone
--  until an owner picks a colour.
--
--  No GRANT is needed. This schema grants privileges at TABLE level
--  ("grant select, insert, update, delete on all tables ...", schema.sql:431),
--  and table-level privileges cover columns added later. That is why the
--  teachers/groups migration needed an explicit grant -- it added a new TABLE,
--  which the one-time snapshot had never seen -- and this one does not.
--  RLS is unaffected: the policies on businesses are row-level.
--
--  Run ONCE in the Supabase SQL editor.
-- ============================================================================

alter table public.businesses
  add column if not exists accent text;

comment on column public.businesses.accent is
  'Owner-chosen accent theme key (see THEMES in app/index.html). NULL = fall back to the category palette.';

-- ============================================================================
--  Sanity checks:
--
--    -- 1) the column exists and every existing business is NULL (unchanged)
--    select count(*) as businesses,
--           count(accent) as with_a_theme      -- expect with_a_theme = 0
--      from public.businesses;
--
--    -- 2) you can write it
--    select id, name, accent from public.businesses limit 5;
--
--  After this, the OWNER side works: Settings -> Colour, pick, save.
--  Parents and students keep seeing the category colour until PART B, which
--  adds the field to get_my_cards() and get_student_card().
--
--  PART B has to be written against the definitions that are actually LIVE.
--  The functions in this repo are OUT OF DATE -- the groups/teachers work was
--  pasted straight into Supabase and never committed here, so the live
--  get_my_cards() returns an inline `group` object that no file here mentions.
--  Re-creating them from these files would silently revert group support.
--  Dump the live definitions first:
--
--    select p.proname, pg_get_functiondef(p.oid)
--      from pg_proc p
--      join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('get_my_cards', 'get_student_card');
--
--  ROLLBACK (removes only this column and any chosen themes):
--    alter table public.businesses drop column if exists accent;
-- ============================================================================
