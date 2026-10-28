-- =====================================================================
--  RLS MANUELLES — Démêlo v2 (pipeline IA, à partir de la migration v2_05)
-- =====================================================================
--  ⚠ CE FICHIER N'EST PAS UNE MIGRATION ET NE DOIT PAS ÊTRE EXÉCUTÉ D'UN BLOC.
--  Il sert de référence au tutoriel docs/tutoriel-rls.md : l'équipe crée
--  chaque policy à la main, la comprend, puis la teste avant de passer à la
--  suivante. Il ne doit jamais être placé dans supabase/migrations/.
--
--  Trois profils clients :
--    * visiteur (anon)                : lit uniquement ce qui est public ;
--    * compte connecté sans rôle       : mêmes droits qu'un visiteur ;
--    * administrateur (role_equipe = 'admin', les 4 membres) : voit tout,
--      corrige, retire, valide les revues exceptionnelles.
--  Le pipeline IA a son propre rôle serveur (demelo_pipeline), déjà configuré
--  par la migration v2_05 : il n'est pas concerné par ce fichier.
--
--  Ordre imposé pour chaque table (aucune exposition accidentelle) :
--    1. créer les policies de la table (sans GRANT, elles n'ouvrent rien) ;
--    2. donner les GRANT de la table ;
--    3. lancer les tests du tutoriel pour cette table.
--  Ne jamais écrire `using (true)` sur affirmations ou preuves.
--
--  Rappel : les conditions de publication (preuves vérifiées, revue des cas
--  sensibles, données fictives exclues) sont garanties par les triggers de
--  v2_05, même si une policy était trop permissive.
-- =====================================================================


-- =====================================================================
-- TABLE 1 — sources (les 15 organismes de vérification)
-- =====================================================================

-- P1. Lecture : tout le monde voit les organismes actifs ; l'admin voit tout.
create policy sources_lecture on public.sources
  for select to anon, authenticated
  using (active or (select prive.est_admin()));

-- P2. Ajout : réservé aux administrateurs (aucun organisme sans accord de l'équipe).
create policy sources_ajout on public.sources
  for insert to authenticated
  with check ((select prive.est_admin()));

-- P3. Modification : réservée aux administrateurs.
create policy sources_modif on public.sources
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));

-- G1. Droits de la table sources (pas de DELETE : une source citée ne disparaît pas).
grant select on public.sources to anon, authenticated;
grant insert, update on public.sources to authenticated;


-- =====================================================================
-- TABLE 2 — contenus (articles réels et données fictives)
-- =====================================================================

-- P4. Lecture : le public voit les articles réels visibles ; l'admin voit tout,
--     y compris les données fictives (est_test) et les articles masqués.
create policy contenus_lecture on public.contenus
  for select to anon, authenticated
  using ((visible_public and not est_test) or (select prive.est_admin()));

-- P5. Ajout : réservé aux administrateurs (import, données fictives de test).
create policy contenus_ajout on public.contenus
  for insert to authenticated
  with check ((select prive.est_admin()));

-- P6. Modification : réservée aux administrateurs.
create policy contenus_modif on public.contenus
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));

-- G2. Droits de la table contenus (pas de DELETE côté client).
grant select on public.contenus to anon, authenticated;
grant insert, update on public.contenus to authenticated;


-- =====================================================================
-- TABLE 3 — affirmations   (⚠ contient les analyses non publiées)
-- =====================================================================

-- P7. Lecture : le public voit les analyses publiées et les abstentions, et
--     seulement si l'article est lui-même visible (la sous-requête passe par P4).
--     non_traite, en_cours, revue_requise et retire restent internes.
create policy affirmations_lecture on public.affirmations
  for select to anon, authenticated
  using (
    (statut_analyse in ('analyse_disponible', 'verification_insuffisante')
     and exists (select 1 from public.contenus c where c.id = contenu_id))
    or (select prive.est_admin())
  );

-- P8. Ajout : réservé aux administrateurs (le pipeline a son propre rôle).
create policy affirmations_ajout on public.affirmations
  for insert to authenticated
  with check ((select prive.est_admin()));

-- P9. Modification : réservée aux administrateurs (revue, correction, retrait).
--     Les transitions autorisées sont contrôlées par le trigger.
create policy affirmations_modif on public.affirmations
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));

-- G3. Droits de la table affirmations (pas de DELETE : on retire, on ne supprime pas).
grant select on public.affirmations to anon, authenticated;
grant insert, update on public.affirmations to authenticated;


-- =====================================================================
-- TABLE 4 — preuves   (⚠ révèlent les analyses non publiées et les échecs)
-- =====================================================================

-- P10. Lecture : le public voit uniquement les preuves VÉRIFIÉES de la version
--      publiée d'une analyse visible (la sous-requête passe par P7).
create policy preuves_lecture on public.preuves
  for select to anon, authenticated
  using (
    (statut_preuve = 'verifiee'
     and exists (select 1 from public.affirmations a
                  where a.id = affirmation_id and a.version = version_analyse))
    or (select prive.est_admin())
  );

-- P11. Ajout : réservé aux administrateurs (analyse manuelle exceptionnelle).
create policy preuves_ajout on public.preuves
  for insert to authenticated
  with check ((select prive.est_admin()));

-- P12. Modification : réservée aux administrateurs (trigger : pendant l'analyse uniquement).
create policy preuves_modif on public.preuves
  for update to authenticated
  using ((select prive.est_admin()))
  with check ((select prive.est_admin()));

-- G4. Droits de la table preuves (pas de DELETE : les échecs restent tracés).
grant select on public.preuves to anon, authenticated;
grant insert, update on public.preuves to authenticated;


-- =====================================================================
-- VUES — v_feed_verifie et v_analyses_publiques (en dernier)
-- =====================================================================

-- G5. Les vues appliquent les policies des tables (security_invoker) : aucune policy à créer.
grant select on public.v_feed_verifie, public.v_analyses_publiques to anon, authenticated;
