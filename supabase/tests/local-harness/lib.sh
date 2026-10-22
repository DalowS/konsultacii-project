#!/bin/bash
# Общи функции за ЛОКАЛЕН PostgreSQL стенд (НЕ е Supabase!). Нужен е достъпен PostgreSQL >= 14.
# Променливи: PGHOST (по подр. /var/tmp/pgtest), PGPORT (5444), PGUSER (postgres).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MIG="$REPO/supabase/migrations"
export PGHOST="${PGHOST:-/var/tmp/pgtest}" PGPORT="${PGPORT:-5444}" PGUSER="${PGUSER:-postgres}"
export PGOPTIONS="-c client_min_messages=warning"
P="psql -v ON_ERROR_STOP=1 -q"
OLD_MIGRATIONS="20260101000000 20261006000000 20261007000000 20261008000000 20261009000000 20261010000000 20261011000000"
NEW_MIGRATIONS="20261012000000 20261013000000 20261014000000"
mkdb()   { dropdb --if-exists "$1" 2>/dev/null; createdb "$1"; $P -d "$1" -f "$HERE/stub.sql" 2>&1 | grep -v "wal_level\|HINT" ; }
apply()  { for f in $2; do $P -d "$1" -f "$MIG/${f}_"*.sql >/dev/null || { echo "ГРЕШКА при $f"; return 1; }; done; }
q()      { psql -d "$1" -Atq -c "$2"; }
