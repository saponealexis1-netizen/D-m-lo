# Sauvegarde du schéma Supabase v1 — 28 octobre 2026

Instantané du projet Supabase **`aoysmqeasnfnyvmfwktt`** (« saponealexis1-netizen's SQL », eu-west-2, Postgres 17), pris **avant** la reconstruction du MVP Démêlo.

| Fichier | Contenu |
|---|---|
| `schema.sql` | Types, 13 tables, contraintes, index, 12 fonctions, 5 triggers (dont 1 sur `auth.users`), la vue `affirmations_publiques`, la RLS, les 34 policies, les droits et les 2 tâches pg_cron |
| `donnees_reference.sql` | 37 lignes de référence : `parametres` (4), `verdicts` (5), `medias` (9), `organismes` (19) |

## Comment elle a été faite
L'export s'est fait en **lecture seule**, depuis le catalogue PostgreSQL (`pg_catalog`, `pg_policies`, `cron.job`), avec le connecteur Supabase et uniquement des requêtes `SELECT`. Rien n'a été modifié sur le projet.

`supabase/brouillons/tests/lancer_tests.sh` rejoue cette sauvegarde dans un Postgres local, puis vérifie qu'on retrouve bien l'état relevé : 13 tables avec RLS, 34 policies, 5 triggers, 2 tâches cron et 37 lignes de référence.

## Ce qui n'est pas sauvegardé, volontairement
- **Aucune donnée personnelle.** `auth.users` contenait 0 compte au moment de l'export ; `profils`, `signalements` et `messages` étaient vides.
- **Aucun secret.** Le Vault contenait 0 secret. Aucune clé API n'est présente.
- **Tables métier vides** : `articles`, `sources`, `affirmations`, `candidats`, `affirmation_sources` et `affirmation_candidats` (0 ligne).
- **Objets gérés par Supabase** :
  - l'event trigger `ensure_rls` et sa fonction `public.rls_auto_enable()`, qui activent automatiquement la RLS sur chaque nouvelle table de `public`. Leur définition figure dans `supabase/brouillons/tests/stubs_supabase.sql` ;
  - les extensions installées : `vector` 0.8.2, `pg_cron` 1.6.4, `supabase_vault`, `pgcrypto`, `uuid-ossp` et `pg_stat_statements`.

## Remarques
- Le SQL avait été exécuté directement dans le SQL Editor : le projet n'a **aucun historique de migration**.
- Cette version correspond à la migration d'origine. La variante plus récente de la branche `claude/sharp-pasteur-wtkdwi` (statut `importe`, pg_net) n'a **jamais été appliquée**.
- Ce fichier sert de documentation et de point de restauration. Il ne doit pas être rejoué tel quel sur le projet, car les objets existent déjà.
