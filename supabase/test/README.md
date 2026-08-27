# Testing a migration before it touches the live database

The Supabase project is production, it serves both paystamp.app and the staging
site, and **it has no backups**. So a migration should be run somewhere
disposable first.

These two files build that disposable copy.

## What the replica is

`rebuild-replica.sh` creates an empty PostgreSQL database and replays, in order:

1. a few lines of Supabase-shaped scaffolding — the `anon`, `authenticated` and
   `service_role` roles, `auth.uid()`, `auth.email()`, and stub `auth`/`storage`
   schemas, which is all our SQL actually depends on;
2. `schema.sql` and every committed migration;
3. **the June groups/teachers migration, which exists only in the live
   database** — it was pasted into the Supabase SQL editor and never committed.
   The DDL here was dumped out of the running project. This is the part that
   makes the replica faithful rather than merely plausible, and it is the reason
   two earlier migrations nearly reverted group support by accident.

If you change the schema, keep step 3 in sync or the replica stops being worth
anything.

## Running it

```bash
sudo apt-get install -y postgresql          # 16 is fine
D=/var/lib/postgresql/regtest               # must be readable by the postgres user
mkdir -p $D && chown postgres:postgres $D
su postgres -c "/usr/lib/postgresql/16/bin/initdb -D $D/data -U postgres --auth=trust"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D $D/data -o '-p 5433 -k $D' -l $D/log start"

export PGHOST=$D PGPORT=5433 PGUSER=postgres
bash supabase/test/rebuild-replica.sh
PGDATABASE=stampcard psql -f supabase/migration-self-registration.sql
PGDATABASE=stampcard psql -f supabase/test/test-self-registration.sql
```

Every check prints `t` for pass. The `permission denied` errors in section B are
the point of that section — they are anon being correctly refused.

## The two checks worth doing for any migration

Behaviour aside, these are what protect a database with no undo. Dump the
schema either side of the run:

```bash
pg_dump -s -d stampcard > before.sql
PGDATABASE=stampcard psql -f supabase/your-migration.sql
pg_dump -s -d stampcard > after.sql
diff before.sql after.sql | grep '^<'      # must show nothing but trailing commas
```

Anything else on a `<` line means the migration drops, rewrites or
re-permissions something that already exists — which on this project is the
failure mode to be afraid of.

Then run the migration's own ROLLBACK block and diff again: a rollback that
works returns the schema byte-for-byte to `before.sql`.

## What this does not cover

The replica has the live *schema*, not the live *data* or the live PostgREST
layer. Two things can only be checked against the real project:

- whether `request.headers` carries `x-forwarded-for` (see sanity check 4 in the
  self-registration migration);
- anything depending on real row volumes.
