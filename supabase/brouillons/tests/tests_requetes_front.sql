-- Rejoue, sur le schéma réel, les requêtes que le site (web/) envoie à PostgREST,
-- avec les rôles du site : anon (visiteur) puis authenticated admin. Base configurée + données fictives.
\set ON_ERROR_STOP 1
select set_config('request.jwt.claims', '{"role": "anon"}', false);
set role anon;
-- Fil (Fil.tsx), fiche (Article.tsx), indicateur (MiseAJour.tsx), sources (Sources.tsx)
select count(*) from (select * from public.v_feed_verifie order by date_publication desc nulls last, id desc limit 20 offset 0) f;
select * from public.v_feed_verifie where id = 1;
select * from public.v_analyses_publiques where contenu_id = 1 order by id;
select vu_le from public.contenus order by vu_le desc limit 1;
select id, nom, type_source, url_base, reutilisation, licence_info from public.sources where active order by nom;
do $$ begin
  if (select count(*) from public.sources where active) <> 15 then raise exception 'Front : 15 sources attendues.'; end if;
  if exists (select 1 from public.contenus where est_test) then raise exception 'Front : un visiteur voit des données fictives.'; end if;
end $$;
reset role;

select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-00000000e001', 'role', 'authenticated',
  'app_metadata', json_build_object('role_equipe', 'admin'))::text, false);
set role authenticated;
-- Espace équipe (Equipe.tsx) : chiffres et file de revue
do $$ begin
  if (select count(*) from public.contenus where est_test and lot_import = 'fictif-v1') <> 500 then raise exception 'Front : l''admin doit voir les 500 lignes fictives.'; end if;
end $$;
select count(*) from public.contenus where statut_traitement = 'non_traite';
select count(*) from public.affirmations where statut_analyse = 'revue_requise';
select a.id, a.texte_affirmation, a.verdict, a.explication, a.motif_sensibilite, a.motif_abstention, a.version, a.analyse_le,
       c.titre, c.url_originale, c.media_nom,
       (select json_agg(p) from (select id, url_finale, url_preuve, titre_document, type_relation, nature, statut_preuve, version_analyse
                                   from public.preuves where affirmation_id = a.id) p)
  from public.affirmations a join public.contenus c on c.id = a.contenu_id
 where a.statut_analyse = 'revue_requise' order by a.analyse_le;
reset role;
select set_config('request.jwt.claims', '', false);
do $$ begin raise notice 'Requêtes du site : OK (visiteur et admin).'; end $$;
