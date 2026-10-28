# Tutoriel : configurer les RLS de Démêlo à la main

Ce tutoriel vous fait créer vous-mêmes, dans Supabase, les **12 policies** et les **5 GRANT** de Démêlo, en les comprenant et en les testant une par une.

- Fichier de référence : `supabase/rls_manuel/policies_et_grants.sql`. **Ne jamais l'exécuter d'un bloc** : on y recopie une policy à la fois.
- Tests : `supabase/rls_manuel/tests_sql_editor.sql` (SQL Editor) et `supabase/rls_manuel/tests_api.mjs` (API réelle).
- Prérequis : les migrations `v2_01` à `v2_05` ont été appliquées. La base est alors **fermée aux clients** : RLS activée, 0 policy et 0 GRANT pour `anon` et `authenticated`.

---

## 0. Les règles d'or

1. **Ordre imposé pour chaque table : policies → GRANT → tests.** Une policy sans GRANT n'ouvre rien ; un GRANT sans policy ne montre aucune ligne, car la RLS refuse tout par défaut. En respectant cet ordre, aucune table n'est jamais exposée sans ses règles.
2. **Jamais `using (true)`** sur `affirmations` ou `preuves` : ce serait publier les analyses en cours, les cas sensibles en attente de revue et les échecs de recherche.
3. **Une policy à la fois, puis un test.** Si un test passe au ❌, on corrige avant de continuer.
4. **La clé `service_role` / secrète ne sort jamais du dashboard** : pas dans le front, pas dans GitHub.
5. **Les RLS décident qui voit et qui modifie quelles lignes. Les triggers décident si une analyse peut être publiée.** Les triggers de `v2_05` exigent des preuves vérifiées, la revue des cas sensibles et l'exclusion des données fictives, quoi que disent les policies.

## 1. Comprendre en 5 minutes

### Deux portes successives
| Couche | Question | Si elle refuse |
|---|---|---|
| **GRANT** | Ce rôle a-t-il le droit de tenter cette **action** sur cette table ? | `permission denied for table …` (HTTP 401/403) |
| **RLS (policies)** | Sur **quelles lignes** cette action est-elle permise ? | En lecture : 0 ligne, sans erreur. En écriture : `new row violates row-level security policy` (HTTP 403) |

### Les profils
| Profil | Rôle Postgres | Ce qu'il voit |
|---|---|---|
| Visiteur sans compte | `anon` (clé publique) | Ce qui est public |
| Compte connecté sans rôle | `authenticated` | La même chose qu'un visiteur |
| Administrateur (les 4 membres) | `authenticated` + `app_metadata.role_equipe = 'admin'` | Tout ; il peut corriger, retirer et trancher les revues |
| Pipeline IA | `demelo_pipeline` (rôle serveur, **déjà configuré** par `v2_05`) | Les sources et les articles réels ; il écrit les analyses. **Il n'est pas concerné par ce tutoriel** |

Le rôle d'équipe est lu par `prive.est_admin()`. Un utilisateur ne peut pas modifier son `app_metadata`, et un compte anonyme n'est jamais administrateur.

### Anatomie d'une policy
```sql
create policy nom on table
  for select | insert | update | delete   -- l'opération
  to anon, authenticated                  -- les rôles concernés
  using (condition)                       -- lignes EXISTANTES visibles / modifiables
  with check (condition);                 -- lignes NOUVELLES ou MODIFIÉES acceptées
```
| Opération | `using` | `with check` |
|---|---|---|
| select | oui | — |
| insert | — | oui |
| update | oui (quelles lignes on peut viser) | oui (à quoi elles peuvent ressembler après) |
| delete | oui | — |

- Plusieurs policies sur la même opération s'additionnent (**OU**).
- Écrire `(select prive.est_admin())` entre parenthèses fait calculer la fonction **une seule fois par requête**, et non à chaque ligne : c'est une question de performances.
- Une sous-requête dans une policy passe elle-même par la RLS : P7 s'appuie sur P4, et P10 s'appuie sur P7.

## 2. Préparation

### 2.1 Vérifier que la base est fermée
Dans **SQL Editor** :
```sql
select tablename, rowsecurity from pg_tables where schemaname = 'public';           -- 4 lignes, toutes true
select policyname, roles from pg_policies where schemaname = 'public';              -- 6 policies, toutes {demelo_pipeline}
```
Ensuite, après avoir créé les comptes de test (2.2), collez et exécutez **tout** `supabase/rls_manuel/tests_sql_editor.sql`. Résultat attendu : **44 ⏳ et 8 ✅**, sans aucun ❌. Les ✅ correspondent aux refus attendus.

### 2.2 Créer les comptes
Dans **Authentication > Users > Add user > Create new user**, saisissez un mot de passe et cochez **Auto Confirm User** :
- `admin@demelo.test` : compte administrateur de test ;
- `visiteur@demelo.test` : compte connecté sans privilège ;
- vos 4 vrais comptes d'équipe.

Puis, dans le SQL Editor :
```sql
update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role_equipe": "admin"}'
 where email in ('admin@demelo.test', 'EMAIL_MEMBRE_1', 'EMAIL_MEMBRE_2', 'EMAIL_MEMBRE_3', 'EMAIL_MEMBRE_4');
-- visiteur@demelo.test : volontairement aucun rôle.
```
Un membre doit **se reconnecter** pour que son rôle apparaisse dans son JWT. Pensez aussi à désactiver les connexions anonymes dans **Authentication > Sign In / Providers**.

### 2.3 Où écrire les policies
- **Recommandé : SQL Editor.** On colle le bloc `create policy …` du fichier de référence.
- **Autre possibilité : Authentication > Policies > (table) > Create policy.** On y saisit le nom, la commande, les rôles visés, puis les expressions USING et WITH CHECK du fichier, sans `using (` ni `)`.

### 2.4 Tester une policy à la main (modèle)
```sql
begin;
select set_config('request.jwt.claims', '{"role": "anon"}', true);          -- visiteur
-- ou, pour un compte :
-- select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated',
--          'app_metadata', raw_app_meta_data)::text, true) from auth.users where email = 'admin@demelo.test';
set local role anon;            -- ou authenticated
select count(*) from public.sources;
rollback;                       -- rien n'est conservé
```
Le script `tests_sql_editor.sql` fait la même chose pour tous les cas, et affiche ✅, ❌ ou ⏳.

---

## 3. Table `sources` : les 15 organismes de vérification

### P1 — `sources_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using (active or (select prive.est_admin()))` |
| Pourquoi | Le public doit savoir sur quels organismes reposent les preuves. Un organisme désactivé n'est visible que par l'équipe. |
| Résultat attendu | anon voit les 15 organismes actifs, pas un organisme inactif ; l'admin voit tout. |

```sql
create policy sources_lecture on public.sources
  for select to anon, authenticated
  using (active or (select prive.est_admin()));
```

### P2 — `sources_ajout`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `insert` |
| Condition | `with check ((select prive.est_admin()))` |
| Pourquoi | Aucun organisme ne s'ajoute à la liste sans l'accord de l'équipe. |
| Résultat attendu | L'admin ajoute ; un compte sans rôle reçoit `new row violates row-level security policy`. |

```sql
create policy sources_ajout on public.sources
  for insert to authenticated
  with check ((select prive.est_admin()));
```

### P3 — `sources_modif`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `update` |
| Condition | `using ((select prive.est_admin())) with check ((select prive.est_admin()))` |
| Résultat attendu | L'admin modifie ; un compte sans rôle modifie **0 ligne**, sans erreur, car la ligne lui est invisible pour l'`update`. |

```sql
create policy sources_modif on public.sources
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));
```

### G1 — GRANT de `sources`
```sql
grant select on public.sources to anon, authenticated;
grant insert, update on public.sources to authenticated;
```
Il n'y a **pas de `delete`** : un organisme cité dans des preuves ne doit pas disparaître.

▶ **Relancez `tests_sql_editor.sql`** : les lignes P1, P2, P3 et G1 passent au ✅.

---

## 4. Table `contenus` : articles réels et données fictives

### P4 — `contenus_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using ((visible_public and not est_test) or (select prive.est_admin()))` |
| Pourquoi | Le public ne voit que les **vrais** articles visibles. Les données fictives, qui servent à atteindre 500 lignes, et les articles masqués restent internes. |
| Résultat attendu | anon voit l'article réel visible, mais ni le masqué ni le fictif ; l'admin voit les trois. |
| ⚠ Piège | Oublier `not est_test` : les fausses données apparaîtraient comme de vraies publications. |

```sql
create policy contenus_lecture on public.contenus
  for select to anon, authenticated
  using ((visible_public and not est_test) or (select prive.est_admin()));
```

### P5 — `contenus_ajout` et P6 — `contenus_modif`
Elles sont réservées aux administrateurs, avec les mêmes formes que P2 et P3. Les contraintes de la base imposent qu'une donnée fictive porte un titre `[FICTIF] …`, un domaine `.invalid` et un média « Média fictif… », et qu'elle ne soit jamais rattachée à un organisme réel.

```sql
create policy contenus_ajout on public.contenus
  for insert to authenticated
  with check ((select prive.est_admin()));

create policy contenus_modif on public.contenus
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));
```

### G2 — GRANT de `contenus`
```sql
grant select on public.contenus to anon, authenticated;
grant insert, update on public.contenus to authenticated;
```
▶ Relancez les tests : P4 à P6 et G2 passent au ✅.

---

## 5. Table `affirmations` ⚠ (contient les analyses non publiées)

### P7 — `affirmations_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using ((statut_analyse in ('analyse_disponible', 'verification_insuffisante') and exists (select 1 from public.contenus c where c.id = contenu_id)) or (select prive.est_admin()))` |
| Pourquoi | Le public voit les analyses publiées **et les abstentions** : dire « nous n'avons pas pu vérifier » fait partie de la transparence. Les statuts `non_traite`, `en_cours`, `revue_requise` et `retire` restent internes. Le `exists` passe par P4 : une analyse d'un article masqué reste cachée. |
| Résultat attendu | anon voit l'analyse publiée et l'abstention, mais ni l'analyse en cours, ni la revue, ni le retrait, ni le non-traité, ni l'analyse d'un article masqué ; l'admin voit les 7. |
| ⚠ Piège | Oublier le `exists` (une analyse d'article masqué devient visible) ou ajouter `revue_requise` (un cas sensible pas encore relu devient public). |

```sql
create policy affirmations_lecture on public.affirmations
  for select to anon, authenticated
  using (
    (statut_analyse in ('analyse_disponible', 'verification_insuffisante')
     and exists (select 1 from public.contenus c where c.id = contenu_id))
    or (select prive.est_admin())
  );
```

### P8 — `affirmations_ajout` et P9 — `affirmations_modif`
Elles sont réservées aux administrateurs. Le **trigger** contrôle ensuite chaque changement de statut :
- un administrateur doit donner un **motif** (`revue_motif`) à chaque décision ; ce motif est archivé dans `historique` ;
- une analyse publiée est figée ; pour la corriger, on la renvoie en `non_traite`, ce qui crée une nouvelle version ;
- un cas sensible ne se publie qu'après passage par `revue_requise` et décision d'un administrateur.

```sql
create policy affirmations_ajout on public.affirmations
  for insert to authenticated
  with check ((select prive.est_admin()));

create policy affirmations_modif on public.affirmations
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));
```

### G3 — GRANT de `affirmations`
```sql
grant select on public.affirmations to anon, authenticated;
grant insert, update on public.affirmations to authenticated;
```
Il n'y a pas de `delete` : une analyse se retire, elle ne s'efface pas.

▶ Relancez les tests : P7 à P9, G3 et **W1 à W7** passent au ✅.

| Test | Ce qu'il prouve (trigger, indépendant des policies) |
|---|---|
| W1 | Une décision d'administrateur sans motif est refusée |
| W2 | Un cas sensible est publié après revue motivée |
| W3 | Un verdict « vrai » sans preuve primaire vérifiée est refusé |
| W4 | La clé `service_role` ne peut pas modifier une analyse |
| W5 | Une analyse publiée est figée |
| W6 | Aucune affirmation n'est possible sur un contenu fictif |
| W7 | Un compte anonyme avec un rôle `admin` forgé n'obtient rien |

---

## 6. Table `preuves` ⚠ (révèle les analyses en cours et les échecs)

### P10 — `preuves_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using ((statut_preuve = 'verifiee' and exists (select 1 from public.affirmations a where a.id = affirmation_id and a.version = version_analyse)) or (select prive.est_admin()))` |
| Pourquoi | Le public ne voit que les preuves **vérifiées** de la **version publiée** d'une analyse visible. Le `exists` passe par P7. Les échecs (document inaccessible ou rejeté) restent consultables par l'équipe pour l'audit. |
| Résultat attendu | anon voit la preuve vérifiée de l'analyse publiée, mais ni l'échec tracé ni la preuve d'une analyse en cours ; l'admin voit tout. |

```sql
create policy preuves_lecture on public.preuves
  for select to anon, authenticated
  using (
    (statut_preuve = 'verifiee'
     and exists (select 1 from public.affirmations a
                  where a.id = affirmation_id and a.version = version_analyse))
    or (select prive.est_admin())
  );
```

### P11 — `preuves_ajout` et P12 — `preuves_modif`
Elles sont réservées aux administrateurs, pour une analyse manuelle exceptionnelle. Le trigger ajoute ses propres règles :
- une preuve ne s'écrit que pendant l'analyse (`en_cours`) ;
- un document « vérifié » doit appartenir au **périmètre** de l'organisme cité ;
- pas d'extrait pour AFP Factuel, qui est une source sous licence.

```sql
create policy preuves_ajout on public.preuves
  for insert to authenticated
  with check ((select prive.est_admin()));

create policy preuves_modif on public.preuves
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));
```

### G4 — GRANT de `preuves`
```sql
grant select on public.preuves to anon, authenticated;
grant insert, update on public.preuves to authenticated;
```

---

## 7. Vues `v_feed_verifie` et `v_analyses_publiques`

Il n'y a pas de policy à créer. Les vues sont en `security_invoker = true` : elles appliquent **les policies des tables** à celui qui les lit.
```sql
grant select on public.v_feed_verifie, public.v_analyses_publiques to anon, authenticated;
```
▶ Relancez `tests_sql_editor.sql` : **tout doit être ✅ (52 essais)**.

## 8. Tests réels via l'API

1. Définissez, sur votre machine et jamais dans GitHub, les variables listées en tête de `tests_api.mjs`. Utilisez la **clé publique** (Project Settings > API Keys) : le script refuse une clé secrète.
2. Lancez `node supabase/rls_manuel/tests_api.mjs`. Tout doit être ✅. Le script vérifie notamment qu'un visiteur qui écrit `role_equipe: admin` dans ses `user_metadata` ne gagne aucun droit.
3. Exécutez `nettoyage_tests_api.sql` : vérifiez les nombres de lignes, puis décommentez les deux `delete`.

## 9. Contrôle final
- [ ] `select count(*) from pg_policies where schemaname = 'public'` donne **18** (12 policies clients et 6 du pipeline)
- [ ] `tests_sql_editor.sql` : 100 % ✅
- [ ] `tests_api.mjs` : 100 % ✅, puis nettoyage
- [ ] **Advisors > Security** : aucune alerte nouvelle
- [ ] Chaque membre sait expliquer une policy à l'oral (rôle, opération, condition, test)

## 10. Questions pour l'oral
1. **Pourquoi les abstentions sont-elles publiques ?** Dire « preuves insuffisantes » est une information, et cela montre que l'outil n'invente rien.
2. **Pourquoi le pipeline n'utilise-t-il pas la clé `service_role` ?** Cette clé contourne toute la RLS et donne accès à tout le projet. Le rôle `demelo_pipeline` ne peut que lire et écrire ce qui le concerne, et ne peut rien supprimer : c'est le **moindre privilège**.
3. **Pourquoi `app_metadata` et pas `user_metadata` ?** Voir le test d'élévation de `tests_api.mjs`.
4. **Que garantit vraiment la base ?** L'intégrité et les conditions de publication : preuves téléchargées et vérifiées, périmètre de l'organisme, revue des cas sensibles. Elle ne garantit **pas** que l'analyse est juste : c'est pourquoi chaque fiche affiche ses limites et la mention « Analyse produite par IA ».
