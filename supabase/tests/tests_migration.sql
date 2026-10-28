-- Tests de la migration : sélection des articles, appel pg_net, quota par média,
-- relance des analyses, droits d'exécution, et rappels des règles centrales.
\set QUIET on
\o /dev/null
set client_min_messages = warning;

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create table tests.resultats (nom text, ok boolean);
grant insert on tests.resultats to anon, authenticated, service_role;

create function tests.verifier(nom text, ok boolean) returns void language plpgsql as $$
begin
  insert into tests.resultats values (nom, coalesce(ok, false));
end $$;

-- Exécute une requête qui DOIT échouer.
create function tests.doit_echouer(nom text, requete text) returns void language plpgsql as $$
begin
  begin
    execute requete;
  exception when others then
    insert into tests.resultats values (nom, true);
    return;
  end;
  insert into tests.resultats values (nom, false);
end $$;

create function tests.en_tant_que(sub text, anonyme boolean default false) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', sub, 'is_anonymous', anonyme)::text, false)
$$;
grant execute on all functions in schema tests to anon, authenticated, service_role;

-- Utilisateurs : un admin, un éditeur, un visiteur anonyme.
insert into auth.users (id, email, is_anonymous) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@test', false),
  ('00000000-0000-0000-0000-00000000000e', 'editeur@test', false),
  ('00000000-0000-0000-0000-0000000000b0', null, true);
update public.profils set role = 'admin'   where id = '00000000-0000-0000-0000-00000000000a';
update public.profils set role = 'editeur' where id = '00000000-0000-0000-0000-00000000000e';

insert into vault.decrypted_secrets values
  ('url_projet', 'https://projet.supabase.co/'),
  ('cle_interne', 'cle-de-test');

-- ---------------------------------------------------------------------
-- Import RSS (service_role) : statut 'importe', aucun appel à l'IA.
-- ---------------------------------------------------------------------
set role service_role;
insert into public.articles (media_id, url, titre, statut)
select m.id, 'https://exemple.fr/' || m.id || '/' || g, 'Article ' || g, 'importe'
  from public.medias m, generate_series(1, 4) g
 where m.nom in ('Le Monde', 'Le Figaro');
reset role;

select tests.verifier('import RSS : 8 articles importés', (select count(*) = 8 from public.articles where statut = 'importe'));
select tests.verifier('import RSS : aucun appel pg_net', (select count(*) = 0 from net.appels));
select tests.verifier('import RSS : analyse_demandee_le vide', (select bool_and(analyse_demandee_le is null) from public.articles));

-- ---------------------------------------------------------------------
-- Visibilité : le public ne voit pas les articles importés, l'équipe si.
-- ---------------------------------------------------------------------
set role anon;
select tests.verifier('anon : ne voit pas les articles importés', (select count(*) = 0 from public.articles));
reset role;

select tests.en_tant_que('00000000-0000-0000-0000-0000000000b0', true);
set role authenticated;
select tests.verifier('anonyme connecté : ne voit pas les articles importés', (select count(*) = 0 from public.articles));
select tests.doit_echouer('anonyme connecté : ne peut pas lancer une analyse',
  $$ do $d$ begin
       update public.articles set statut = 'en_attente' where id = 1;
       if not found then raise exception 'aucune ligne'; end if;
     end $d$ $$);
reset role;

select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
select tests.verifier('éditeur : voit les articles importés', (select count(*) = 8 from public.articles));

-- ---------------------------------------------------------------------
-- Sélection par l'éditeur : 'importe' -> 'en_attente' déclenche l'appel.
-- ---------------------------------------------------------------------
update public.articles set statut = 'en_attente'
 where id = (select min(a.id) from public.articles a join public.medias m on m.id = a.media_id where m.nom = 'Le Monde');
reset role;

select tests.verifier('sélection : un appel pg_net', (select count(*) = 1 from net.appels));
select tests.verifier('sélection : URL de la fonction analyser-article',
  (select url = 'https://projet.supabase.co/functions/v1/analyser-article' from net.appels order by id desc limit 1));
select tests.verifier('sélection : clé interne transmise',
  (select headers ->> 'x-cle-interne' = 'cle-de-test' from net.appels order by id desc limit 1));
select tests.verifier('sélection : article_id transmis',
  (select (body ->> 'article_id')::bigint = (select id from public.articles where statut = 'en_attente') from net.appels order by id desc limit 1));
select tests.verifier('sélection : date de demande enregistrée',
  (select analyse_demandee_le is not null from public.articles where statut = 'en_attente'));

-- Une autre modification de l'article (titre) ne relance pas l'analyse.
select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
update public.articles set titre = 'Titre corrigé' where statut = 'en_attente';
reset role;
select tests.verifier('modification du titre : pas de nouvel appel', (select count(*) = 1 from net.appels));

-- ---------------------------------------------------------------------
-- Neutralité : même quota d'analyses par média et par jour.
-- ---------------------------------------------------------------------
update public.parametres set valeur = 2 where cle = 'analyses_max_par_media_jour';

select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
-- 2e article du Monde : accepté (quota 2).
update public.articles set statut = 'en_attente'
 where id = (select a.id from public.articles a join public.medias m on m.id = a.media_id
              where m.nom = 'Le Monde' and a.statut = 'importe' order by a.id limit 1);
-- 3e article du Monde : refusé.
select tests.doit_echouer('quota : 3e analyse du même média refusée',
  $$ update public.articles set statut = 'en_attente'
      where id = (select a.id from public.articles a join public.medias m on m.id = a.media_id
                   where m.nom = 'Le Monde' and a.statut = 'importe' order by a.id limit 1) $$);
-- Demande groupée de 3 articles du Figaro : refusée en bloc.
select tests.doit_echouer('quota : demande groupée au-delà du quota refusée',
  $$ update public.articles set statut = 'en_attente'
      where media_id = (select id from public.medias where nom = 'Le Figaro') $$);
-- Demande groupée de 2 articles du Figaro : acceptée.
update public.articles set statut = 'en_attente'
 where id in (select a.id from public.articles a join public.medias m on m.id = a.media_id
               where m.nom = 'Le Figaro' order by a.id limit 2);
reset role;

select tests.verifier('quota : 4 analyses demandées au total', (select count(*) = 4 from public.articles where statut = 'en_attente'));
select tests.verifier('quota : 4 appels pg_net au total', (select count(*) = 4 from net.appels));

-- Ajout manuel d'un article par un éditeur : analysé directement.
update public.parametres set valeur = 5 where cle = 'analyses_max_par_media_jour';
select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
insert into public.articles (media_id, url, titre, ajoute_par)
values ((select id from public.medias where nom = 'franceinfo'), 'https://www.francetvinfo.fr/test.html',
        'Ajout manuel', '00000000-0000-0000-0000-00000000000e');
reset role;
select tests.verifier('ajout manuel : appel pg_net', (select count(*) = 5 from net.appels));

-- ---------------------------------------------------------------------
-- Pas de réanalyse d'un article déjà traité (doublons).
-- ---------------------------------------------------------------------
set role service_role;
update public.articles set statut = 'en_cours' where url = 'https://www.francetvinfo.fr/test.html';
update public.articles set statut = 'traite'   where url = 'https://www.francetvinfo.fr/test.html';
reset role;

select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
select tests.doit_echouer('article traité : réanalyse refusée',
  $$ update public.articles set statut = 'en_attente' where url = 'https://www.francetvinfo.fr/test.html' $$);
reset role;

-- Un article en erreur peut être relancé.
set role service_role;
update public.articles set statut = 'erreur'
 where id = (select min(id) from public.articles where statut = 'en_attente');
reset role;
select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
update public.articles set statut = 'en_attente' where statut = 'erreur';
reset role;
select tests.verifier('article en erreur : relance acceptée', (select count(*) = 6 from net.appels));

-- ---------------------------------------------------------------------
-- Filet de sécurité : relance et déblocage.
-- ---------------------------------------------------------------------
update public.articles set analyse_demandee_le = now() - interval '20 minutes'
 where id = (select min(id) from public.articles where statut = 'en_attente');
insert into public.articles (media_id, url, titre, statut, analyse_demandee_le)
values ((select id from public.medias where nom = 'BFMTV'), 'https://www.bfmtv.com/bloque.html', 'Bloqué', 'en_cours',
        now() - interval '40 minutes');

select tests.verifier('relance : un article relancé', (select public.relancer_analyses() = 1));
select tests.verifier('relance : appel pg_net envoyé', (select count(*) = 7 from net.appels));
select tests.verifier('relance : analyse bloquée passée en erreur',
  (select statut = 'erreur' from public.articles where url = 'https://www.bfmtv.com/bloque.html'));

-- ---------------------------------------------------------------------
-- Vault vide : avertissement, la transaction n'échoue pas.
-- ---------------------------------------------------------------------
delete from vault.decrypted_secrets;
select tests.en_tant_que('00000000-0000-0000-0000-00000000000e');
set role authenticated;
update public.articles set statut = 'en_attente'
 where id = (select min(id) from public.articles where statut = 'importe');
reset role;
select tests.verifier('Vault vide : demande enregistrée sans appel',
  (select count(*) = 7 from net.appels) and (select count(*) = 5 from public.articles where statut = 'en_attente'));

-- ---------------------------------------------------------------------
-- Droits : les fonctions internes ne sont pas appelables via l'API.
-- ---------------------------------------------------------------------
set role anon;
select tests.doit_echouer('anon : appeler_edge_function interdite', $$ select public.appeler_edge_function('chatbot') $$);
select tests.doit_echouer('anon : relancer_analyses interdite', $$ select public.relancer_analyses() $$);
reset role;
select tests.en_tant_que('00000000-0000-0000-0000-00000000000a');
set role authenticated;
select tests.doit_echouer('admin via API : appeler_edge_function interdite', $$ select public.appeler_edge_function('importer-rss') $$);
select tests.doit_echouer('admin via API : relancer_analyses interdite', $$ select public.relancer_analyses() $$);
reset role;

-- ---------------------------------------------------------------------
-- Rappels des règles centrales (écriture de l'IA via service_role).
-- ---------------------------------------------------------------------
set role service_role;
insert into public.organismes (nom, site_url, type, reutilisation) values ('Test', 'https://test.fr', 'statistique', 'ouverte');
insert into public.sources (organisme_id, titre, url, extrait, embedding)
values ((select id from public.organismes where nom = 'Test'), 'Source A', 'https://test.fr/a', 'Extrait A', array[1, 0, 0]::float8[]),
       ((select id from public.organismes where nom = 'Test'), 'Source B', 'https://test.fr/b', 'Extrait B', array[0, 1, 0]::float8[]);
insert into public.affirmations (article_id, citation, verdict, explication)
values ((select id from public.articles where statut = 'traite'), 'Le chômage a baissé de 2 points.', 'faux', 'Explication.');
reset role;

set role service_role;
select tests.doit_echouer('IA : « faux » avec 1 source refusé',
  $$ do $d$ begin
       insert into public.affirmation_sources values ((select max(id) from public.affirmations), (select id from public.sources where url = 'https://test.fr/a'));
       update public.affirmations set statut = 'publie' where id = (select max(id) from public.affirmations);
     end $d$ $$);
insert into public.affirmation_sources
select (select max(id) from public.affirmations), id from public.sources where organisme_id = (select id from public.organismes where nom = 'Test');
update public.affirmations set statut = 'publie' where id = (select max(id) from public.affirmations);
reset role;
select tests.verifier('IA : « faux » avec 2 sources publié', (select statut = 'publie' from public.affirmations order by id desc limit 1));

set role anon;
select tests.verifier('anon : voit la vérification publiée et ses 2 sources',
  (select jsonb_array_length(sources) = 2 from public.affirmations_publiques));
select tests.verifier('recherche vectorielle : source la plus proche en premier',
  (select titre = 'Source B' from public.rechercher_sources(array[0.1, 0.9, 0]::float8[], 2) limit 1));
reset role;

-- ---------------------------------------------------------------------
-- Tâches planifiées enregistrées.
-- ---------------------------------------------------------------------
select tests.verifier('cron : 5 tâches planifiées', (select count(*) = 5 from cron.jobs));
select tests.verifier('cron : import RSS quotidien', exists (select 1 from cron.jobs where nom = 'importer-rss' and commande like '%appeler_edge_function(''importer-rss'')%'));
select tests.verifier('cron : maj-sources hebdomadaire', exists (select 1 from cron.jobs where nom = 'maj-sources' and planning like '% * * 1'));

-- ---------------------------------------------------------------------
\o
\set QUIET off
select case when ok then 'OK   ' else 'ÉCHEC' end as resultat, nom from tests.resultats;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echoues from tests.resultats;
do $$ begin
  if exists (select 1 from tests.resultats where not ok) then raise exception 'Des tests ont échoué.'; end if;
end $$;
