#!/usr/bin/env bash
# Exécution réelle et contrôlée du collecteur : vrai Postgres local (schéma Démêlo complet,
# rôle demelo_pipeline), vrai serveur HTTP de flux, deux collectes successives.
# Usage : collecte/tests/test_local.sh   (PostgreSQL 16+, Node 20+, utilisateur non root)
set -euo pipefail
ICI="$(cd "$(dirname "$0")" && pwd)"
RACINE="$ICI/../.."
NODE="${NODE:-$(command -v node || echo /opt/node22/bin/node)}"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
TMP="$(mktemp -d)"
PORT=8765
trap 'kill $SERVEUR 2>/dev/null || true; "$PGBIN/pg_ctl" -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

"$PGBIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PGBIN/pg_ctl" -D "$TMP/data" -o "-k $TMP -c listen_addresses=''" -l "$TMP/log" start >/dev/null
export PGHOST="$TMP" PGUSER=postgres PGDATABASE=postgres
executer() { psql -q -v ON_ERROR_STOP=1 "$@"; }
valeur() { psql -At -v ON_ERROR_STOP=1 -c "$1"; }

# Schéma : sauvegarde v1 puis reconstruction v2 et pipeline (v2_05)
executer -f "$RACINE/supabase/brouillons/tests/stubs_supabase.sql"
sed -e 's/extensions\.vector(1024)/extensions.vector/g' -e '/USING hnsw/d' \
    "$RACINE/sauvegarde/2026-10-28_schema_v1/schema.sql" | executer -o /dev/null -f -
executer -f "$RACINE/sauvegarde/2026-10-28_schema_v1/donnees_reference.sql" >/dev/null
for f in "$RACINE/supabase/brouillons/v2_01_archiver_v1.sql" "$RACINE/supabase/brouillons/v2_02_schema_cible.sql" \
         "$RACINE/supabase/brouillons/v2_03_donnees_initiales.sql" "$RACINE/supabase/migrations/20261028155725_v2_04_sources_retenues.sql" \
         "$RACINE/supabase/migrations/20261028165254_v2_05_pipeline_ia.sql"; do
  executer -o /dev/null -f "$f"
done
executer -c "alter role demelo_pipeline login"
# Une donnée fictive existante : la collecte ne doit jamais la toucher.
executer -c "insert into public.contenus (media_nom, titre, url_originale, est_test, vu_le)
             values ('Média fictif', '[FICTIF] Témoin', 'https://temoin.invalid/1', true, '2026-01-01')"

"$NODE" "$ICI/serveur_flux.mjs" $PORT & SERVEUR=$!
sleep 1
URL_PIPELINE="postgresql://demelo_pipeline@localhost/postgres?host=$TMP"
cat > "$TMP/flux1.json" <<JSON
{ "flux": [
  { "media": "Le Monde",   "url": "http://127.0.0.1:$PORT/lemonde.xml",  "domaine": "lemonde.fr" },
  { "media": "20 Minutes", "url": "http://127.0.0.1:$PORT/atom.xml",     "domaine": "20minutes.fr" },
  { "media": "Le Parisien", "url": "http://127.0.0.1:$PORT/leparisien.xml", "domaine": "leparisien.fr" },
  { "media": "Cassé",      "url": "http://127.0.0.1:$PORT/errone.xml",   "domaine": "exemple.fr" },
  { "media": "Absent",     "url": "http://127.0.0.1:$PORT/absent.xml",   "domaine": "exemple.fr" }
] }
JSON
sed "s/lemonde.xml/lemonde_semaine2.xml/" "$TMP/flux1.json" > "$TMP/flux2.json"

cd "$TMP"
echo "— Refus d'un rôle trop puissant"
if DEMELO_DATABASE_URL="postgresql://postgres@localhost/postgres?host=$TMP" DEMELO_DB_SSL=desactive DEMELO_FLUX_FICHIER="$TMP/flux1.json" \
   "$NODE" "$RACINE/collecte/collecte.mjs" >/dev/null 2>"$TMP/err.txt"; then echo "ÉCHEC : rôle postgres accepté"; exit 1; fi
grep -q "demelo_pipeline" "$TMP/err.txt" && echo "OK   rôle postgres refusé"

echo "— Collecte 1 (semaine 1)"
DEMELO_DATABASE_URL="$URL_PIPELINE" DEMELO_DB_SSL=desactive DEMELO_FLUX_FICHIER="$TMP/flux1.json" "$NODE" "$RACINE/collecte/collecte.mjs"
cp rapport-collecte.json rapport1.json
vu1=$(valeur "select max(vu_le) from public.contenus where url_originale like '%budget_1%'")
sleep 1
echo "— Collecte 2 (semaine 2)"
DEMELO_DATABASE_URL="$URL_PIPELINE" DEMELO_DB_SSL=desactive DEMELO_FLUX_FICHIER="$TMP/flux2.json" "$NODE" "$RACINE/collecte/collecte.mjs"

echo "— Contrôles"
verifier() { if [ "$(valeur "$2")" = "t" ]; then echo "OK   $1"; else echo "ÉCHEC $1"; ECHECS=$((ECHECS+1)); fi; }
ECHECS=0
verifier "semaine 1 : 6 articles réels (2 Le Monde + 2 Atom + 2 Le Parisien), pas l'externe, pas le .invalid, pas le doublon, pas le sans-titre" \
  "select count(*) = 6 from public.contenus where not est_test and lot_import like 'rss-%' and date_collecte < (select min(vu_le) from public.contenus where url_originale like '%nouveau_3%')"
verifier "semaine 2 : 1 seul nouvel article, total 7, aucun supprimé" "select count(*) = 7 from public.contenus where not est_test"
verifier "URL canonique : paramètres utm/xtor et ancre retirés" \
  "select bool_and(url_originale !~ '(utm_|xtor|#)') and count(*) filter (where url_originale = 'https://www.lemonde.fr/politique/article/2026/10/27/budget_1.html') = 1 from public.contenus"
verifier "articles déjà connus : vu_le mis à jour, titre et date de collecte conservés" \
  "select vu_le > '$vu1'::timestamptz and date_collecte < vu_le from public.contenus where url_originale like '%budget_1%'"
verifier "nouveaux articles non vérifiés et rattachés à leur média, pas à un organisme" \
  "select bool_and(statut_traitement = 'non_traite' and source_id is null and media_nom in ('Le Monde', '20 Minutes', 'Le Parisien')) from public.contenus where not est_test"
verifier "titre décodé (apostrophe typographique)" "select exists (select 1 from public.contenus where titre = 'Budget 2027 : l’Assemblée adopte la première partie')"
verifier "dates de publication enregistrées (RSS et Atom)" "select count(*) = 5 from public.contenus where not est_test and media_nom <> 'Le Parisien' and date_publication is not null"
verifier "Le Parisien : date lue dans l'adresse, sinon laissée vide (jamais inventée)" \
  "select count(*) filter (where (date_publication at time zone 'Europe/Paris')::date = '2026-10-28') = 1 and count(*) filter (where date_publication is null) = 1 from public.contenus where media_nom = 'Le Parisien'"
verifier "donnée fictive jamais modifiée" "select vu_le = '2026-01-01'::timestamptz from public.contenus where est_test"
verifier "aucune affirmation créée (collecte indépendante du fact-checking)" "select count(*) = 0 from public.affirmations"
if node -e "const r=require('$TMP/rapport1.json'); const e=r.flux.filter(f=>f.statut==='erreur').map(f=>f.media).sort().join(','); process.exit(e==='Absent,Cassé' && r.total_nouveaux===6 ? 0 : 1)"; then
  echo "OK   rapport : 2 flux en erreur tracés (HTTP 404, XML invalide), 6 nouveaux articles"; else echo "ÉCHEC rapport"; ECHECS=$((ECHECS+1)); fi
if [ "$ECHECS" -ne 0 ]; then echo "$ECHECS contrôle(s) en échec"; exit 1; fi
echo "Tous les contrôles sont réussis."
