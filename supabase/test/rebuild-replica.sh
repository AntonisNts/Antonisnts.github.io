#!/bin/bash
# Rebuild a faithful replica of the live StampCard database from an empty one,
# so every test run starts from the same state.
set -e
D=${PGSOCKDIR:-/var/lib/postgresql/regtest}
S="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST=$D PGPORT=5433 PGUSER=postgres

psql -q -d postgres -c "drop database if exists stampcard;"
psql -q -d postgres -c "create database stampcard;"
export PGDATABASE=stampcard

# Supabase ships these roles; a bare cluster does not. Create them if missing
# so the script works on a fresh Postgres as well as a warmed-up one.
psql -q -d postgres <<'SQL'
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon')          then create role anon nologin;          end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role')  then create role service_role nologin;  end if;
end $$;
SQL

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
-- pgcrypto goes in its OWN schema, because that is where Supabase puts it.
-- Installed into public instead, this replica silently accepts a function
-- pinned to `set search_path = public` that calls gen_random_bytes() or
-- hmac() -- and the live project then rejects it with "function does not
-- exist". That is exactly how the Tap to Pay token generator reached
-- production broken. Creating it here first means schema.sql's own
-- `create extension if not exists pgcrypto` finds it already present and
-- leaves it where it is.
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create extension if not exists pgcrypto with schema extensions;
SQL

# Every migration, in the order the live database received them. Order matters
# in two places: groups/teachers has to precede self-registration (which reads
# public.groups), and the three files that redefine get_my_cards /
# get_student_card have to run oldest-first so icon-part-b wins.
#
# teachers/groups used to be inlined here as "the June migration that lives
# only in the database, never committed" -- it is committed now, so the real
# file is loaded instead. cards.group_name and cards.lesson_schedule come from
# migration-flip-card.sql above it, which is why that file is not in it.
n=0
for f in schema.sql migration-add-phone.sql migration-approval-gate.sql \
         migration-parent-portal.sql migration-child-grouping.sql \
         migration-plaintext-pins.sql migration-security-hardening.sql \
         migration-flip-card.sql migration-fee-history.sql \
         migration-paused-months.sql migration-enrollment-receipts.sql \
         migration-announcements.sql migration-announcement-reads.sql \
         migration-delete-account.sql migration-business-accent.sql \
         migration-groups-teachers.sql migration-groups-teachers-grants.sql \
         migration-self-registration.sql migration-registration-level.sql \
         migration-announcement-targeting.sql \
         migration-business-accent-part-b.sql \
         migration-business-icon.sql migration-business-icon-part-b.sql \
         migration-registration-throttle.sql migration-student-limit.sql \
         migration-family-export.sql migration-stamp-confirm.sql \
         migration-stamp-geometry.sql migration-stamp-rotation.sql \
         migration-stamp-student.sql migration-stamp-auto.sql \
         migration-payment-link.sql \
         migration-stamp-owner-fix.sql migration-shop.sql \
         migration-push.sql; do
  # Show the real error rather than swallowing it -- a silent "FAILED: x.sql"
  # tells you nothing about which statement broke.
  if ! psql -q -v ON_ERROR_STOP=1 -f "$S/$f" >/tmp/replica-$$.log 2>&1; then
    echo "FAILED: $f"; sed 's/^/    /' /tmp/replica-$$.log | head -5; rm -f /tmp/replica-$$.log; exit 1
  fi
  n=$((n+1))
done
rm -f /tmp/replica-$$.log

echo "replica rebuilt ($(ls "$S"/*.sql | wc -l) SQL files present, $n applied in order)"
