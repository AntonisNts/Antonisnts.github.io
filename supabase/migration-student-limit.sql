-- ===========================================================================
--  Student limit per plan  (issue #142)
--  ---------------------------------------------------------------------------
--  Pricing sells on student count alone -- every plan is the complete app --
--  but nothing enforced it. A Starter school could add 500 students.
--
--  Additive and idempotent. No DROP TABLE, no DELETE, no data migration.
--  Safe to run on the live project; safe to re-run.
--
--  Decisions this implements:
--    * plan is set by hand (no billing system yet)
--    * at the limit, adding is refused; students already there are untouched
--      and stay fully usable -- nobody loses access to records they created
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  1. The plan column
--
--  Added with default 'unlimited' so every school that already exists is
--  grandfathered -- nobody wakes up capped. THEN the default flips to
--  'starter', so only schools created from now on get a limit.
--
--  Doing it in that order is also what makes the file idempotent: re-running
--  it cannot flip a real Starter school to unlimited, which a plain
--  `update ... set plan='unlimited'` would do on every re-run.
-- ---------------------------------------------------------------------------

alter table public.businesses
  add column if not exists plan text not null default 'unlimited';

alter table public.businesses
  alter column plan set default 'starter';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'businesses_plan_check') then
    alter table public.businesses
      add constraint businesses_plan_check
      check (plan in ('starter','growth','pro','unlimited'));
  end if;
end $$;

comment on column public.businesses.plan is
  'starter=25, growth=80, pro=200, unlimited=no cap. Set by hand; owners cannot change it.';


-- ---------------------------------------------------------------------------
--  2. Owners must not be able to upgrade themselves
--
--  businesses_update_own lets the owner update their row and says nothing
--  about WHICH columns, so without this an owner could simply PATCH
--  plan='unlimited' with the publishable key and the limit would be theatre.
--
--  Postgres treats a table-level UPDATE grant as covering every column and a
--  column-level revoke cannot carve one out of it, so the table grant is
--  withdrawn and re-issued per column. The list is exactly what the app
--  writes today (name, accent, icon, custom_card_image, inactive_months,
--  levels, year) plus the three a settings screen would reasonably add.
--
--  Deliberately excluded: plan, approval_status, owner_id, biz_code, id,
--  created_at.
-- ---------------------------------------------------------------------------

revoke update on public.businesses from authenticated;

grant update (
  name, type, fee, year, contact_email,
  inactive_months, levels, custom_card_image, accent, icon
) on public.businesses to authenticated;


-- ---------------------------------------------------------------------------
--  3. The limit itself
--
--  AFTER ... FOR EACH STATEMENT with a transition table, not BEFORE ... FOR
--  EACH ROW. A row-level BEFORE trigger cannot see the other rows of its own
--  INSERT, so a bulk import of 100 students into an empty Starter school
--  would count 0 every time and let all 100 through -- defeating the limit on
--  one of the two ways over it.
--
--  Running after the statement means the count already includes the new rows,
--  so the comparison is `> limit`, and raising here rolls the whole statement
--  back. A bulk import that would breach the cap fails entirely rather than
--  landing half a class, which matches how the importer already behaves.
--
--  One trigger covers every path into cards -- adding a student, the bulk
--  importer, and approve_registration -- including any added later.
-- ---------------------------------------------------------------------------

create or replace function public.enforce_student_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r       record;
  v_plan  text;
  v_limit int;
  v_count int;
begin
  for r in select distinct business_id from new_rows loop
    select plan into v_plan from public.businesses where id = r.business_id;

    v_limit := case coalesce(v_plan, 'unlimited')
                 when 'starter' then 25
                 when 'growth'  then 80
                 when 'pro'     then 200
                 else null                      -- unlimited
               end;
    continue when v_limit is null;

    select count(*) into v_count from public.cards where business_id = r.business_id;

    if v_count > v_limit then
      -- Worded for a human: this text reaches the owner through the app's
      -- existing error toast, so no frontend change is needed.
      raise exception
        'Your % plan covers % students. Remove a student, or move to a larger plan to add more.',
        initcap(v_plan), v_limit
        using errcode = 'P0001';
    end if;
  end loop;
  return null;
end;
$$;

revoke all on function public.enforce_student_limit() from public, anon, authenticated;

drop trigger if exists cards_enforce_student_limit on public.cards;
create trigger cards_enforce_student_limit
  after insert on public.cards
  referencing new table as new_rows
  for each statement
  execute function public.enforce_student_limit();


-- ---------------------------------------------------------------------------
--  Changing a school's plan (this is the whole admin interface)
--
--    update public.businesses set plan = 'growth' where biz_code = 'BIZ-XXXX';
--
--  Seeing where everyone sits:
--
--    select b.biz_code, b.name, b.plan, count(c.id) as students
--      from public.businesses b
--      left join public.cards c on c.business_id = b.id
--     group by b.id order by b.name;
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
--  ROLLBACK (only if needed)
--
--    drop trigger if exists cards_enforce_student_limit on public.cards;
--    drop function if exists public.enforce_student_limit();
--    grant update on public.businesses to authenticated;
--    -- the plan column is harmless to leave in place
-- ---------------------------------------------------------------------------
