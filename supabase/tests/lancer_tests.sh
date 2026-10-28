#!/usr/bin/env bash
# Teste la migration dans un Postgres local jetable (sans Supabase).
# Usage : supabase/tests/lancer_tests.sh   (nécessite les binaires PostgreSQL 16)
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
MIGRATION="$ICI/../migrations/20261028150000_init_fact_checking.sql"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
TMP="$(mktemp -d)"
trap '"$PGBIN/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -o "-k $TMP -c listen_addresses=''" -l "$TMP/log" start >/dev/null
export PGHOST="$TMP" PGUSER=postgres PGDATABASE=postgres

psql -q -v ON_ERROR_STOP=1 -f "$ICI/stubs_supabase.sql"
# Les extensions absentes en local sont remplacées par les stubs.
sed -e '/create extension if not exists/d' \
    -e 's/extensions\.vector(1024)/extensions.vector/g' \
    -e '/using hnsw/d' \
    "$MIGRATION" | psql -q -v ON_ERROR_STOP=1 -f -
psql -q -v ON_ERROR_STOP=1 -f "$ICI/tests_migration.sql"
