# Plan de reconstruction Démêlo v2 (MVP)

> **Statut : préparation uniquement.** Rien n'a été appliqué sur Supabase. Chaque étape marquée 🔒 attend une validation explicite de l'équipe.

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
| `claude/reconstruction-mvp` | **Nouvelle branche**, créée depuis `main` (`16f739e`) : sauvegarde et préparation de la v2 |

## 3. Fichiers préparés

```
sauvegarde/2026-10-28_schema_v1/
  README.md                 ce qui est sauvegardé, ce qui ne l'est pas
  schema.sql                schéma v1 complet (export lecture seule)
  donnees_reference.sql     37 lignes de référence, sans donnée personnelle
supabase/brouillons/        ⚠ brouillons, PAS dans supabase/migrations/
  v2_01_archiver_v1.sql     étape 1 : mise à l'écart réversible de la v1
  v2_02_schema_cible.sql    étape 2 : 4 tables, rôles, workflow, RLS, vue
  v2_03_donnees_initiales.sql  étape 3 : 28 sources reprises de la v1
  tests/                    Postgres local : rejoue v1, puis v2, puis 49 tests
docs/plan-reconstruction.md ce document
```

Les brouillons ne sont volontairement pas dans `supabase/migrations/`, pour qu'aucun outil ne les applique par erreur. Une fois validés, ils y seront copiés et appliqués avec l'outil `apply_migration`, ce qui crée un historique de migration.

## 4. Schéma cible

```
                 ┌──────────────────────────────┐
                 │ sources                      │  médias, chaînes YouTube,
                 │ (+ champs de collecte)       │  institutions, fact-checkeurs
                 └──────┬───────────────▲───────┘
                        │ 1..n          │ n..1
                 ┌──────▼───────┐       │
                 │ contenus     │  article | youtube   (≥ 500 lignes)
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
| `sources` | `nom` (unique), `type_source`, `url_base`, `reutilisation` (ouverte / lien_seulement), `active` |
| `contenus` | `source_id`, `format` (article / youtube), `titre`, `url_originale` (unique), `identifiant_externe` (ID vidéo, obligatoire pour YouTube), `theme`, `resume` (600 caractères maximum), `date_publication`, `transcription_disponible`, `visible_public` |
| `affirmations` | `contenu_id`, `texte_affirmation` (10 à 400 caractères), `localisation`, `minutage_secondes`, `score_priorite` (0 à 100), `verdict` (vrai / faux / trompeur / non_verifiable), `explication`, `limites`, `statut_workflow`, `created_by`, `reviewed_by`, `reviewed_at`, `published_at`, `version` |
| `preuves` | `affirmation_id`, `source_id`, `url_preuve`, `type_relation`, `note`, `extrait` (400 caractères maximum, interdit si la source est sous licence), `date_document`, `date_consultation`, `ajoutee_par` |

**Champs prévus pour l'actualisation hebdomadaire (V2)** :
- dans `sources` : `mode_collecte` (manuel / rss / api_youtube), `flux_url`, `identifiant_externe` (ID de chaîne), `frequence_collecte_jours` (7 par défaut), `derniere_collecte_le`, `derniere_erreur_collecte` ;
- dans `contenus` : `identifiant_externe` (avec unicité par source, pour la déduplication), `date_collecte` (première fois vu), `vu_le` (dernière fois vu), `lot_import` ;
- dans les 3 tables principales : `updated_at` tenu à jour par un trigger.

**Brique logique côté base** : la vue `v_feed_verifie`, avec `security_invoker = true`. Pour chaque contenu visible, elle donne sa source, le nombre d'affirmations publiées, le statut `verifie` / `non_verifie` et la date de la dernière vérification. S'y ajoutent les triggers de workflow (section 6).

## 5. Authentification et rôles, sans table `profils`

- **Supabase Auth**, par e-mail et mot de passe, pour les 4 membres. Les visiteurs n'ont pas besoin de compte.
- Le rôle d'équipe est stocké dans **`auth.users.raw_app_meta_data ->> 'role_equipe'`**, avec la valeur `editeur` ou `relecteur`. Il apparaît dans le JWT sous `app_metadata`.
  - L'**`app_metadata` ne peut pas être modifié par l'utilisateur** : seuls le SQL ou l'API admin y ont accès, contrairement à `user_metadata`.
  - Un compte anonyme n'a jamais de rôle, même avec un JWT forgé (testé).
- Les fonctions `prive.role_equipe()`, `prive.est_membre()` et `prive.est_relecteur()` lisent le JWT. Elles sont placées dans un schéma `prive` **non exposé par l'API**.
- Attribution d'un rôle (SQL Editor, par un membre qui a accès au dashboard) :
  ```sql
  update auth.users
     set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role_equipe": "relecteur"}'
   where email = 'EMAIL_DU_MEMBRE';
  ```
  Le membre doit ensuite **se reconnecter** pour que son JWT contienne le rôle.

## 6. Workflow de validation humaine

```
brouillon ──(≥ 1 preuve)──> en_relecture ──(relecteur ≠ auteur)──> publie ──> retire
    ▲                            │                                  │          │
    └────────────────────────────┴──────────(relecteur)─────────────┴──────────┘
```

| Règle | Où elle est appliquée |
|---|---|
| Création toujours en `brouillon`, et l'auteur est forcé à l'utilisateur connecté | Trigger et policy |
| Envoi en relecture : verdict, explication et au moins 1 preuve | Trigger et contrainte |
| Publication : **relecteur connecté**, **différent de l'auteur**, au moins 1 preuve ; « vrai » exige une preuve *confirme*, « faux » une preuve *contredit* | Trigger, plus la contrainte `reviewed_by <> created_by` |
| La clé `service_role` (scripts, IA) **ne peut pas publier** : sans utilisateur connecté, la publication est refusée | Trigger |
| Hors brouillon : texte, verdict et preuves figés ; le relecteur valide le texte tel quel | Triggers |
| `reviewed_by`, `reviewed_at`, `published_at` et `version` ne sont jamais modifiables à la main | Trigger |
| Correction : seul un relecteur peut dépublier ; la version augmente et la validation est effacée | Trigger |

### Matrice RLS

| Table | Visiteur (`anon`) | Inscrit sans rôle | Éditeur | Relecteur |
|---|---|---|---|---|
| sources | lit les actives | lit les actives | lit et ajoute / modifie | idem |
| contenus | lit les visibles | lit les visibles | lit et ajoute / modifie | idem |
| affirmations | lit les publiées | lit les publiées | tout lire, créer, modifier ses brouillons, envoyer en relecture | idem, plus publier, retirer et dépublier celles des autres |
| preuves | celles des affirmations publiées | idem | tout lire, ajouter / supprimer (en brouillon seulement) | idem |

Il n'y a aucune policy de suppression sur `sources` et `contenus`. Une affirmation ne peut être supprimée que par son auteur, et seulement en brouillon.

## 7. Fonctions exposées à risque

| Fonction (v1) | Risque relevé par les advisors | Traitement prévu |
|---|---|---|
| `public.rls_auto_enable()` | `SECURITY DEFINER` exécutable par `anon` et `authenticated` via `/rest/v1/rpc` | **Conservée** (c'est la fonction Supabase de l'event trigger `ensure_rls`), mais `revoke execute ... from public, anon, authenticated`. Risque réel faible, car une fonction `event_trigger` ne peut pas être appelée directement. Le test confirme que l'event trigger fonctionne toujours |
| `public.role_courant()` | `SECURITY DEFINER` exposée : révèle le rôle de l'appelant | Archivée hors de `public` ; remplacée par `prive.role_equipe()`, non exposée et sans `security definer` |
| `public.questions_restantes()` | `SECURITY DEFINER` exposée | Archivée (le chatbot sort du MVP) |
| `est_admin()`, `est_editeur()`, `est_anonyme()`, `rechercher_sources()` | Exécutables par `PUBLIC` | Archivées ; remplacées par les fonctions du schéma `prive` |
| Policies `to authenticated` (lint 0012) | Les connexions anonymes sont activées | **Désactiver les connexions anonymes** dans Auth ; les fonctions `prive.*` refusent de toute façon les comptes anonymes |

## 8. Plan détaillé

| # | Étape | Fichier ou action | Réversible | Validation |
|---|---|---|---|---|
| 0 | Revérifier que l'état distant n'a pas changé depuis la sauvegarde (nombres de lignes, 0 compte) | requêtes en lecture | — | non |
| 1 | **Archiver la v1** dans `archive_v1` : supprimer le trigger `auth.users`, désactiver les 2 tâches cron, déplacer les 13 tables, la vue, les 11 fonctions et les 6 types, puis retirer tous les droits | `v2_01_archiver_v1.sql` | oui | 🔒 |
| 2 | **Créer la v2** : schéma `prive`, 8 types, 4 tables, index, triggers, vue, RLS, droits, `revoke` sur `rls_auto_enable()` | `v2_02_schema_cible.sql` | oui (suppression des objets v2) | 🔒 |
| 3 | **Insérer les 28 sources** reprises de la v1 | `v2_03_donnees_initiales.sql` | oui | 🔒 |
| 4 | Relancer les **advisors** de sécurité et de performance | `get_advisors` | — | non |
| 5 | **Auth** : désactiver les connexions anonymes, créer les 4 comptes, attribuer les rôles (SQL section 5) | dashboard et SQL | oui | 🔒 |
| 6 | **Tests RLS réels** via l'API avec la clé publique : visiteur, inscrit sans rôle, éditeur, relecteur | scripts de test | — | non |
| 7 | Copier les 3 fichiers validés dans `supabase/migrations/` | GitHub | oui | non |
| 8 | Phases suivantes : import des 500 contenus, puis le front React | — | — | 🔒 |

Les étapes 1 à 3 seront appliquées en **3 migrations séparées** avec `apply_migration`, chacune dans sa propre transaction : si une étape échoue, rien n'est appliqué.

### Retour arrière
- **Après l'étape 1 seule** : remettre les objets dans `public` (`alter ... set schema public`), puis recréer le trigger et les 2 tâches cron à partir de `sauvegarde/2026-10-28_schema_v1/schema.sql`.
- **Après l'étape 2** : supprimer d'abord les objets v2 (`drop view v_feed_verifie; drop table preuves, affirmations, contenus, sources; drop schema prive cascade;` et les 8 types), puis faire le retour arrière de l'étape 1.
- **Suppression définitive de `archive_v1`** : seulement plus tard, sur décision explicite (par exemple après la soutenance).

## 9. Objets touchés sur Supabase et conséquences

| Objet | Action | Conséquence |
|---|---|---|
| 13 tables v1 avec index, contraintes, 34 policies et triggers | Déplacées dans `archive_v1` | Invisibles pour l'API. Aucune donnée perdue (37 lignes de référence et tables vides) |
| Vue `affirmations_publiques` | Déplacée | Aucun front ne l'utilise |
| Trigger `apres_creation_utilisateur` sur `auth.users` | **Supprimé** | Indispensable : sinon chaque inscription échouerait. Recréable à partir de la sauvegarde |
| Tâches cron `purge-messages-chatbot` et `purge-visiteurs-anonymes` | Désactivées (`unschedule`) | Elles viseraient des tables archivées. Recréables à partir de la sauvegarde |
| 11 fonctions et 6 types v1 | Déplacés | Les noms se libèrent ; pas de conflit avec la v2 (types renommés) |
| `public.rls_auto_enable()` et l'event trigger `ensure_rls` | Droit d'exécution retiré, objets conservés | Comportement identique (RLS automatique) |
| Extensions `vector`, `pg_cron`, Vault | Conservées | `vector` n'est plus utilisée par la v2 ; `pg_cron` servira pour la collecte hebdomadaire |
| Autre projet `gdjzejledniwlqvxkjds` | **Aucune** | — |

## 10. Risques identifiés

| Risque | Mesure |
|---|---|
| Se tromper de projet | Ref vérifié ; toujours passer `aoysmqeasnfnyvmfwktt` explicitement ; ne jamais toucher `gdjzejledniwlqvxkjds` |
| L'état distant a changé depuis la sauvegarde | Étape 0 obligatoire ; si quelque chose a changé, refaire une sauvegarde |
| Tests réalisés en local sur Postgres 16 avec des stubs, alors que Supabase tourne sous Postgres 17 | Étapes 4 et 6 : advisors et tests réels via l'API |
| Un rôle retiré reste valable jusqu'à l'expiration du JWT (environ 1 h) | Acceptable pour 4 membres ; pour un retrait urgent, révoquer les sessions de l'utilisateur dans le dashboard |
| Supprimer le compte d'un auteur est bloqué (`on delete restrict`) | Voulu, pour la traçabilité ; bannir le compte au lieu de le supprimer |
| La clé `service_role` contourne la RLS (elle peut écrire des brouillons) | Elle ne peut pas publier (trigger) ; elle ne doit jamais être dans le front ni dans GitHub |
| Un administrateur du SQL Editor peut désactiver un trigger | La contrainte `reviewed_by <> created_by` tient même sans trigger (testé) ; c'est aussi une règle d'équipe |
| Atteindre 500 contenus réels | RSS et API YouTube Data (clé et quotas), via un script lancé en local et jamais dans le front : phase suivante |
| Supabase pourrait rétablir le droit d'exécution de `rls_auto_enable()` lors d'une mise à jour | Relancer les advisors après chaque migration |
| Les docs de l'ancienne branche (Mistral, chatbot) ne correspondent plus au MVP | Branche conservée mais non fusionnée ; la référence est ce document |

## 11. Tests locaux

```bash
supabase/brouillons/tests/lancer_tests.sh   # PostgreSQL 16+, utilisateur non root
```

Le script :
1. rejoue la sauvegarde v1 et vérifie qu'elle est fidèle ;
2. applique les étapes 1 à 3 ;
3. lance **49 tests** : archivage, structure à 4 tables, RLS par profil, workflow complet sur un article et sur une vidéo, auto-validation refusée, `service_role` bloquée, preuves figées, correction avec version, contrainte sans trigger, `rls_auto_enable()` sécurisée.

Résultat au 28/10/2026 : **49/49 réussis.**
