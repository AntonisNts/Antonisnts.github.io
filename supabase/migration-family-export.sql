-- ===========================================================================
--  Family data export  (GDPR Article 20, portability)
--  ---------------------------------------------------------------------------
--  A business can export everything. A family had no way to obtain their own
--  data at all -- they could delete it, but not see it.
--
--  Additive and idempotent. Creates one read-only function. No table changes,
--  no data migration. Safe to run on the live project; safe to re-run.
-- ===========================================================================


-- ---------------------------------------------------------------------------
--  export_my_family_data()
--
--  Returns everything held about the calling parent, and nothing else.
--
--  Scoped exactly like get_my_cards: the parent's own email is taken from the
--  session, never from an argument, so there is no parameter to tamper with
--  and one family cannot request another's data.
--
--  What is deliberately NOT included, because it is the school's and not the
--  family's: the student's PIN, the school's own contact email, its fee
--  schedule and levels, and anything about other students. The share code IS
--  included -- the parent already has it, it is how they open the card.
-- ---------------------------------------------------------------------------

create or replace function public.export_my_family_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := auth.email();
  v_uid   uuid := auth.uid();
begin
  if v_email is null then
    return jsonb_build_object('error', 'not_authenticated');
  end if;

  return jsonb_build_object(
    'exported_at', now(),
    'about',       'Everything PayStamp holds about this family account.',
    'account', jsonb_build_object(
      'email', v_email
    ),

    -- Children the parent created to group their cards.
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name',       ch.name,
               'created_at', ch.created_at)
             order by ch.created_at)
        from public.children ch
       where ch.parent_email = v_email
    ), '[]'::jsonb),

    -- Every card they have linked, with its payment record.
    'students', coalesce((
      select jsonb_agg(jsonb_build_object(
               'name',             c.name,
               'school',           b.name,
               'level',            c.level,
               'share_code',       c.share_code,
               'enrolled_from',    c.enrollment_start_month,
               'paused_months',    c.paused_months,
               'payments',         c.payments,
               'payment_history',  c.history,
               'linked_on',        cl.created_at,
               'grouped_under',    (select ch.name from public.children ch
                                     where ch.id = cl.child_id))
             order by c.name)
        from public.card_links cl
        join public.cards c      on c.id = cl.card_id
        join public.businesses b on b.id = c.business_id
       where cl.parent_email = v_email
    ), '[]'::jsonb),

    -- Announcements they were shown, so the record is complete.
    'announcements_received', coalesce((
      select jsonb_agg(distinct jsonb_build_object(
               'school',     b.name,
               'title',      a.title,
               'body',       a.body,
               'created_at', a.created_at))
        from public.announcements a
        join public.businesses b on b.id = a.business_id
       where a.is_active
         and (a.expires_at is null or a.expires_at > now())
         and a.business_id in (
               select c.business_id
                 from public.card_links cl
                 join public.cards c on c.id = cl.card_id
                where cl.parent_email = v_email)
    ), '[]'::jsonb),

    'note', 'Payment records belong to the school and are kept by them. '
         || 'Deleting this account removes your login and unlinks these '
         || 'students; it does not erase the school''s own records.'
  );
end;
$$;

revoke all on function public.export_my_family_data() from public, anon;
grant execute on function public.export_my_family_data() to authenticated;


-- ---------------------------------------------------------------------------
--  ROLLBACK (only if needed)
--
--    drop function if exists public.export_my_family_data();
-- ---------------------------------------------------------------------------
