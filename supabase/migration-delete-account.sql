-- ============================================================================
--  Migration: GDPR account deletion (right to erasure)
--  Run ONCE in the Supabase SQL editor (as the postgres role — the default
--  there). Adds two SECURITY DEFINER RPCs that let a signed-in user delete
--  their OWN account and the associated data, including their auth.users row
--  so the email can be re-registered. Nothing runs automatically — the app
--  only calls these after the user explicitly confirms in the UI.
--
--  Why SECURITY DEFINER + delete from auth.users: the browser holds only the
--  publishable/anon key and cannot use the admin API. These functions run as
--  their owner (postgres), which can remove the auth row. Each function only
--  ever touches the caller's own data (keyed off auth.uid() / auth.email()).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Flow 1 — Business owner deletes their account.
-- Deletes, in order: parent links to this owner's cards, the cards themselves
-- (payments + history are columns ON the card, so they go with it), the
-- business record, then the auth user. (FKs already cascade owner -> business
-- -> cards -> card_links; the explicit deletes make the GDPR order auditable
-- and independent of cascade config.)
-- ---------------------------------------------------------------------------
create or replace function public.delete_my_business_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  delete from public.card_links cl
    using public.cards c, public.businesses b
    where cl.card_id = c.id
      and c.business_id = b.id
      and b.owner_id = v_uid;

  delete from public.cards c
    using public.businesses b
    where c.business_id = b.id
      and b.owner_id = v_uid;

  delete from public.businesses where owner_id = v_uid;

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_business_account() from public, anon;
grant execute on function public.delete_my_business_account() to authenticated;

-- ---------------------------------------------------------------------------
-- Flow 2 — Parent deletes their family account.
-- Deletes ONLY the parent's own data: their card links and child groupings,
-- then the auth user. Student cards, payments and businesses belong to the
-- schools and are NEVER touched here.
-- ---------------------------------------------------------------------------
create or replace function public.delete_my_family_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := auth.email();
begin
  if v_uid is null then
    raise exception 'not authenticated';
  end if;

  delete from public.card_links where parent_email = v_email;
  delete from public.children   where parent_email = v_email;

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_family_account() from public, anon;
grant execute on function public.delete_my_family_account() to authenticated;

-- ============================================================================
--  Notes:
--  * If your project restricts postgres from deleting auth.users, run these in
--    the SQL editor (which executes as postgres) — that is the supported path.
--  * No business/student/payment data is touched by the parent flow.
--  * Sanity check (as a normal signed-in user, the RPCs only erase self):
--      select proname, prosecdef from pg_proc
--      where proname in ('delete_my_business_account','delete_my_family_account');
-- ============================================================================
