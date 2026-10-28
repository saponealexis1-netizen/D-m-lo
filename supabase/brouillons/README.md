# Brouillons des migrations v2

**Appliqués le 28/10/2026** sur le projet `aoysmqeasnfnyvmfwktt`. La version de référence est désormais
`supabase/migrations/`, qui contient le SQL exact enregistré par Supabase (sans `begin` / `commit`,
car `apply_migration` exécute chaque migration dans sa propre transaction).

Ces brouillons restent ici pour les tests locaux (`tests/lancer_tests.sh`). Ils sont équivalents
aux migrations : même SQL, avec des commentaires plus détaillés.
Journal d'exécution : `docs/journal-phase2.md`.
