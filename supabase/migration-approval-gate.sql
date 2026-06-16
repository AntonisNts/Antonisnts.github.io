-- ============================================================================
--  Migration: admin approval gate for new registrations
--  Run ONCE in the Supabase SQL editor. Order is deliberate and lockout-safe:
--  existing accounts are set to 'approved' BEFORE the RLS gate is enforced.
--  Does NOT touch student or payment data.
-- ============================================================================

-- 1. Add the column. The default backfills EXISTING rows as 'pending'...
alter table public.businesses
  add column if not exists approval_status text not null default 'pending'
  check (approval_status in ('pending','approved','rejected'));

-- 2. CRITICAL — ...so immediately approve ALL currently-existing accounts
--    (including your owner account) so nobody using the app is locked out.
--    This runs BEFORE the gate policies below are created.
update public.businesses set approval_status = 'approved';

-- 3. get_my_approval(): lets a logged-in owner read their OWN status even
--    though the gate (below) hides unapproved business rows. SECURITY DEFINER
--    bypasses RLS but only ever returns the caller's own status. null = the
--    caller owns no business (e.g. a parent account).
create or replace function public.get_my_approval()
returns text language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  select approval_status into v_status
    from public.businesses where owner_id = auth.uid()
    order by created_at limit 1;
  return v_status;
end;
$$;
revoke all on function public.get_my_approval() from public, anon;
grant execute on function public.get_my_approval() to authenticated;

-- 4. Enforce the gate in RLS (database-level, not just UI). Only 'approved'
--    businesses can be read or written. New signups may still INSERT a
--    'pending' business (so it exists for you to approve) but cannot
--    self-approve.
drop policy if exists businesses_select_own on public.businesses;
create policy businesses_select_own on public.businesses
  for select using (owner_id = auth.uid() and approval_status = 'approved');

drop policy if exists businesses_insert_own on public.businesses;
create policy businesses_insert_own on public.businesses
  for insert with check (owner_id = auth.uid() and approval_status = 'pending');

drop policy if exists businesses_update_own on public.businesses;
create policy businesses_update_own on public.businesses
  for update using (owner_id = auth.uid() and approval_status = 'approved')
            with check (owner_id = auth.uid() and approval_status = 'approved');

drop policy if exists businesses_delete_own on public.businesses;
create policy businesses_delete_own on public.businesses
  for delete using (owner_id = auth.uid() and approval_status = 'approved');

-- Cards: gate on the parent business being approved too (defense in depth).
drop policy if exists cards_select_own on public.cards;
create policy cards_select_own on public.cards
  for select using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists cards_insert_own on public.cards;
create policy cards_insert_own on public.cards
  for insert with check (exists (
    select 1 from public.businesses b
    where b.id = business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists cards_update_own on public.cards;
create policy cards_update_own on public.cards
  for update using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

drop policy if exists cards_delete_own on public.cards;
create policy cards_delete_own on public.cards
  for delete using (exists (
    select 1 from public.businesses b
    where b.id = cards.business_id and b.owner_id = auth.uid() and b.approval_status = 'approved'));

-- ============================================================================
--  To approve an account later: in the dashboard, Table editor -> businesses,
--  set approval_status = 'approved' (or run:
--    update public.businesses set approval_status='approved' where biz_code='BIZ-XXXX';
--  ). To reject: set 'rejected'.
--  Sanity check:  select biz_code, name, approval_status from public.businesses;
-- ============================================================================
