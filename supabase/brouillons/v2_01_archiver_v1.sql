-- =====================================================================
--  BROUILLON — NE PAS APPLIQUER SANS VALIDATION EXPLICITE
--  Étape 1/3 de la reconstruction : mettre le schéma v1 à l'écart
-- =====================================================================
--  Option recommandée : ARCHIVER plutôt que supprimer. Les 13 tables v1, leur
--  vue, leurs fonctions et leurs types sont déplacés dans le schéma
--  `archive_v1`, qui n'est pas exposé par l'API Supabase. Rien n'est perdu et
--  l'opération est réversible (voir docs/plan-reconstruction.md, « Retour arrière »).
--
--  Une sauvegarde complète existe aussi dans sauvegarde/2026-10-28_schema_v1/.
--
--  Conséquences :
--  * l'API ne voit plus aucune table v1 (le front v1 n'existe pas, rien ne casse) ;
--  * le trigger apres_creation_utilisateur sur auth.users est supprimé : sinon
--    chaque inscription échouerait (il écrit dans public.profils, archivée) ;
--  * les 2 tâches pg_cron v1 sont désactivées (elles visent des tables archivées).
-- =====================================================================

begin;

create schema archive_v1;
comment on schema archive_v1 is 'Schéma Démêlo v1 archivé le <date d''application>. Non exposé par l''API.';

-- 1. Ce qui dépend de auth.users ou s'exécute seul
drop trigger if exists apres_creation_utilisateur on auth.users;
select cron.unschedule(jobname) from cron.job
 where jobname in ('purge-messages-chatbot', 'purge-visiteurs-anonymes');

-- 2. Vue et tables (index, contraintes, policies, triggers et séquences suivent)
alter view  public.affirmations_publiques set schema archive_v1;
alter table public.affirmation_candidats  set schema archive_v1;
alter table public.affirmation_sources    set schema archive_v1;
alter table public.signalements           set schema archive_v1;
alter table public.messages               set schema archive_v1;
alter table public.affirmations           set schema archive_v1;
alter table public.articles               set schema archive_v1;
alter table public.candidats              set schema archive_v1;
alter table public.sources                set schema archive_v1;
alter table public.organismes             set schema archive_v1;
alter table public.medias                 set schema archive_v1;
alter table public.verdicts               set schema archive_v1;
alter table public.parametres             set schema archive_v1;
alter table public.profils                set schema archive_v1;

-- 3. Fonctions v1 (dont role_courant() et questions_restantes(), exposées à anon)
alter function public.controler_source()                         set schema archive_v1;
alter function public.creer_profil()                             set schema archive_v1;
alter function public.est_admin()                                set schema archive_v1;
alter function public.est_anonyme()                              set schema archive_v1;
alter function public.est_editeur()                              set schema archive_v1;
alter function public.proteger_sources_publiees()                set schema archive_v1;
alter function public.questions_restantes()                      set schema archive_v1;
alter function public.rechercher_sources(extensions.vector, integer) set schema archive_v1;
alter function public.role_courant()                             set schema archive_v1;
alter function public.traiter_signalement()                      set schema archive_v1;
alter function public.verifier_sources_avant_publication()       set schema archive_v1;

-- 4. Types v1
alter type public.auteur_message     set schema archive_v1;
alter type public.reutilisation      set schema archive_v1;
alter type public.role_utilisateur   set schema archive_v1;
alter type public.statut_affirmation set schema archive_v1;
alter type public.statut_article     set schema archive_v1;
alter type public.type_organisme     set schema archive_v1;

-- 5. Personne ne peut plus rien lire ni exécuter dans l'archive via les rôles de l'API
revoke all on schema archive_v1 from public, anon, authenticated;
revoke all on all tables    in schema archive_v1 from anon, authenticated;
revoke all on all functions in schema archive_v1 from public, anon, authenticated;

-- Contrôle : plus aucun objet v1 dans public (doit renvoyer 0 ligne)
do $$
begin
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind in ('r', 'v')) then
    raise exception 'Il reste des tables ou vues dans public : archivage incomplet.';
  end if;
end $$;

commit;
