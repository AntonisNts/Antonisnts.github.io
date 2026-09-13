#!/bin/bash
# Run every SQL suite, each against a freshly rebuilt replica.
#
# The rebuild between suites is the whole point. The suites share fixture ids
# and none of them clean up after the others, so running them back to back in
# one database makes later ones fail on rows an earlier one left behind. That
# is what the "three undiagnosed replica failures" turned out to be -- not
# product bugs, just a dirty database.
#
# Verdicts are the `pass` column of each SELECT: t or f.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
D=/var/lib/postgresql/regtest
export PGHOST=$D PGPORT=5433 PGUSER=postgres PGDATABASE=stampcard

only="${1:-}"          # optional: run one suite, e.g. ./run-tests.sh self-registration
total_p=0; total_f=0; failed=()

for t in test-*.sql; do
  [ -n "$only" ] && [[ "$t" != *"$only"* ]] && continue

  ./rebuild-replica.sh >/dev/null || { echo "replica rebuild FAILED"; exit 1; }
  out=$(psql -q -f "$t" 2>&1)

  p=$(echo "$out" | grep -cE '\|[[:space:]]*t[[:space:]]*(\||$)')
  f=$(echo "$out" | grep -cE '\|[[:space:]]*f[[:space:]]*(\||$)')
  total_p=$((total_p + p)); total_f=$((total_f + f))

  printf '%-38s pass=%-4s fail=%s\n' "$t" "$p" "$f"
  if [ "$f" -gt 0 ]; then
    failed+=("$t")
    echo "$out" | grep -E '\|[[:space:]]*f[[:space:]]*(\||$)' | sed 's/^/    /'
  fi
done

echo "------------------------------------------------------------"
printf 'TOTAL  pass=%s  fail=%s\n' "$total_p" "$total_f"
if [ "$total_f" -gt 0 ]; then
  printf 'suites with failures: %s\n' "${failed[*]}"
  exit 1
fi
