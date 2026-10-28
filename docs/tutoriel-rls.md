# Tutoriel : configurer les RLS de Démêlo à la main

Ce tutoriel vous fait créer vous-mêmes, dans Supabase, les **13 policies** et les **5 GRANT** de Démêlo v2, en les comprenant et en les testant une par une.

- Fichier de référence : `supabase/rls_manuel/policies_et_grants.sql`. **À ne jamais exécuter d'un bloc** : on y recopie une policy à la fois.
- Tests : `supabase/rls_manuel/tests_sql_editor.sql` (SQL Editor) et `supabase/rls_manuel/tests_api.mjs` (API réelle).
- Prérequis : les migrations `v2_01` à `v2_03` ont été appliquées. La base est alors **fermée** : RLS activée, 0 policy, 0 GRANT pour les clients.

---

## 0. Les règles d'or

1. **Ordre imposé pour chaque table : policies → GRANT → tests.** Une policy sans GRANT n'ouvre rien ; un GRANT sans policy ne montre aucune ligne, car la RLS refuse tout par défaut. En respectant cet ordre, aucune table n'est jamais exposée sans ses règles.
2. **Jamais `using (true)`** sur `affirmations` ou `preuves` : ce serait publier les brouillons.
3. **Une policy à la fois, puis un test.** Si un test passe au ❌, on corrige avant de continuer.
4. **La clé `service_role` / secrète ne sort jamais du dashboard** : pas dans le front, pas dans GitHub.
5. La **validation humaine** ne dépend pas de vous : les triggers `prive.controler_affirmation` et `prive.controler_preuve` la font respecter quoi que disent les policies. Les RLS décident **qui voit et touche quelles lignes** ; les triggers décident **si une publication est valable**.

## 1. Comprendre en 5 minutes

### Deux portes successives
| Couche | Question | Si elle refuse |
|---|---|---|
| **GRANT** | Ce rôle a-t-il le droit de tenter cette **action** sur cette table ? | `permission denied for table …` (HTTP 401/403) |
| **RLS (policies)** | Sur **quelles lignes** cette action est-elle permise ? | Lecture : 0 ligne, sans erreur. Écriture : `new row violates row-level security policy` (HTTP 403) |

### Les rôles
- `anon` : visiteur sans compte. Le front utilise la clé publique.
- `authenticated` : utilisateur connecté (un membre de l'équipe ou un simple inscrit).
- Le **rôle d'équipe** n'est pas un rôle Postgres : c'est `app_metadata.role_equipe` dans le JWT, lu par les fonctions `prive.est_membre()` (éditeur ou relecteur) et `prive.est_relecteur()`. Un utilisateur ne peut pas modifier son `app_metadata`, et un compte anonyme n'a jamais de rôle.

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
- `(select prive.est_membre())` entre parenthèses : la fonction est calculée **une seule fois par requête** et non à chaque ligne (performances).

## 2. Préparation

### 2.1 Vérifier que la base est fermée
Dans **SQL Editor**, exécuter :
```sql
select tablename, rowsecurity from pg_tables where schemaname = 'public';   -- 4 lignes, toutes true
select count(*) from pg_policies where schemaname = 'public';               -- 0
```
Puis coller et exécuter **tout** `supabase/rls_manuel/tests_sql_editor.sql` (voir 2.2 pour les comptes). Résultat attendu : **uniquement des ⏳ et des ✅**, aucun ❌. Les ✅ sont les refus attendus.

### 2.2 Créer les 3 comptes de test
**Authentication > Users > Add user > Create new user**, en cochant **Auto Confirm User** :
- `editeur@demelo.test`
- `relecteur@demelo.test`
- `visiteur@demelo.test`

Puis, dans le SQL Editor :
```sql
update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role_equipe": "editeur"}'
 where email = 'editeur@demelo.test';
update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role_equipe": "relecteur"}'
 where email = 'relecteur@demelo.test';
-- visiteur@demelo.test : volontairement aucun rôle (compte connecté sans droits).
```
Faites de même pour vos 4 vrais comptes d'équipe. Un membre doit **se reconnecter** pour que son rôle apparaisse dans son JWT.

### 2.3 Où écrire les policies
- **Recommandé : SQL Editor.** On colle le bloc `create policy …` du fichier de référence ; c'est précis et reproductible.
- **Alternative : Authentication > Policies > (table) > Create policy.** Champs à remplir : *Policy name*, *Policy command* (SELECT…), *Target roles* (anon, authenticated), *USING expression* et *WITH CHECK expression* : on y recopie les conditions du fichier, sans `using (` ni `)`.

### 2.4 Tester une policy à la main (modèle)
```sql
begin;
-- 1) Choisir l'identité AVANT de changer de rôle
select set_config('request.jwt.claims', '{"role": "anon"}', true);          -- visiteur
-- ou, pour un membre :
-- select set_config('request.jwt.claims', json_build_object('sub', id, 'role', 'authenticated',
--          'app_metadata', raw_app_meta_data)::text, true) from auth.users where email = 'editeur@demelo.test';
set local role anon;            -- ou authenticated
-- 2) La requête à tester
select count(*) from public.sources;
rollback;                       -- 3) Rien n'est conservé
```
Le script `tests_sql_editor.sql` fait la même chose pour tous les cas, et affiche ✅ / ❌ / ⏳.

---

## 3. Table `sources`

Contenu : médias, institutions et fact-checkeurs. Ce sont des informations publiques, sans brouillons.

### P1 — `sources_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using (active or (select prive.est_membre()))` |
| Pourquoi | Le public doit voir d'où viennent les articles et les preuves. Une source désactivée n'est visible que par l'équipe. |
| Résultat attendu | anon voit les sources actives, pas les inactives ; un éditeur voit tout. |
| Tests | P1 × 3 dans `tests_sql_editor.sql` |

```sql
create policy sources_lecture on public.sources
  for select to anon, authenticated
  using (active or (select prive.est_membre()));
```

### P2 — `sources_ajout`
| | |
|---|---|
| Rôles | `authenticated` (anon n'aura de toute façon pas le GRANT `insert`) |
| Opération | `insert` |
| Condition | `with check ((select prive.est_membre()))` |
| Pourquoi | Seule l'équipe enrichit la liste des sources. |
| Résultat attendu | L'éditeur ajoute une source ; un compte connecté sans rôle reçoit `new row violates row-level security policy`. |
| Tests | P2 × 2 |

```sql
create policy sources_ajout on public.sources
  for insert to authenticated
  with check ((select prive.est_membre()));
```

### P3 — `sources_modif`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `update` |
| Condition | `using ((select prive.est_membre())) with check ((select prive.est_membre()))` |
| Pourquoi | `using` : on ne peut viser que si l'on est membre. `with check` : la ligne modifiée doit rester acceptable. |
| Résultat attendu | L'éditeur modifie ; un compte sans rôle modifie **0 ligne**, sans erreur : la ligne lui est invisible pour l'`update`. |
| Tests | P3 × 2 |

```sql
create policy sources_modif on public.sources
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));
```

### G1 — GRANT de `sources`
```sql
grant select on public.sources to anon, authenticated;
grant insert, update on public.sources to authenticated;
```
Il n'y a **pas de `delete`** : une source citée par des preuves ne doit pas disparaître. Le test G1 vérifie que anon ne peut pas écrire et qu'un éditeur ne peut pas supprimer (`permission denied`).

▶ **Relancer `tests_sql_editor.sql`** : les lignes P1, P2, P3 et G1 passent au ✅.

---

## 4. Table `contenus`

Contenu : les 500 articles indexés. Un article peut être masqué (`visible_public = false`).

### P4 — `contenus_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using (visible_public or (select prive.est_membre()))` |
| Pourquoi | Le flux public n'affiche que les articles visibles ; l'équipe voit aussi les articles masqués (en préparation, doublons…). |
| Résultat attendu | anon voit l'article visible, pas le masqué ; l'éditeur voit les deux. |
| Tests | P4 × 3 |

```sql
create policy contenus_lecture on public.contenus
  for select to anon, authenticated
  using (visible_public or (select prive.est_membre()));
```

### P5 — `contenus_ajout`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `insert` |
| Condition | `with check ((select prive.est_membre()))` |
| Résultat attendu | L'éditeur indexe un article ; un compte sans rôle est refusé. |
| Tests | P5 × 2 |

```sql
create policy contenus_ajout on public.contenus
  for insert to authenticated
  with check ((select prive.est_membre()));
```

### P6 — `contenus_modif`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `update` |
| Condition | `using ((select prive.est_membre())) with check ((select prive.est_membre()))` |
| Résultat attendu | L'éditeur classe un article par thème ; un compte sans rôle modifie 0 ligne. |
| Tests | P6 × 2 |

```sql
create policy contenus_modif on public.contenus
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));
```

### G2 — GRANT de `contenus`
```sql
grant select on public.contenus to anon, authenticated;
grant insert, update on public.contenus to authenticated;
```
▶ Relancer les tests : P4 à P6 et G2 passent au ✅.

---

## 5. Table `affirmations` ⚠ (contient les brouillons)

C'est la table la plus sensible : un brouillon publié par erreur serait une **fausse vérification exposée au public**.

### P7 — `affirmations_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using (statut_workflow = 'publie' or (select prive.est_membre()))` |
| Pourquoi | Le public ne voit **que** ce qu'un relecteur a validé. Brouillon, relecture et retiré restent internes. |
| Résultat attendu | anon et un compte sans rôle : 0 brouillon ; l'éditeur voit les brouillons de toute l'équipe (pour relire et s'entraider). |
| Tests | P7 × 4 (dont « anon ne voit aucun brouillon ni relecture ») |
| ⚠ Piège | `using (true)` ou `using (auth.role() = 'authenticated')` ferait fuiter les brouillons : tout inscrit les verrait. |

```sql
create policy affirmations_lecture on public.affirmations
  for select to anon, authenticated
  using (statut_workflow = 'publie' or (select prive.est_membre()));
```

### P8 — `affirmations_ajout`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `insert` |
| Condition | `with check ((select prive.est_membre()) and created_by = (select auth.uid()) and statut_workflow = 'brouillon')` |
| Pourquoi | On ne crée qu'en **brouillon**, et en **son propre nom**. C'est la base de la traçabilité auteur / relecteur. |
| Résultat attendu | L'éditeur crée un brouillon ; « créer directement publié » est refusé ; un compte sans rôle est refusé. |
| Tests | P8 × 3 |

```sql
create policy affirmations_ajout on public.affirmations
  for insert to authenticated
  with check (
    (select prive.est_membre())
    and created_by = (select auth.uid())
    and statut_workflow = 'brouillon'
  );
```

### P9 — `affirmations_modif`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `update` |
| Condition | `using ((select prive.est_membre())) with check ((select prive.est_membre()))` |
| Pourquoi | La policy dit seulement **qui** peut modifier (l'équipe). **Comment** on change d'état (relecture, publication, relecteur ≠ auteur, texte figé) est contrôlé par le trigger, testé par W1 à W7. |
| Résultat attendu | L'éditeur complète son brouillon ; un compte sans rôle modifie 0 ligne. |
| Tests | P9 × 2, puis W1 à W7 |

```sql
create policy affirmations_modif on public.affirmations
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));
```

### P10 — `affirmations_suppression`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `delete` |
| Condition | `using ((select prive.est_membre()) and statut_workflow = 'brouillon' and created_by = (select auth.uid()))` |
| Pourquoi | On peut jeter **son propre brouillon**, jamais celui d'un autre, jamais une vérification publiée (on la *retire*, ce qui laisse une trace). |
| Résultat attendu | L'éditeur supprime son brouillon ; 0 ligne pour le brouillon d'un autre ; 0 ligne pour une affirmation publiée, même pour un relecteur. |
| Tests | P10 × 3 |

```sql
create policy affirmations_suppression on public.affirmations
  for delete to authenticated
  using (
    (select prive.est_membre())
    and statut_workflow = 'brouillon'
    and created_by = (select auth.uid())
  );
```

### G3 — GRANT de `affirmations`
```sql
grant select on public.affirmations to anon, authenticated;
grant insert, update, delete on public.affirmations to authenticated;
```
▶ Relancer les tests : P7 à P10, G3 et **W1 à W7** (validation humaine) passent au ✅.

| Test | Ce qu'il prouve (trigger, indépendant des policies) |
|---|---|
| W1 | Un éditeur ne peut pas publier |
| W2 | Un relecteur publie l'affirmation **d'un autre** |
| W3 | Un relecteur ne peut pas valider **sa propre** affirmation |
| W4 | La clé `service_role` (script, IA) ne peut pas publier |
| W5 | Pas d'envoi en relecture sans preuve |
| W6 | Une affirmation publiée est figée |
| W7 | Un compte anonyme avec un rôle forgé n'obtient rien |

---

## 6. Table `preuves` ⚠ (révèle le contenu des brouillons)

Une preuve d'un brouillon (son URL, sa note) en dit long sur une vérification pas encore validée : elle doit rester aussi cachée que le brouillon.

### P11 — `preuves_lecture`
| | |
|---|---|
| Rôles | `anon`, `authenticated` |
| Opération | `select` |
| Condition | `using ((select prive.est_membre()) or exists (select 1 from public.affirmations a where a.id = affirmation_id and a.statut_workflow = 'publie'))` |
| Pourquoi | Une preuve est publique **si et seulement si** son affirmation est publiée. |
| Résultat attendu | anon voit la preuve de l'affirmation publiée, pas celle du brouillon ; l'éditeur voit tout. |
| Tests | P11 × 3 |
| ⚠ Piège | Écrire `using (true)` en pensant « les preuves sont des liens publics » : cela révèle les brouillons. |

```sql
create policy preuves_lecture on public.preuves
  for select to anon, authenticated
  using (
    (select prive.est_membre())
    or exists (
      select 1 from public.affirmations a
       where a.id = affirmation_id
         and a.statut_workflow = 'publie'
    )
  );
```

### P12 — `preuves_ajout`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `insert` |
| Condition | `with check ((select prive.est_membre()) and ajoutee_par = (select auth.uid()))` |
| Pourquoi | L'équipe documente, en son nom. Le trigger ajoute deux règles : affirmation **en brouillon** uniquement, et **pas d'extrait** pour une source sous licence (droit voisin). |
| Résultat attendu | L'éditeur ajoute une preuve à un brouillon ; refus sur une affirmation publiée ; refus d'un extrait du Monde ; refus pour un compte sans rôle. |
| Tests | P12 × 4 |

```sql
create policy preuves_ajout on public.preuves
  for insert to authenticated
  with check ((select prive.est_membre()) and ajoutee_par = (select auth.uid()));
```

### P13 — `preuves_suppression`
| | |
|---|---|
| Rôles | `authenticated` |
| Opération | `delete` |
| Condition | `using ((select prive.est_membre()))` |
| Pourquoi | Corriger un brouillon. Le trigger interdit de retirer la preuve d'une affirmation publiée. |
| Résultat attendu | L'éditeur supprime la preuve d'un brouillon ; refus pour une affirmation publiée. |
| Tests | P13 × 2 |

```sql
create policy preuves_suppression on public.preuves
  for delete to authenticated
  using ((select prive.est_membre()));
```

### G4 — GRANT de `preuves`
```sql
grant select on public.preuves to anon, authenticated;
grant insert, delete on public.preuves to authenticated;
```
Il n'y a pas d'`update` : une preuve fausse se supprime et se recrée, en brouillon.

---

## 7. Vue `v_feed_verifie`

Pas de policy à créer : la vue est en `security_invoker = true`, elle applique **les policies des tables** à celui qui la lit. Un visiteur n'y compte donc que les affirmations publiées.

### G5
```sql
grant select on public.v_feed_verifie to anon, authenticated;
```
▶ Relancer `tests_sql_editor.sql` : **tout doit être ✅** (49 essais).

## 8. Tests réels via l'API (anon, éditeur, relecteur)

Ce sont les tests « comme un vrai front » : clé publique, vraies connexions, vrais JWT.
1. Les 3 comptes de test doivent avoir un mot de passe : le saisir à la création (Add user > Create new user). Les adresses `@demelo.test` ne reçoivent pas d'e-mail, donc la récupération de mot de passe ne fonctionne pas pour elles.
2. Sur votre machine (jamais dans GitHub), définir les variables listées en tête de `supabase/rls_manuel/tests_api.mjs`, avec la **clé publique** (Project Settings > API Keys). Le script refuse une clé secrète.
3. `node supabase/rls_manuel/tests_api.mjs` → tout doit être ✅. Il teste notamment qu'un éditeur qui s'attribue `role_equipe` dans ses `user_metadata` ne peut toujours pas publier.
4. Exécuter `supabase/rls_manuel/nettoyage_tests_api.sql` : vérifier les nombres, puis décommenter les deux `delete`.

## 9. Contrôle final
- **Advisors > Security Advisor** : aucune alerte sur les 4 tables, ni sur `rls_auto_enable`.
- **Authentication > Sign In / Providers** : connexions anonymes **désactivées** (non utilisées par le MVP).
- Checklist :
  - [ ] 13 policies (`select count(*) from pg_policies where schemaname = 'public'` → 13)
  - [ ] `tests_sql_editor.sql` : 100 % ✅
  - [ ] `tests_api.mjs` : 100 % ✅, puis nettoyage
  - [ ] Chaque membre sait expliquer une policy à l'oral (rôle, opération, condition, test)

## 10. Pour aller plus loin (questions pour l'oral)
1. **Que se passe-t-il si on oublie `with check` dans P3 ?** Un membre pourrait-il « transformer » une ligne en une ligne qu'il ne devrait pas créer ? Ici le risque est faible (même condition), mais pourquoi est-ce essentiel en général ?
2. **P7 et les articles masqués** : une affirmation publiée reste visible même si son article est masqué. Faut-il ajouter `and exists (select 1 from contenus c where c.id = contenu_id and c.visible_public)` ? Avantages et coût.
3. **Pourquoi les rôles sont-ils dans `app_metadata` et pas dans `user_metadata` ?** (Réponse dans le test d'élévation de `tests_api.mjs`.)
4. **Pourquoi la validation humaine est-elle dans un trigger et pas dans une policy ?** Parce que la clé `service_role` contourne la RLS, alors qu'un trigger s'applique à tout le monde (test W4).
