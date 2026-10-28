#!/usr/bin/env bash
# Rejoue la sauvegarde v1, la reconstruction v2, puis la configuration RLS, dans un Postgres
# local jetable, et lance les tests. Rien n'est envoyé vers Supabase.
# Usage : supabase/brouillons/tests/lancer_tests.sh  (PostgreSQL 16+, utilisateur non root)
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="$ICI/../../.."
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
TMP="$(mktemp -d)"
trap '"$PGBIN/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -o "-k $TMP -c listen_addresses=''" -l "$TMP/log" start >/dev/null
export PGHOST="$TMP" PGUSER=postgres PGDATABASE=postgres
executer() { psql -q -v ON_ERROR_STOP=1 "$@"; }

executer -f "$ICI/stubs_supabase.sql"
# Sauvegarde v1 (pgvector absent en local : type remplacé par le stub)
sed -e 's/extensions\.vector(1024)/extensions.vector/g' -e '/USING hnsw/d' \
    "$RACINE/sauvegarde/2026-10-28_schema_v1/schema.sql" | executer -f -
executer -f "$RACINE/sauvegarde/2026-10-28_schema_v1/donnees_reference.sql"
executer -f "$ICI/tests_sauvegarde_v1.sql"
# Reconstruction
executer -f "$RACINE/supabase/brouillons/v2_01_archiver_v1.sql"
executer -f "$RACINE/supabase/brouillons/v2_02_schema_cible.sql"
executer -f "$RACINE/supabase/brouillons/v2_03_donnees_initiales.sql"
executer -f "$RACINE/supabase/migrations/20261028155725_v2_04_sources_retenues.sql"
executer -f "$RACINE/supabase/brouillons/v2_05_pipeline_ia.sql"
# État 1 : base fermée, avant la configuration manuelle des RLS
executer -f "$ICI/tests_base_fermee.sql"
executer -f "$ICI/comptes_test_sql_editor.sql"
sql_editor() {  # rejoue le script destiné au SQL Editor de Supabase et contrôle son tableau
  { echo "set demelo.etat = '$1';"; echo '\o /dev/null'; cat "$RACINE/supabase/rls_manuel/tests_sql_editor.sql" "$ICI/verifier_sql_editor.sql"; } \
    | executer -f -
}
sql_editor ferme
# État 2 : après la configuration manuelle (le fichier est rejoué ici pour le test)
executer -f "$RACINE/supabase/rls_manuel/policies_et_grants.sql"
sql_editor configure
executer -f "$ICI/tests_v3_pipeline.sql"
# Données fictives : 500 lignes, invisibles du public
executer -o /dev/null -f "$RACINE/supabase/donnees/donnees_fictives.sql"
executer -o /dev/null -f "$RACINE/supabase/donnees/donnees_fictives.sql"   # rejouable sans doublon
psql -At -v ON_ERROR_STOP=1 <<'SQL'
do $$ begin
  if (select count(*) from public.contenus where est_test and lot_import = 'fictif-v1') <> 500 then
    raise exception 'Données fictives : 500 lignes attendues.';
  end if;
end $$;
select set_config('request.jwt.claims', '{"role": "anon"}', false);
set role anon;
do $$ begin
  if exists (select 1 from public.contenus where est_test) or exists (select 1 from public.v_feed_verifie where domaine_origine like '%.invalid') then
    raise exception 'Données fictives visibles du public.';
  end if;
  raise notice 'Données fictives : 500 lignes, rejouable, invisibles du public.';
end $$;
SQL
