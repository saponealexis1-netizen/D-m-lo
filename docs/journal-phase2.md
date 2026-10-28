# Journal — Phase 2 : reconstruction Supabase (28/10/2026)

Projet : **`aoysmqeasnfnyvmfwktt`** uniquement, via le connecteur `supabase_demelo`, rattaché à ce seul projet (rôle SQL `postgres`).
Aucune autre base n'a été touchée.

## 1. Contrôles avant écriture
| Contrôle | Résultat |
|---|---|
| État distant | 13 tables (RLS 13/13), 1 vue, 34 policies, 5 triggers, 2 tâches cron, 12 fonctions, 0 compte, 0 secret, 37 lignes de référence, 0 autre ligne. Schémas `archive_v1` et `prive` absents, types v2 absents, event trigger `ensure_rls` actif |
| Empreintes md5 distant / sauvegarde rejouée | Identiques : policies, colonnes, contraintes, triggers, vue, cron, `parametres`, `organismes`, `medias`, `verdicts`. Fonctions : identiques une à une avec `search_path = ''`. Le premier écart venait du `search_path` du nouveau connecteur (`"$user", public, extensions`), qui change l'affichage de `extensions.vector` |
| Lacune de la sauvegarde corrigée | `schema.sql` recrée maintenant aussi les `revoke execute` des 5 fonctions de trigger. Le retour arrière principal (`set schema public`) n'était pas concerné : les objets déplacés gardent leurs droits |

## 2. Migrations appliquées
| Version | Nom | Résultat | Contrôle immédiat |
|---|---|---|---|
| `20261028154657` | `v2_01_archiver_v1` | ✅ succès | 13 tables, 1 vue, 11 fonctions et 6 types dans `archive_v1` ; 34 policies conservées (empreinte identique, au préfixe de schéma près) ; RLS 13/13 ; 37 lignes de référence ; trigger `auth.users` supprimé (aucun trigger restant sur `auth.users`) ; 0 tâche cron ; aucun usage du schéma pour anon / authenticated ; 0 table dans `public` |
| `20261028154805` | `v2_02_schema_cible` | ✅ succès | 4 tables, RLS 4/4 ; 4 clés étrangères internes et 3 vers `auth.users` ; vue `v_feed_verifie` (`security_invoker=true`) ; 5 triggers actifs ; 8 types ; 24 contraintes `check` ; 18 index ; **0 policy ; 0 GRANT client** ; `rls_auto_enable()` limité à `postgres` |
| `20261028154842` | `v2_03_donnees_initiales` | ✅ succès | 28 sources (9 médias, 6 statistiques, 6 institutions, 2 juridiques, 5 fact-checkeurs ; 14 ouvertes et 14 « lien seulement ») ; aucun nom v1 manquant ; 0 contenu, 0 affirmation, 0 preuve |

Les fichiers de `supabase/migrations/` sont **identiques à l'octet près** au SQL enregistré par Supabase (md5 comparés : `24f2298a…`, `951b42b3…`, `8c689439…`).

## 2 bis. Sources retenues par l'équipe
| Version | Nom | Résultat |
|---|---|---|
| `20261028155725` | `v2_04_sources_retenues` | ✅ 13 sources supprimées (9 médias, Les Décodeurs, CheckNews, Vrai ou faux, Les Surligneurs), sans dépendance (0 contenu, 0 preuve). **15 sources restantes** : INSEE, Eurostat, DARES, DREES, Banque de France, SSMSI (statistique) ; Légifrance, Conseil constitutionnel (juridique) ; Assemblée nationale, Sénat, Cour des comptes, HATVP, Vie-publique.fr, Viginum (institution) ; AFP Factuel (fact-checking, lien seulement). Toujours fermées aux clients |

⚠ Chaque article (`contenus.source_id`) doit être rattaché à son média : les médias seront ajoutés dans `sources` (type `media`) au moment de l'import des 500 articles.

## 3. Fermeture des accès (vérifiée sur le projet réel)
- `has_table_privilege` : **aucun** droit select / insert / update / delete pour `anon` et `authenticated`, sur les 4 tables, la vue et les tables archivées.
- Essais réels avec changement de rôle (transactions annulées) :
  - `anon` → `select` sur `affirmations` : `permission denied for table affirmations` ;
  - `anon` → `select` sur `sources` : `permission denied for table sources` ;
  - `authenticated` avec un JWT de relecteur → `select` sur `v_feed_verifie` : `permission denied for view v_feed_verifie`.
- Aucune affirmation n'existe encore. Même lorsqu'il y en aura, aucun brouillon ne sera accessible tant que les policies et GRANT manuels ne sont pas en place.

## 4. Advisors
**Sécurité**
- INFO `rls_enabled_no_policy` sur les 4 tables : **attendu**, c'est l'état « fermé » voulu avant le tutoriel.
- Les alertes `SECURITY DEFINER` exposé (`rls_auto_enable`, `role_courant`, `questions_restantes`) ont **disparu**.
- WARN 0012 (connexions anonymes) :
  - toujours présent, car les connexions anonymes sont encore activées dans Auth. À désactiver par l'équipe (étape 5) ;
  - les lignes qui citent `public.affirmations` et `public.sources` sont des **faux positifs** : les policies nommées (`affirmations_modif`, `sources_ecriture`…) n'existent que dans `archive_v1` (vérifié dans `pg_policies`). Le linter rapproche les tables par leur nom ;
  - les autres lignes visent `archive_v1` (non exposé et sans droit d'usage), ainsi que `cron` et `realtime`, qui sont gérés par Supabase.

**Performance** : index non utilisés (tables vides, normal) ; clés étrangères non indexées dans `archive_v1` uniquement ; plusieurs policies permissives dans `archive_v1` uniquement.

## 5. Points restants
1. **Connexions anonymes** encore activées : à désactiver dans le dashboard (étape 5).
2. **`service_role` n'a pas de droit de lecture ni d'écriture** sur les nouvelles tables (ACL `Dxtm` uniquement, comme pour les tables v1 de ce projet). Sans conséquence aujourd'hui. Pour le futur script d'import des 500 articles, il faudra décider d'un GRANT **côté serveur** (par exemple `grant select, insert, update on public.contenus to service_role`), distinct des GRANT clients du tutoriel.
3. Les tests locaux (Postgres 16 avec stubs) ne valent pas preuve de sécurité en production. La preuve viendra des tests réels du tutoriel : `tests_sql_editor.sql`, puis `tests_api.mjs`.
4. L'archive `archive_v1` est conservée ; sa suppression définitive se fera plus tard, sur décision explicite.
