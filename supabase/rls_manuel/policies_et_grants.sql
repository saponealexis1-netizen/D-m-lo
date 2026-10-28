-- =====================================================================
--  RLS MANUELLES — Démêlo v2
-- =====================================================================
--  ⚠ CE FICHIER N'EST PAS UNE MIGRATION ET NE DOIT PAS ÊTRE EXÉCUTÉ D'UN BLOC.
--  Il sert de référence au tutoriel docs/tutoriel-rls.md : l'équipe crée
--  chaque policy à la main, la comprend, puis la teste avant de passer à la
--  suivante. Il ne doit jamais être placé dans supabase/migrations/.
--
--  Ordre imposé pour chaque table (aucune exposition accidentelle) :
--    1. créer les policies de la table (sans GRANT, elles n'ouvrent rien) ;
--    2. donner les GRANT de la table ;
--    3. lancer les tests du tutoriel pour cette table.
--  Ne jamais écrire `using (true)` sur affirmations ou preuves.
--
--  Rappel : la publication reste protégée par les triggers du schéma
--  (prive.controler_affirmation, prive.controler_preuve), même si une policy
--  était trop permissive.
-- =====================================================================


-- =====================================================================
-- TABLE 1 — sources
-- =====================================================================

-- P1. Lecture : tout le monde voit les sources actives ; l'équipe voit tout.
create policy sources_lecture on public.sources
  for select to anon, authenticated
  using (active or (select prive.est_membre()));

-- P2. Ajout : réservé à l'équipe.
create policy sources_ajout on public.sources
  for insert to authenticated
  with check ((select prive.est_membre()));

-- P3. Modification : réservée à l'équipe (avant ET après modification).
create policy sources_modif on public.sources
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));

-- G1. Droits de la table sources (pas de DELETE : une source citée ne disparaît pas).
grant select on public.sources to anon, authenticated;
grant insert, update on public.sources to authenticated;


-- =====================================================================
-- TABLE 2 — contenus
-- =====================================================================

-- P4. Lecture : le public voit les articles visibles ; l'équipe voit tout.
create policy contenus_lecture on public.contenus
  for select to anon, authenticated
  using (visible_public or (select prive.est_membre()));

-- P5. Ajout : réservé à l'équipe.
create policy contenus_ajout on public.contenus
  for insert to authenticated
  with check ((select prive.est_membre()));

-- P6. Modification : réservée à l'équipe.
create policy contenus_modif on public.contenus
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));

-- G2. Droits de la table contenus (pas de DELETE côté client).
grant select on public.contenus to anon, authenticated;
grant insert, update on public.contenus to authenticated;


-- =====================================================================
-- TABLE 3 — affirmations   (⚠ contient les brouillons)
-- =====================================================================

-- P7. Lecture : le public ne voit QUE les affirmations publiées.
create policy affirmations_lecture on public.affirmations
  for select to anon, authenticated
  using (statut_workflow = 'publie' or (select prive.est_membre()));

-- P8. Ajout : un membre crée un brouillon en son propre nom.
create policy affirmations_ajout on public.affirmations
  for insert to authenticated
  with check (
    (select prive.est_membre())
    and created_by = (select auth.uid())
    and statut_workflow = 'brouillon'
  );

-- P9. Modification : réservée à l'équipe. Les transitions (relecture,
--     publication, relecteur ≠ auteur) sont contrôlées par le trigger.
create policy affirmations_modif on public.affirmations
  for update to authenticated
  using ((select prive.est_membre()))
  with check ((select prive.est_membre()));

-- P10. Suppression : seulement son propre brouillon.
create policy affirmations_suppression on public.affirmations
  for delete to authenticated
  using (
    (select prive.est_membre())
    and statut_workflow = 'brouillon'
    and created_by = (select auth.uid())
  );

-- G3. Droits de la table affirmations.
grant select on public.affirmations to anon, authenticated;
grant insert, update, delete on public.affirmations to authenticated;


-- =====================================================================
-- TABLE 4 — preuves   (⚠ révèlent le contenu des brouillons)
-- =====================================================================

-- P11. Lecture : le public voit uniquement les preuves d'affirmations publiées.
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

-- P12. Ajout : un membre ajoute une preuve en son propre nom
--      (le trigger refuse si l'affirmation n'est plus en brouillon).
create policy preuves_ajout on public.preuves
  for insert to authenticated
  with check ((select prive.est_membre()) and ajoutee_par = (select auth.uid()));

-- P13. Suppression : réservée à l'équipe (trigger : brouillon uniquement).
create policy preuves_suppression on public.preuves
  for delete to authenticated
  using ((select prive.est_membre()));

-- G4. Droits de la table preuves (pas d'UPDATE : on supprime et on recrée).
grant select on public.preuves to anon, authenticated;
grant insert, delete on public.preuves to authenticated;


-- =====================================================================
-- VUE — v_feed_verifie (en dernier : elle s'appuie sur les 4 tables)
-- =====================================================================

-- G5. La vue applique la RLS des tables (security_invoker) : aucune policy à créer.
grant select on public.v_feed_verifie to anon, authenticated;
