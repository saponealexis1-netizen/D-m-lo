-- Tests du schéma cible v2 : archivage, structure, RLS, workflow de validation humaine.
\set QUIET on
\o /dev/null
set client_min_messages = warning;

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
create table tests.resultats (n serial, nom text, ok boolean);
grant insert on tests.resultats to anon, authenticated, service_role;
grant usage on sequence tests.resultats_n_seq to anon, authenticated, service_role;

create function tests.verifier(nom text, ok boolean) returns void language sql as
  $$ insert into tests.resultats (nom, ok) values (nom, coalesce(ok, false)) $$;

-- Exécute une requête qui DOIT échouer (ou ne toucher aucune ligne si verifier_lignes).
create function tests.doit_echouer(nom text, requete text, verifier_lignes boolean default false) returns void
language plpgsql as $$
declare n bigint;
begin
  begin
    execute requete;
    get diagnostics n = row_count;
    insert into tests.resultats (nom, ok) values (nom, verifier_lignes and n = 0);
  exception when others then
    insert into tests.resultats (nom, ok) values (nom, true);
  end;
end $$;

-- Simule la session : sub = utilisateur, app_metadata.role_equipe = rôle d'équipe.
create function tests.session(sub text, role_equipe text default null, anonyme boolean default false) returns void
language sql as $$
  select set_config('request.jwt.claims', json_build_object(
    'sub', sub, 'role', 'authenticated', 'is_anonymous', anonyme,
    'app_metadata', case when role_equipe is null then '{}'::json else json_build_object('role_equipe', role_equipe) end)::text, false)
$$;
grant execute on all functions in schema tests to anon, authenticated, service_role;

insert into auth.users (id, email, is_anonymous, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'editeur@test',    false, '{"role_equipe": "editeur"}'),
  ('00000000-0000-0000-0000-0000000000b2', 'relecteur@test',  false, '{"role_equipe": "relecteur"}'),
  ('00000000-0000-0000-0000-0000000000c3', 'relecteur2@test', false, '{"role_equipe": "relecteur"}'),
  ('00000000-0000-0000-0000-0000000000d4', 'inscrit@test',    false, '{}'),
  ('00000000-0000-0000-0000-0000000000e5', null,              true,  '{}');

-- ---------------------------------------------------------------------
-- Archivage v1 et structure v2
-- ---------------------------------------------------------------------
select tests.verifier('archive : 13 tables v1 dans archive_v1', (select count(*) = 13 from pg_tables where schemaname = 'archive_v1'));
select tests.verifier('archive : données de référence conservées (37 lignes)',
  (select (select count(*) from archive_v1.parametres) + (select count(*) from archive_v1.verdicts)
        + (select count(*) from archive_v1.medias) + (select count(*) from archive_v1.organismes) = 37));
select tests.verifier('archive : trigger sur auth.users supprimé',
  not exists (select 1 from pg_trigger where tgname = 'apres_creation_utilisateur'));
select tests.verifier('archive : tâches cron v1 désactivées', (select count(*) = 0 from cron.job));
select tests.verifier('archive : anon sans accès au schéma', not has_schema_privilege('anon', 'archive_v1', 'usage'));
select tests.verifier('archive : role_courant() et questions_restantes() sortis de public',
  not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('role_courant', 'questions_restantes')));
select tests.verifier('v2 : exactement 4 tables dans public',
  (select array_agg(tablename::text order by tablename) = array['affirmations', 'contenus', 'preuves', 'sources'] from pg_tables where schemaname = 'public'));
select tests.verifier('v2 : RLS sur les 4 tables', (select bool_and(rowsecurity) from pg_tables where schemaname = 'public'));
select tests.verifier('v2 : pas de table profils', to_regclass('public.profils') is null);
select tests.verifier('v2 : 4 clés étrangères entre tables métier',
  (select count(*) = 4 from pg_constraint where contype = 'f' and connamespace = 'public'::regnamespace and confrelid::regclass::text not like 'auth.%'));
select tests.verifier('v2 : 28 sources de départ', (select count(*) = 28 from public.sources));
select tests.verifier('sécurité : rls_auto_enable() non exécutable par anon',
  not has_function_privilege('anon', 'public.rls_auto_enable()', 'execute'));
select tests.verifier('sécurité : rls_auto_enable() non exécutable par authenticated',
  not has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute'));
create table public.t_ensure_rls (id int);
select tests.verifier('sécurité : event trigger ensure_rls toujours actif',
  (select relrowsecurity from pg_class where oid = 'public.t_ensure_rls'::regclass));
drop table public.t_ensure_rls;
select tests.verifier('sécurité : fonctions de trigger non exécutables par anon',
  not has_function_privilege('anon', 'prive.controler_affirmation()', 'execute'));

-- ---------------------------------------------------------------------
-- Contenus : un éditeur indexe, un inscrit sans rôle et un anonyme ne peuvent pas.
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000a1', 'editeur');
set role authenticated;
insert into public.contenus (source_id, format, titre, url_originale, theme)
values ((select id from public.sources where nom = 'Le Monde'), 'article', 'Budget 2027 : ce que prévoit le projet de loi',
        'https://www.lemonde.fr/article-budget', 'economie');
insert into public.contenus (source_id, titre, url_originale, identifiant_externe)
values ((select id from public.sources where nom = 'franceinfo'), 'Chômage des jeunes : les chiffres du trimestre',
        'https://www.francetvinfo.fr/chomage-jeunes', 'guid-rss-123');
insert into public.contenus (source_id, format, titre, url_originale, visible_public)
values ((select id from public.sources where nom = 'Le Figaro'), 'article', 'Contenu masqué', 'https://www.lefigaro.fr/masque', false);
select tests.doit_echouer('contenu : format hors MVP (vidéo) refusé',
  $$ insert into public.contenus (source_id, format, titre, url_originale)
     values ((select id from public.sources where nom = 'franceinfo'), 'video', 'Vidéo', 'https://www.francetvinfo.fr/video') $$);
select tests.doit_echouer('contenu : même GUID RSS deux fois pour une source refusé',
  $$ insert into public.contenus (source_id, titre, url_originale, identifiant_externe)
     values ((select id from public.sources where nom = 'franceinfo'), 'Doublon GUID', 'https://www.francetvinfo.fr/autre', 'guid-rss-123') $$);
select tests.doit_echouer('contenu : URL en double refusée',
  $$ insert into public.contenus (source_id, format, titre, url_originale)
     values ((select id from public.sources where nom = 'Le Monde'), 'article', 'Doublon', 'https://www.lemonde.fr/article-budget') $$);
reset role;

select tests.session('00000000-0000-0000-0000-0000000000d4');
set role authenticated;
select tests.doit_echouer('inscrit sans rôle : ajout de contenu refusé',
  $$ insert into public.contenus (source_id, format, titre, url_originale)
     values (1, 'article', 'Tentative', 'https://exemple.fr/x') $$);
select tests.doit_echouer('inscrit sans rôle : ajout de source refusé',
  $$ insert into public.sources (nom, type_source, url_base) values ('Pirate', 'media', 'https://pirate.fr') $$);
reset role;

-- Un anonyme ne peut pas se donner un rôle via un faux app_metadata.
select tests.session('00000000-0000-0000-0000-0000000000e5', 'relecteur', true);
set role authenticated;
select tests.doit_echouer('anonyme avec rôle forgé : ajout refusé',
  $$ insert into public.contenus (source_id, format, titre, url_originale) values (1, 'article', 'Tentative', 'https://exemple.fr/y') $$);
reset role;

select set_config('request.jwt.claims', '{"role": "anon"}', false);  -- JWT de la clé publique
set role anon;
select tests.doit_echouer('anon : écriture refusée',
  $$ insert into public.sources (nom, type_source, url_base) values ('Pirate', 'media', 'https://pirate.fr') $$);
select tests.verifier('anon : voit les 2 contenus visibles, pas le masqué', (select count(*) = 2 from public.contenus));
reset role;

-- ---------------------------------------------------------------------
-- Workflow : brouillon -> en_relecture -> publie
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000a1', 'editeur');
set role authenticated;
select tests.doit_echouer('création directement publiée refusée',
  $$ insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication, statut_workflow, created_by)
     values ((select id from public.contenus where url_originale = 'https://www.lemonde.fr/article-budget'), 'Le déficit public atteindra 5 % du PIB.', 'vrai', 'Explication', 'publie', '00000000-0000-0000-0000-0000000000a1') $$);
-- Usurpation d'auteur : le trigger remplace created_by par l'utilisateur connecté.
insert into public.affirmations (contenu_id, texte_affirmation, created_by)
values ((select id from public.contenus where url_originale = 'https://www.lemonde.fr/article-budget'), 'Tentative d''usurpation de l''auteur.', '00000000-0000-0000-0000-0000000000b2');
select tests.verifier('création au nom d''un autre : auteur forcé à l''utilisateur connecté',
  (select created_by = '00000000-0000-0000-0000-0000000000a1' from public.affirmations where texte_affirmation like 'Tentative%'));
delete from public.affirmations where texte_affirmation like 'Tentative%';
insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
values ((select id from public.contenus where url_originale = 'https://www.lemonde.fr/article-budget'), 'Le déficit public atteindra 5,4 % du PIB en 2026.', 'vrai', 'Le chiffre figure dans le projet de loi de finances.');
select tests.doit_echouer('envoi en relecture sans preuve refusé',
  $$ update public.affirmations set statut_workflow = 'en_relecture' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
select tests.doit_echouer('extrait d''une source sous licence refusé',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, extrait)
     values ((select id from public.affirmations where texte_affirmation like 'Le déficit%'), (select id from public.sources where nom = 'Le Monde'), 'https://www.lemonde.fr/preuve', 'confirme', 'Texte copié') $$);
insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, extrait)
values ((select id from public.affirmations where texte_affirmation like 'Le déficit%'), (select id from public.sources where nom = 'Légifrance'), 'https://www.legifrance.gouv.fr/plf-2026', 'contredit', 'Article liminaire');
update public.affirmations set statut_workflow = 'en_relecture' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%');
select tests.verifier('envoi en relecture avec preuve accepté', (select statut_workflow = 'en_relecture' from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%')));
select tests.doit_echouer('en relecture : texte figé',
  $$ update public.affirmations set texte_affirmation = 'Texte modifié pendant la relecture.' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
select tests.doit_echouer('en relecture : ajout de preuve refusé',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
     values ((select id from public.affirmations where texte_affirmation like 'Le déficit%'), (select id from public.sources where nom = 'INSEE'), 'https://www.insee.fr/x', 'confirme') $$);
select tests.doit_echouer('éditeur : publication refusée',
  $$ update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
select tests.doit_echouer('éditeur : falsifier reviewed_by sans effet',
  $$ do $d$ begin
       update public.affirmations set reviewed_by = '00000000-0000-0000-0000-0000000000b2' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%');
       if (select reviewed_by from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%')) is null then raise exception 'ignoré'; end if;
     end $d$ $$);
reset role;

-- La clé service_role (script, IA) ne peut pas publier.
set role service_role;
select set_config('request.jwt.claims', '', false);
select tests.doit_echouer('service_role : publication refusée',
  $$ update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
reset role;

-- Le relecteur publie : cohérence verdict/preuves d'abord.
select tests.session('00000000-0000-0000-0000-0000000000b2', 'relecteur');
set role authenticated;
select tests.doit_echouer('« vrai » sans preuve qui confirme refusé',
  $$ update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
update public.affirmations set statut_workflow = 'brouillon' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%');
reset role;

select tests.session('00000000-0000-0000-0000-0000000000a1', 'editeur');
set role authenticated;
insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, note)
values ((select id from public.affirmations where texte_affirmation like 'Le déficit%'), (select id from public.sources where nom = 'Cour des comptes'), 'https://www.ccomptes.fr/rapport-2026', 'confirme', 'Rapport sur la situation des finances publiques');
update public.affirmations set statut_workflow = 'en_relecture' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%');
reset role;

select tests.session('00000000-0000-0000-0000-0000000000b2', 'relecteur');
set role authenticated;
select tests.doit_echouer('relecteur : modifier le verdict en publiant refusé',
  $$ update public.affirmations set statut_workflow = 'publie', verdict = 'trompeur' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%');
select tests.verifier('relecteur différent : publication acceptée',
  (select statut_workflow = 'publie' and reviewed_by = '00000000-0000-0000-0000-0000000000b2'
          and reviewed_at is not null and published_at is not null from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%')));
reset role;

-- Un relecteur ne valide pas sa propre affirmation.
select tests.session('00000000-0000-0000-0000-0000000000b2', 'relecteur');
set role authenticated;
insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
values ((select id from public.contenus where url_originale = 'https://www.francetvinfo.fr/chomage-jeunes'), 'Le chômage des 15-24 ans a baissé en un an.', 'faux', 'Les données INSEE montrent une hausse.');
insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
values ((select id from public.affirmations where texte_affirmation like 'Le chômage%'), (select id from public.sources where nom = 'INSEE'), 'https://www.insee.fr/chomage-t2', 'contredit');
update public.affirmations set statut_workflow = 'en_relecture' where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%');
select tests.doit_echouer('auteur relecteur : auto-validation refusée',
  $$ update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%') $$);
reset role;
select tests.session('00000000-0000-0000-0000-0000000000c3', 'relecteur');
set role authenticated;
update public.affirmations set statut_workflow = 'publie' where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%');
select tests.verifier('2e article : publication par un autre relecteur acceptée', (select statut_workflow = 'publie' from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%')));
reset role;

-- ---------------------------------------------------------------------
-- Après publication
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000a1', 'editeur');
set role authenticated;
select tests.doit_echouer('publié : suppression de preuve refusée', $$ delete from public.preuves where affirmation_id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
select tests.doit_echouer('publié : texte figé', $$ update public.affirmations set explication = 'Autre explication' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
select tests.doit_echouer('publié : suppression refusée', $$ delete from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$, true);
select tests.doit_echouer('éditeur : dépublication refusée', $$ update public.affirmations set statut_workflow = 'brouillon' where id = (select id from public.affirmations where texte_affirmation like 'Le déficit%') $$);
-- Brouillon non publié, pour vérifier qu'il reste invisible.
insert into public.affirmations (contenu_id, texte_affirmation) values ((select id from public.contenus where url_originale = 'https://www.lemonde.fr/article-budget'), 'Brouillon qui ne doit pas être visible.');
reset role;

select set_config('request.jwt.claims', '{"role": "anon"}', false);  -- JWT de la clé publique
set role anon;
select tests.verifier('anon : voit les 2 affirmations publiées, pas le brouillon', (select count(*) = 2 from public.affirmations));
select tests.verifier('anon : voit les 3 preuves des affirmations publiées', (select count(*) = 3 from public.preuves));
select tests.verifier('vue : contenu 1 vérifié (1 affirmation publiée)',
  (select nb_affirmations_publiees = 1 and statut_verification = 'verifie' from public.v_feed_verifie where url_originale = 'https://www.lemonde.fr/article-budget'));
select tests.verifier('vue : contenu masqué absent', (select count(*) = 2 from public.v_feed_verifie));
reset role;

-- Correction : le relecteur dépublie, la version augmente, l'affirmation disparaît du public.
select tests.session('00000000-0000-0000-0000-0000000000c3', 'relecteur');
set role authenticated;
update public.affirmations set statut_workflow = 'brouillon' where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%');
reset role;
select tests.verifier('correction : version 2, validation effacée',
  (select version = 2 and reviewed_by is null and published_at is null from public.affirmations where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%')));
select set_config('request.jwt.claims', '{"role": "anon"}', false);  -- JWT de la clé publique
set role anon;
select tests.verifier('correction : invisible pour le public', (select count(*) = 1 from public.affirmations));
select tests.verifier('correction : preuves masquées au public', (select count(*) = 2 from public.preuves));
reset role;

-- Garde-fou indépendant du trigger : contrainte auteur ≠ relecteur.
alter table public.affirmations disable trigger controler_affirmation;
select tests.doit_echouer('contrainte : relecteur = auteur refusé même sans trigger',
  $$ update public.affirmations set statut_workflow = 'publie', reviewed_by = created_by, reviewed_at = now(), published_at = now() where id = (select id from public.affirmations where texte_affirmation like 'Le chômage%') $$);
alter table public.affirmations enable trigger controler_affirmation;

-- ---------------------------------------------------------------------
\o
\set QUIET off
select case when ok then 'OK   ' else 'ÉCHEC' end as resultat, nom from tests.resultats order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echoues from tests.resultats;
do $$ begin
  if exists (select 1 from tests.resultats where not ok) then raise exception 'Des tests ont échoué.'; end if;
end $$;
