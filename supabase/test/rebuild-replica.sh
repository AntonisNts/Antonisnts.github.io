#!/bin/bash
# Rebuild a faithful replica of the live StampCard database from an empty one,
# so every test run starts from the same state.
set -e
D=/var/lib/postgresql/regtest
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=$D PGPORT=5433 PGUSER=postgres

psql -q -d postgres -c "drop database if exists stampcard;"
psql -q -d postgres -c "create database stampcard;"
export PGDATABASE=stampcard

psql -q -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
create schema if not exists storage;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
create table storage.buckets (id text primary key, name text, public boolean default false);
create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create function auth.email() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.email', true), '') $$;
grant usage on schema auth, storage to anon, authenticated, service_role;
create extension if not exists pgcrypto;
SQL

for f in schema.sql migration-add-phone.sql migration-approval-gate.sql \
         migration-parent-portal.sql migration-child-grouping.sql \
         migration-plaintext-pins.sql migration-security-hardening.sql \
         migration-flip-card.sql migration-fee-history.sql \
         migration-paused-months.sql migration-enrollment-receipts.sql \
         migration-announcements.sql migration-announcement-reads.sql \
         migration-delete-account.sql migration-business-accent.sql; do
  psql -q -v ON_ERROR_STOP=1 -f "$S/$f" >/dev/null 2>&1 || { echo "FAILED: $f"; exit 1; }
done

# The June migration that lives only in the database, never committed.
psql -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
create table public.teachers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null, created_at timestamptz not null default now());
create table public.groups (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null, schedule jsonb not null default '[]'::jsonb,
  teacher_id uuid references public.teachers(id) on delete set null,
  created_at timestamptz not null default now());
alter table public.cards add column if not exists group_id uuid references public.groups(id) on delete set null;
alter table public.cards add column if not exists group_name text;
alter table public.cards add column if not exists lesson_schedule jsonb not null default '[]'::jsonb;
alter table public.groups enable row level security;
alter table public.teachers enable row level security;
create policy groups_all_own on public.groups for all
  using (exists (select 1 from public.businesses b where b.id = groups.business_id and b.owner_id = auth.uid()))
  with check (exists (select 1 from public.businesses b where b.id = business_id and b.owner_id = auth.uid()));
create policy teachers_all_own on public.teachers for all
  using (exists (select 1 from public.businesses b where b.id = teachers.business_id and b.owner_id = auth.uid()))
  with check (exists (select 1 from public.businesses b where b.id = business_id and b.owner_id = auth.uid()));
grant select, insert, update, delete on public.groups, public.teachers to authenticated;
SQL

psql -q -v ON_ERROR_STOP=1 -f "$S/migration-business-accent-part-b.sql" >/dev/null 2>&1 || { echo "FAILED: part-b"; exit 1; }
echo "replica rebuilt"
