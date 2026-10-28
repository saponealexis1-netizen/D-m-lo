# Brouillons des migrations v2

**Appliqués le 28/10/2026** sur le projet `aoysmqeasnfnyvmfwktt`. La version de référence est désormais
`supabase/migrations/`, qui contient le SQL exact enregistré par Supabase (sans `begin` / `commit`,
car `apply_migration` exécute chaque migration dans sa propre transaction).

Ces brouillons restent ici pour les tests locaux (`tests/lancer_tests.sh`). Ils sont équivalents
aux migrations : même SQL, avec des commentaires plus détaillés.
Journal d'exécution : `docs/journal-phase2.md`.

## v2_05 — pipeline IA (préparé, NON appliqué)
`v2_05_pipeline_ia.sql` remplace la validation humaine systématique par le fact-checking automatisé
(spécification : `docs/pipeline-ia.md`). Il sera appliqué avec `apply_migration` après validation, puis
copié dans `supabase/migrations/` avec la version attribuée par Supabase (sans `begin` / `commit`).
