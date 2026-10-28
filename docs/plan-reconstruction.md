# Plan de reconstruction Démêlo v2 (MVP)

> **Statut au 28/10/2026 : étapes 0 à 4 réalisées** (v1 archivée, v2 créée et fermée, 28 sources), voir `docs/journal-phase2.md`. Prochaine étape : 5 (Auth), puis 6 (RLS manuelles). Chaque étape marquée 🔒 attend une validation explicite de l'équipe.

> **Mise à jour du 28/10/2026 (phase 3A)** : le circuit éditeur / relecteur est **remplacé** par le fact-checking automatisé par Claude. Migration complémentaire appliquée le 28/10/2026 : `supabase/migrations/20261028165254_v2_05_pipeline_ia.sql`. Spécification : `docs/pipeline-ia.md`. RLS : nouveau `rls_manuel/` (12 policies) et `docs/tutoriel-rls.md`. Les sections 5 à 7 ci-dessous décrivent l'état d'avant cette décision.

## Périmètre du MVP (ajusté le 28/10/2026)
- **Priorité absolue : 500 articles politiques réels indexés et 3 à 5 vérifications rigoureuses.**
- **YouTube est retiré du MVP** (clé API, quotas, transcriptions). L'architecture reste extensible : `format_contenu` ne contient que `article`, et un nouveau format s'ajoute sans toucher aux tables (`alter type public.format_contenu add value 'video';`).
- **RLS configurées à la main par l'équipe**, dans un but pédagogique. Les migrations créent une base **fermée** ; les policies et les GRANT sont dans un fichier séparé, jamais appliqué automatiquement.

## 1. Vérifications préalables

| Point | Résultat |
|---|---|
| Projet cible | `aoysmqeasnfnyvmfwktt`, « saponealexis1-netizen's SQL », eu-west-2, Postgres 17.11, `ACTIVE_HEALTHY`, créé le 28/10/2026 à 13 h 13 UTC |
| Est-ce bien Démêlo ? | **Oui** : il contient les 13 tables Démêlo v1 (`articles`, `affirmations`, `verdicts`…) |
| Autre projet du compte | `gdjzejledniwlqvxkjds` (« saponealexis1-netizen's Project », tables `documents` et `epictete_*`). **Sans rapport, à ne pas toucher** |
| Données présentes | 0 compte, 0 secret dans le Vault, 0 contenu ; seulement 37 lignes de référence |
| Historique de migration | Aucun (SQL exécuté directement dans le SQL Editor) |

## 2. Branches GitHub

| Branche | Rôle |
|---|---|
| `main` (`16f739e`) | Base stable : README seulement |
| `claude/sharp-pasteur-wtkdwi` (`66e0783`) | **Ancienne version conservée telle quelle**, sans fusion ni suppression (Mistral, Edge Functions, pg_net) |
| `claude/reconstruction-mvp` | **Branche de travail**, créée depuis `main` (`16f739e`) : sauvegarde et préparation de la v2 |

## 3. Fichiers préparés

```
sauvegarde/2026-10-28_schema_v1/        point de restauration de la v1
  README.md                             ce qui est sauvegardé, ce qui ne l'est pas
  schema.sql                            schéma v1 complet (export lecture seule)
  donnees_reference.sql                 37 lignes de référence, sans donnée personnelle

supabase/brouillons/                    ⚠ migrations à valider (pas encore dans supabase/migrations/)
  v2_01_archiver_v1.sql                 étape 1 : mise à l'écart réversible de la v1
  v2_02_schema_cible.sql                étape 2 : 4 tables, RLS activée, AUCUN accès client,
                                          triggers de validation humaine, vue
  v2_03_donnees_initiales.sql           étape 3 : 28 sources reprises de la v1
  tests/                                Postgres local : v1 → v2 → base fermée → RLS → tests

supabase/rls_manuel/                    ⚠ JAMAIS appliqué automatiquement
  policies_et_grants.sql                13 policies + 5 GRANT, à recopier une par une
  tests_sql_editor.sql                  49 essais réels dans le SQL Editor (données annulées)
  tests_api.mjs                         tests via l'API avec de vrais JWT (anon, éditeur, relecteur)
  nettoyage_tests_api.sql               suppression des données de tests_api.mjs

docs/plan-reconstruction.md             ce document
docs/tutoriel-rls.md                    tutoriel pas à pas des RLS
```

Les migrations ne sont volontairement pas dans `supabase/migrations/`, pour qu'aucun outil ne les applique par erreur. Une fois validées, **seules `v2_01` à `v2_03`** y seront copiées et appliquées avec `apply_migration`, ce qui crée un historique de migration. Le dossier `rls_manuel/` n'y va jamais.

## 4. Schéma cible

```
                 ┌──────────────────────────────┐
                 │ sources                      │  médias, institutions,
                 │ (+ champs de collecte RSS)   │  fact-checkeurs
                 └──────┬───────────────▲───────┘
                        │ 1..n          │ n..1
                 ┌──────▼───────┐       │
                 │ contenus     │  format = article (extensible)   ≥ 500 lignes
                 └──────┬───────┘       │
                        │ 1..n          │
                 ┌──────▼───────┐       │
                 │ affirmations │  brouillon → en_relecture → publie → retire
                 └──────┬───────┘       │
                        │ 1..n          │
                 ┌──────▼───────┐       │
                 │ preuves      ├───────┘  confirme | contredit | contextualise
                 └──────────────┘
   auth.users ── created_by / reviewed_by (affirmations), ajoutee_par (preuves)
```

**Exactement 4 tables métier**, reliées par 4 clés étrangères internes, plus 3 vers `auth.users` pour la traçabilité.

| Table | Champs essentiels |
|---|---|
| `sources` | `nom` (unique), `type_source` (media / institution / statistique / juridique / fact_checking), `url_base`, `reutilisation` (ouverte / lien_seulement), `active` |
| `contenus` | `source_id`, `format` (`article` par défaut), `titre`, `url_originale` (unique), `identifiant_externe` (GUID RSS, unique par source), `theme`, `resume` (600 caractères maximum), `date_publication`, `visible_public` |
| `affirmations` | `contenu_id`, `texte_affirmation` (10 à 400 caractères), `localisation`, `score_priorite` (0 à 100), `verdict` (vrai / faux / trompeur / non_verifiable), `explication`, `limites`, `statut_workflow`, `created_by`, `reviewed_by`, `reviewed_at`, `published_at`, `version` |
| `preuves` | `affirmation_id`, `source_id`, `url_preuve`, `type_relation`, `note`, `extrait` (400 caractères maximum, interdit si la source est sous licence), `date_document`, `date_consultation`, `ajoutee_par` |

**Champs prévus pour l'actualisation hebdomadaire** :
- dans `sources` : `mode_collecte` (manuel / rss), `flux_url`, `frequence_collecte_jours` (7 par défaut), `derniere_collecte_le`, `derniere_erreur_collecte` ;
- dans `contenus` : `identifiant_externe` (pour la déduplication), `date_collecte` (première fois vu), `vu_le` (dernière fois vu), `lot_import` ;
- dans les 3 tables principales : `updated_at` tenu à jour par un trigger.

**Brique logique côté base** : la vue `v_feed_verifie`, avec `security_invoker = true`. Pour chaque article visible, elle donne sa source, le nombre d'affirmations publiées, le statut `verifie` / `non_verifie` et la date de la dernière vérification. S'y ajoutent les triggers de validation (section 6).

## 5. Authentification et rôles, sans table `profils`

- **Supabase Auth**, par e-mail et mot de passe, pour les 4 membres. Les visiteurs n'ont pas besoin de compte.
- Le rôle d'équipe est stocké dans **`auth.users.raw_app_meta_data ->> 'role_equipe'`**, avec la valeur `editeur` ou `relecteur`, et apparaît dans le JWT sous `app_metadata`.
  - Un utilisateur **ne peut pas modifier son `app_metadata`** (contrairement à `user_metadata`) : `tests_api.mjs` le vérifie.
  - Un compte anonyme n'a jamais de rôle, même avec un JWT forgé (testé).
- Les fonctions `prive.role_equipe()`, `prive.est_membre()` et `prive.est_relecteur()` sont dans un schéma `prive` **non exposé par l'API**. Elles sont créées par la migration ; les policies les utiliseront.
- Attribution d'un rôle : voir `docs/tutoriel-rls.md`, section 2.2. Le membre doit ensuite se reconnecter.

## 6. Validation humaine : dans les triggers, indépendante des RLS

```
brouillon ──(≥ 1 preuve)──> en_relecture ──(relecteur ≠ auteur)──> publie ──> retire
    ▲                            │                                  │          │
    └────────────────────────────┴──────────(relecteur)─────────────┴──────────┘
```

Ces règles sont créées par la **migration** `v2_02`, et non par les policies. Elles s'appliquent à tous les rôles, y compris `service_role`, quelles que soient les policies configurées ensuite.

| Règle | Mécanisme |
|---|---|
| Création toujours en `brouillon` ; l'auteur est forcé à l'utilisateur connecté | Trigger |
| Envoi en relecture : verdict, explication et au moins 1 preuve | Trigger et contrainte |
| Publication : **relecteur connecté**, **différent de l'auteur**, au moins 1 preuve ; « vrai » exige une preuve *confirme*, « faux » une preuve *contredit* | Trigger, plus la contrainte `reviewed_by <> created_by` |
| La clé `service_role` (scripts, IA) **ne peut pas publier** | Trigger |
| Hors brouillon : texte, verdict et preuves figés | Triggers |
| `reviewed_by`, `reviewed_at`, `published_at` et `version` ne sont jamais modifiables à la main | Trigger |
| Correction : seul un relecteur peut dépublier ; la version augmente | Trigger |
| Pas d'extrait pour une source sous licence (droit voisin) | Trigger |

## 7. RLS : configuration manuelle

| Phase | État de la base | Qui y accède |
|---|---|---|
| Après les migrations | RLS activée sur les 4 tables, **0 policy, 0 GRANT** client | **Personne** (ni anon, ni membres) ; seul le propriétaire via le SQL Editor |
| Pendant le tutoriel | Pour chaque table : policies → GRANT → tests | Seulement ce que les policies déjà testées autorisent |
| À la fin | 13 policies, 5 GRANT | Matrice ci-dessous |

L'ordre policies → GRANT garantit qu'**aucune table n'est jamais ouverte sans ses règles**. Les tests `tests_sql_editor.sql` affichent ⏳ pour les tables pas encore ouvertes.

| Table | Visiteur (`anon`) | Inscrit sans rôle | Éditeur | Relecteur |
|---|---|---|---|---|
| sources | lit les actives | lit les actives | lit et ajoute / modifie | idem |
| contenus | lit les visibles | lit les visibles | lit et ajoute / modifie | idem |
| affirmations | lit les publiées | lit les publiées | tout lire, créer, modifier ses brouillons, envoyer en relecture | idem, plus publier, retirer et dépublier celles des autres |
| preuves | celles des affirmations publiées | idem | tout lire, ajouter / supprimer (en brouillon seulement) | idem |

## 8. Fonctions exposées à risque

| Fonction (v1) | Risque relevé par les advisors | Traitement prévu |
|---|---|---|
| `public.rls_auto_enable()` | `SECURITY DEFINER` exécutable par `anon` et `authenticated` via `/rest/v1/rpc` | **Conservée** (fonction Supabase de l'event trigger `ensure_rls`), mais `revoke execute` dans `v2_02`. Risque réel faible : une fonction `event_trigger` ne peut pas être appelée directement. L'event trigger fonctionne toujours (testé) |
| `public.role_courant()` | `SECURITY DEFINER` exposée : révèle le rôle de l'appelant | Archivée ; remplacée par `prive.role_equipe()`, non exposée et sans `security definer` |
| `public.questions_restantes()` | `SECURITY DEFINER` exposée | Archivée (chatbot hors MVP) |
| `est_admin()`, `est_editeur()`, `est_anonyme()`, `rechercher_sources()` | Exécutables par `PUBLIC` | Archivées |
| Policies `to authenticated` (lint 0012) | Les connexions anonymes sont activées | **Désactiver les connexions anonymes** dans Auth |

## 9. Plan d'exécution actualisé

| # | Étape | Fichier ou action | Qui | Validation |
|---|---|---|---|---|
| 0 | Revérifier que l'état distant n'a pas changé depuis la sauvegarde | requêtes en lecture | Claude | non |
| 1 | **Archiver la v1** dans `archive_v1` (trigger `auth.users` supprimé, 2 tâches cron arrêtées) | `v2_01_archiver_v1.sql` via `apply_migration` | Claude | 🔒 |
| 2 | **Créer la v2 fermée** : 4 tables avec RLS active, 0 policy, 0 GRANT, triggers, vue | `v2_02_schema_cible.sql` via `apply_migration` | Claude | 🔒 |
| 3 | **Insérer les 28 sources** | `v2_03_donnees_initiales.sql` via `apply_migration` | Claude | 🔒 |
| 4 | Contrôler la fermeture : 0 policy, 0 GRANT client, advisors | lecture | Claude | non |
| 5 | **Auth** : désactiver les connexions anonymes, créer les 4 comptes d'équipe et les 3 comptes de test, attribuer les rôles | dashboard et SQL | **Équipe** | 🔒 |
| 6 | **Configurer les RLS à la main**, table par table : policies → GRANT → tests | `docs/tutoriel-rls.md` | **Équipe**, accompagnée | — |
| 7 | **Tests réels** : `tests_sql_editor.sql` à 100 % ✅, puis `tests_api.mjs` et le nettoyage | SQL Editor et poste local | **Équipe** | — |
| 8 | Relire les advisors ; copier `v2_01` à `v2_03` dans `supabase/migrations/` | lecture et GitHub | Claude | non |
| 9 | Phase suivante : **import des 500 articles** via RSS (script lancé en local), puis 3 à 5 vérifications | — | — | 🔒 |

Les étapes 1 à 3 sont **3 migrations séparées**, chacune dans sa transaction : si une étape échoue, elle n'est pas appliquée.

### Retour arrière
- **Après l'étape 1 seule** : remettre les objets dans `public` (`alter ... set schema public`), puis recréer le trigger et les 2 tâches cron à partir de `sauvegarde/2026-10-28_schema_v1/schema.sql`.
- **Après l'étape 2 ou 3** : supprimer d'abord les objets v2 (`drop view v_feed_verifie; drop table preuves, affirmations, contenus, sources; drop schema prive cascade;` et les 8 types), puis faire le retour arrière de l'étape 1.
- **Policies créées à tort** pendant l'étape 6 : `drop policy nom on table;`, puis recommencer (aucun impact sur les données).
- **Suppression définitive de `archive_v1`** : seulement plus tard, sur décision explicite.

## 10. Objets touchés sur Supabase et conséquences

| Objet | Action | Conséquence |
|---|---|---|
| 13 tables v1 avec index, contraintes, 34 policies et triggers | Déplacées dans `archive_v1` à l'étape 1 | Invisibles pour l'API ; policies v1 conservées telles quelles dans l'archive. Aucune donnée perdue |
| Vue `affirmations_publiques` | Déplacée | Aucun front ne l'utilise |
| Trigger `apres_creation_utilisateur` sur `auth.users` | **Supprimé** | Indispensable : sinon chaque inscription échouerait. Recréable à partir de la sauvegarde |
| Tâches cron `purge-messages-chatbot` et `purge-visiteurs-anonymes` | Désactivées | Elles viseraient des tables archivées. Recréables |
| 11 fonctions et 6 types v1 | Déplacés | Aucun conflit de nom avec la v2 |
| `public.rls_auto_enable()` et l'event trigger `ensure_rls` | Droit d'exécution retiré, objets conservés | Comportement identique (RLS automatique) |
| Extensions `vector`, `pg_cron`, Vault | Conservées | `pg_cron` servira pour la collecte hebdomadaire |
| Autre projet `gdjzejledniwlqvxkjds` | **Aucune** | — |

## 11. Risques identifiés

| Risque | Mesure |
|---|---|
| Se tromper de projet | Ref vérifié ; toujours passer `aoysmqeasnfnyvmfwktt` explicitement |
| L'état distant a changé depuis la sauvegarde | Étape 0 obligatoire ; si quelque chose a changé, refaire une sauvegarde |
| Une policy trop permissive pendant le tutoriel (par exemple `using (true)` sur `affirmations`) | Ordre policies → GRANT → tests ; tests P7 et P11 dédiés aux fuites de brouillons ; base vide de vraies vérifications pendant la configuration ; la publication reste protégée par les triggers |
| Exécuter `policies_et_grants.sql` d'un bloc, sans comprendre | Avertissement en tête du fichier ; le fichier n'est jamais dans `migrations/` |
| Tests locaux sur Postgres 16 avec des stubs, alors que Supabase tourne sous Postgres 17 | Étape 7 : tests réels dans le SQL Editor et via l'API |
| Un rôle retiré reste valable jusqu'à l'expiration du JWT (environ 1 h) | Acceptable pour 4 membres ; pour un retrait urgent, révoquer les sessions |
| Supprimer le compte d'un auteur est bloqué (`on delete restrict`) | Voulu, pour la traçabilité ; bannir le compte au lieu de le supprimer |
| La clé `service_role` contourne la RLS | Elle ne peut pas publier (trigger) ; jamais dans le front ni dans GitHub ; `tests_api.mjs` refuse une clé secrète |
| Un administrateur du SQL Editor peut désactiver un trigger | La contrainte `reviewed_by <> created_by` tient même sans trigger (testé) |
| Données de `tests_api.mjs` restées en base | Article masqué, affirmation retirée en fin de test, puis script de nettoyage |
| Atteindre 500 articles réels | Flux RSS des médias et des institutions, via un script lancé en local : phase suivante. YouTube n'est plus sur le chemin critique |

## 12. Tests locaux

```bash
supabase/brouillons/tests/lancer_tests.sh   # PostgreSQL 16+, utilisateur non root
```

Le script enchaîne, dans un Postgres jetable :
1. la réexécution de la sauvegarde v1, avec contrôle de fidélité ;
2. les étapes 1 à 3 ;
3. **10 tests de base fermée** : RLS active, 0 policy, 0 GRANT, aucun accès anon ou relecteur, brouillon invisible ;
4. `tests_sql_editor.sql` **sur la base fermée** : uniquement des ⏳ ou des ✅ ;
5. l'application de `policies_et_grants.sql`, comme si l'équipe l'avait terminée ;
6. `tests_sql_editor.sql` **après configuration** : **49/49 ✅**, et aucune donnée de test restante ;
7. **50 tests** de structure, RLS et workflow.

Résultat au 28/10/2026 : **tout est vert.**
