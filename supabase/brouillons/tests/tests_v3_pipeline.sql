-- Tests de la migration v2_05 (pipeline IA) et des RLS manuelles, dans Postgres local.
-- Profils : pipeline (rôle demelo_pipeline), administrateur, compte sans rôle,
-- visiteur anonyme, clé service_role.
\set QUIET on
\o /dev/null
set client_min_messages = warning;

create schema tests;
grant usage on schema tests to anon, authenticated, service_role, demelo_pipeline;
create table tests.resultats (n serial, nom text, ok boolean);
grant insert on tests.resultats to anon, authenticated, service_role, demelo_pipeline;
grant usage on sequence tests.resultats_n_seq to anon, authenticated, service_role, demelo_pipeline;

create function tests.verifier(nom text, ok boolean) returns void language sql as
  $$ insert into tests.resultats (nom, ok) values (nom, coalesce(ok, false)) $$;

-- La requête DOIT échouer (ou ne toucher aucune ligne si zero_ok).
create function tests.doit_echouer(nom text, requete text, zero_ok boolean default false) returns void
language plpgsql as $$
declare n bigint;
begin
  begin
    execute requete;
    get diagnostics n = row_count;
    insert into tests.resultats (nom, ok) values (nom, zero_ok and n = 0);
  exception when others then
    insert into tests.resultats (nom, ok) values (nom, true);
  end;
end $$;

create function tests.session(sub text, role_equipe text default null, anonyme boolean default false) returns void
language sql as $$
  select set_config('request.jwt.claims', json_build_object(
    'sub', sub, 'role', 'authenticated', 'is_anonymous', anonyme,
    'app_metadata', case when role_equipe is null then '{}'::json else json_build_object('role_equipe', role_equipe) end)::text, false)
$$;
create function tests.sans_jwt() returns void language sql as
  $$ select set_config('request.jwt.claims', '', false) $$;
create function tests.aff(debut text) returns bigint language sql stable security definer as
  $$ select id from public.affirmations where texte_affirmation like debut || '%' $$;
create function tests.src(nom text) returns bigint language sql stable security definer as
  $$ select id from public.sources where sources.nom = src.nom $$;
grant execute on all functions in schema tests to anon, authenticated, service_role, demelo_pipeline;

insert into auth.users (id, email, raw_app_meta_data, is_anonymous) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@test',    '{"role_equipe": "admin"}', false),
  ('00000000-0000-0000-0000-0000000000d4', 'visiteur@test', '{}', false),
  ('00000000-0000-0000-0000-0000000000e5', null,            '{}', true);

-- Bloc JSON de recoupement complet, réutilisé.
create function tests.recoupement() returns jsonb language sql immutable as $$
  select '{"periode": "T2 2026", "definition": "BIT", "unite": "%", "population": "15-24 ans",
           "perimetre": "France hors Mayotte", "contradictions": "aucune", "dependances": "aucune"}'::jsonb
$$;

-- ---------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------
select tests.verifier('structure : 4 tables dans public',
  (select array_agg(tablename::text order by tablename) = array['affirmations', 'contenus', 'preuves', 'sources'] from pg_tables where schemaname = 'public'));
select tests.verifier('structure : RLS activée sur les 4 tables', (select bool_and(rowsecurity) from pg_tables where schemaname = 'public'));
select tests.verifier('structure : 4 tables reliées (contenus→sources, affirmations→contenus, preuves→affirmations, preuves→sources)',
  (select count(distinct conrelid::regclass::text || '>' || confrelid::regclass::text) = 4 from pg_constraint
    where contype = 'f' and connamespace = 'public'::regnamespace and confrelid::regclass::text not like 'auth.%' and conrelid <> confrelid));
select tests.verifier('structure : 15 sources avec un périmètre', (select count(*) = 15 and bool_and(cardinality(perimetres) >= 1) from public.sources));
select tests.verifier('structure : plus de statut_workflow ni de relecteur obligatoire',
  not exists (select 1 from pg_attribute where attrelid = 'public.affirmations'::regclass and attname = 'statut_workflow')
  and not exists (select 1 from pg_constraint where conname = 'affirmations_check2'));
select tests.verifier('sécurité : rôle pipeline sans connexion ni contournement de la RLS',
  (select not rolcanlogin and not rolbypassrls and not rolsuper from pg_roles where rolname = 'demelo_pipeline'));
select tests.verifier('sécurité : pipeline sans aucun droit DELETE ni accès à archive_v1',
  not has_table_privilege('demelo_pipeline', 'public.sources', 'delete') and not has_table_privilege('demelo_pipeline', 'public.contenus', 'delete')
  and not has_table_privilege('demelo_pipeline', 'public.affirmations', 'delete') and not has_table_privilege('demelo_pipeline', 'public.preuves', 'delete')
  and not has_schema_privilege('demelo_pipeline', 'archive_v1', 'usage'));

-- Périmètres
select tests.verifier('périmètre : insee.fr, www.insee.fr et api.insee.fr acceptés',
  prive.url_dans_perimetre('https://insee.fr/x', array['insee.fr']) and prive.url_dans_perimetre('https://www.insee.fr/fr/statistiques/1', array['insee.fr'])
  and prive.url_dans_perimetre('https://api.insee.fr/a', array['insee.fr']));
select tests.verifier('périmètre : faux domaine insee.fr.exemple.com refusé', not prive.url_dans_perimetre('https://insee.fr.exemple.com/', array['insee.fr']));
select tests.verifier('périmètre : http (non chiffré) refusé', not prive.url_dans_perimetre('http://www.insee.fr/', array['insee.fr']));
select tests.verifier('périmètre : Eurostat limité à ec.europa.eu/eurostat',
  prive.url_dans_perimetre('https://ec.europa.eu/eurostat/web/main', array['ec.europa.eu/eurostat'])
  and not prive.url_dans_perimetre('https://ec.europa.eu/commission/presscorner', array['ec.europa.eu/eurostat'])
  and not prive.url_dans_perimetre('https://ec.europa.eu/eurostatfaux', array['ec.europa.eu/eurostat']));
select tests.verifier('périmètre : SSMSI limité à Interstats (casse ignorée)',
  prive.url_dans_perimetre('https://www.interieur.gouv.fr/Interstats/Actualites/x', array['interieur.gouv.fr/interstats'])
  and not prive.url_dans_perimetre('https://www.interieur.gouv.fr/Actualites', array['interieur.gouv.fr/interstats']));

-- ---------------------------------------------------------------------
-- Données fictives
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000a1', 'admin');
set role authenticated;
insert into public.contenus (media_nom, titre, url_originale, est_test)
values ('Média fictif de test', '[FICTIF] Article de démonstration', 'https://media.exemple.invalid/article-1', true);
select tests.doit_echouer('fictif : domaine réel refusé',
  $$ insert into public.contenus (media_nom, titre, url_originale, est_test) values ('Média fictif', '[FICTIF] X', 'https://www.lemonde.fr/faux', true) $$);
select tests.doit_echouer('fictif : titre non marqué [FICTIF] refusé',
  $$ insert into public.contenus (media_nom, titre, url_originale, est_test) values ('Média fictif', 'Article anodin', 'https://a.invalid/1', true) $$);
select tests.doit_echouer('fictif : attribution à une institution réelle refusée',
  $$ insert into public.contenus (source_id, media_nom, titre, url_originale, est_test)
     values (tests.src('INSEE'), 'Média fictif', '[FICTIF] X', 'https://a.invalid/2', true) $$);
select tests.doit_echouer('réel : domaine .invalid refusé',
  $$ insert into public.contenus (media_nom, titre, url_originale) values ('Le Monde', 'Vrai titre', 'https://a.invalid/3') $$);
reset role;

-- ---------------------------------------------------------------------
-- Rôle pipeline : moindre privilège
-- ---------------------------------------------------------------------
select tests.sans_jwt();
set role demelo_pipeline;
insert into public.contenus (media_nom, titre, url_originale, identifiant_externe, theme)
values ('Le Monde', 'Chômage des jeunes : les chiffres du trimestre', 'https://www.lemonde.fr/economie/article-1', 'guid-1', 'economie'),
       ('franceinfo', 'Budget 2027 : ce que prévoit le projet de loi', 'https://www.francetvinfo.fr/politique/article-2', 'guid-2', 'economie');
select tests.verifier('pipeline : lit les 15 sources', (select count(*) = 15 from public.sources));
select tests.verifier('pipeline : ne voit pas les données fictives', (select count(*) = 2 from public.contenus));
select tests.doit_echouer('pipeline : ne peut pas créer de donnée fictive',
  $$ insert into public.contenus (media_nom, titre, url_originale, est_test) values ('Média fictif', '[FICTIF] X', 'https://b.invalid/1', true) $$);
select tests.doit_echouer('pipeline : ne peut pas modifier le titre d''un article',
  $$ update public.contenus set titre = 'Titre réécrit' where identifiant_externe = 'guid-1' $$);
select tests.doit_echouer('pipeline : ne peut rien supprimer', $$ delete from public.contenus where identifiant_externe = 'guid-1' $$);
select tests.doit_echouer('pipeline : pas d''accès à l''archive v1', $$ select count(*) from archive_v1.organismes $$);
select tests.doit_echouer('pipeline : pas d''accès aux comptes', $$ select count(*) from auth.users $$);
update public.contenus set statut_traitement = 'en_cours' where identifiant_externe = 'guid-1';
select tests.verifier('pipeline : met à jour le suivi de traitement', (select statut_traitement = 'en_cours' from public.contenus where identifiant_externe = 'guid-1'));
reset role;

select tests.session('00000000-0000-0000-0000-0000000000a1', 'admin');
set role authenticated;
select tests.doit_echouer('affirmation sur un contenu fictif refusée (même admin)',
  $$ insert into public.affirmations (contenu_id, texte_affirmation)
     values ((select id from public.contenus where est_test), 'Affirmation sur un faux article.') $$);
reset role;

-- ---------------------------------------------------------------------
-- Analyse « vrai » par le pipeline
-- ---------------------------------------------------------------------
select tests.sans_jwt();
set role demelo_pipeline;
insert into public.affirmations (contenu_id, texte_affirmation, contexte, motif_selection, nature_enonce, citation_verifiee)
values ((select id from public.contenus where identifiant_externe = 'guid-1'),
        'Le chômage des 15-24 ans atteint 18 % au deuxième trimestre.', 'Chiffre cité en introduction.', 'Chiffre central, vérifiable', 'factuel', true);
select tests.verifier('pipeline : affirmation créée sans auteur humain',
  (select created_by is null and statut_analyse = 'non_traite' from public.affirmations where id = tests.aff('Le chômage')));
select tests.doit_echouer('pipeline : création directement publiée refusée',
  $$ insert into public.affirmations (contenu_id, texte_affirmation, statut_analyse)
     values ((select id from public.contenus where identifiant_externe = 'guid-1'), 'Publication forcée du pipeline.', 'analyse_disponible') $$);
select tests.doit_echouer('preuve avant le début de l''analyse refusée',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet)
     values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/a', 'confirme', 'inaccessible', 'test') $$);
update public.affirmations set statut_analyse = 'en_cours' where id = tests.aff('Le chômage');

-- Échecs enregistrés
insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet, http_statut)
values (tests.aff('Le chômage'), tests.src('DARES'), 'https://dares.travail-emploi.gouv.fr/introuvable', 'confirme', 'inaccessible', 'HTTP 404', 404);
select tests.doit_echouer('preuve en échec sans motif refusée',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve)
     values (tests.aff('Le chômage'), tests.src('DARES'), 'https://dares.travail-emploi.gouv.fr/x', 'confirme', 'rejetee') $$);

-- Preuves « vérifiées » invalides
select tests.doit_echouer('preuve vérifiée hors périmètre de l''organisme refusée',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
       date_document, empreinte_sha256, passage_verifie, passage_empreinte, nature, justification_nature)
     values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.lemonde.fr/insee', 'https://www.lemonde.fr/insee', 200, 'confirme', 'verifiee',
       'Faux', '2026-08-01', repeat('a', 64), true, repeat('b', 64), 'primaire', 'x') $$);
select tests.doit_echouer('preuve vérifiée sans passage retrouvé refusée',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
       date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
     values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/c', 'https://www.insee.fr/c', 200, 'confirme', 'verifiee',
       'Titre', '2026-08-01', repeat('a', 64), false, 'Extrait', 'primaire', 'x') $$);
select tests.doit_echouer('preuve vérifiée en HTTP 404 refusée',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
       date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
     values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/d', 'https://www.insee.fr/d', 404, 'confirme', 'verifiee',
       'Titre', '2026-08-01', repeat('a', 64), true, 'Extrait', 'primaire', 'x') $$);
select tests.doit_echouer('extrait d''AFP Factuel (lien seulement) refusé',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
       date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
     values (tests.aff('Le chômage'), tests.src('AFP Factuel'), 'https://factuel.afp.com/x', 'https://factuel.afp.com/x', 200, 'confirme', 'verifiee',
       'Titre', '2026-08-01', repeat('a', 64), true, 'Texte copié', 'secondaire', 'x') $$);

-- Preuve secondaire seule : publication « vrai » refusée
insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
  date_document, empreinte_sha256, passage_verifie, passage_empreinte, nature, justification_nature)
values (tests.aff('Le chômage'), tests.src('AFP Factuel'), 'https://factuel.afp.com/chomage', 'https://factuel.afp.com/chomage', 200, 'confirme', 'verifiee',
  'Le chômage des jeunes', '2026-08-02', repeat('c', 64), true, repeat('d', 64), 'secondaire', 'Reprend les chiffres INSEE');
select tests.doit_echouer('« vrai » avec une seule preuve secondaire refusé',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai', explication = 'E', limites = 'L',
       modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), recoupement = tests.recoupement()
     where id = tests.aff('Le chômage') $$);

insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
  date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/fr/statistiques/chomage', 'https://www.insee.fr/fr/statistiques/chomage',
  200, 'confirme', 'verifiee', 'Chômage au sens du BIT — T2 2026', '2026-08-14', repeat('e', 64), true,
  'Le taux de chômage des 15-24 ans s''établit à 18,0 %.', 'primaire', 'Producteur de la statistique');
select tests.doit_echouer('publication sans recoupement complet refusée',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai', explication = 'E', limites = 'L',
       modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), recoupement = '{"periode": "T2"}'
     where id = tests.aff('Le chômage') $$);
select tests.doit_echouer('publication sans limites refusée',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai', explication = 'E',
       modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), recoupement = tests.recoupement()
     where id = tests.aff('Le chômage') $$);
update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai',
  explication = 'Le chiffre correspond à la publication INSEE du trimestre.', limites = 'Chiffre provisoire, révisable.',
  modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), id_execution = 'run-1', recoupement = tests.recoupement()
where id = tests.aff('Le chômage');
select tests.verifier('« vrai » publié avec preuve primaire vérifiée',
  (select statut_analyse = 'analyse_disponible' and published_at is not null and jsonb_array_length(historique) = 2
     from public.affirmations where id = tests.aff('Le chômage')));

select tests.doit_echouer('analyse publiée : explication figée', $$ update public.affirmations set explication = 'Réécrite' where id = tests.aff('Le chômage') $$);
select tests.doit_echouer('analyse publiée : ajout de preuve refusé',
  $$ insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet)
     values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/z', 'confirme', 'rejetee', 'x') $$);
select tests.doit_echouer('pipeline : retrait refusé (réservé aux admins)',
  $$ update public.affirmations set statut_analyse = 'retire', revue_motif = 'x' where id = tests.aff('Le chômage') $$);
reset role;

-- ---------------------------------------------------------------------
-- Règles de verdict, abstention, énoncés non factuels
-- ---------------------------------------------------------------------
select tests.sans_jwt();
set role demelo_pipeline;
insert into public.affirmations (contenu_id, texte_affirmation, nature_enonce, citation_verifiee) values
  ((select id from public.contenus where identifiant_externe = 'guid-2'), 'Le déficit public atteindra 5,4 % du PIB en 2026.', 'factuel', true),
  ((select id from public.contenus where identifiant_externe = 'guid-2'), 'Ce budget est le plus injuste de la décennie.', 'opinion', true),
  ((select id from public.contenus where identifiant_externe = 'guid-2'), 'Le ministre a été condamné pour fraude.', 'factuel', true);
update public.affirmations set statut_analyse = 'en_cours' where contenu_id = (select id from public.contenus where identifiant_externe = 'guid-2');

insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
  version_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
values (tests.aff('Le déficit'), tests.src('Légifrance'), 'https://www.legifrance.gouv.fr/plf-2026', 'https://www.legifrance.gouv.fr/plf-2026',
  200, 'confirme', 'verifiee', 'Loi de finances 2026', 'version du 30/12/2025', repeat('f', 64), true, 'Article liminaire', 'primaire', 'Texte de loi'),
       (tests.aff('Le déficit'), tests.src('Cour des comptes'), 'https://www.ccomptes.fr/rapport', 'https://www.ccomptes.fr/rapport',
  200, 'contredit', 'verifiee', 'Situation des finances publiques', '2026-07-01', repeat('1', 64), true, 'Le déficit atteindrait 5,8 %.', 'primaire', 'Évaluation indépendante');
select tests.doit_echouer('« vrai » malgré une preuve qui contredit refusé',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai', explication = 'E', limites = 'L',
       modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), recoupement = tests.recoupement()
     where id = tests.aff('Le déficit') $$);
select tests.doit_echouer('abstention avec un verdict refusée',
  $$ update public.affirmations set statut_analyse = 'verification_insuffisante', verdict = 'faux', motif_abstention = 'M', limites = 'L',
       modele_ia = 'claude-opus-5-5', analyse_le = now() where id = tests.aff('Le déficit') $$);
update public.affirmations set statut_analyse = 'verification_insuffisante', motif_abstention = 'Prévision et évaluation divergentes, périodes non comparables.',
  limites = 'Chiffres prévisionnels.', modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now()
where id = tests.aff('Le déficit');
select tests.verifier('abstention enregistrée sans verdict', (select statut_analyse = 'verification_insuffisante' and verdict is null from public.affirmations where id = tests.aff('Le déficit')));

select tests.doit_echouer('opinion : verdict « vrai » refusé',
  $$ update public.affirmations set verdict = 'vrai' where id = tests.aff('Ce budget') $$);
update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'non_verifiable',
  explication = 'Il s''agit d''un jugement de valeur.', limites = 'Aucune vérification factuelle possible.',
  modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now()
where id = tests.aff('Ce budget');
select tests.verifier('opinion : publiée en « non_verifiable »', (select statut_analyse = 'analyse_disponible' from public.affirmations where id = tests.aff('Ce budget')));

-- Cas sensible
update public.affirmations set sensible = true, motif_sensibilite = 'Accusation pénale visant une personne nommée'
where id = tests.aff('Le ministre');
insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
  date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
values (tests.aff('Le ministre'), tests.src('HATVP'), 'https://www.hatvp.fr/fiche', 'https://www.hatvp.fr/fiche', 200, 'contredit', 'verifiee',
  'Fiche', '2026-05-01', repeat('2', 64), true, 'Aucune mention de condamnation.', 'primaire', 'Registre officiel');
select tests.doit_echouer('sensible : publication directe par le pipeline refusée',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'faux', explication = 'E', limites = 'L',
       modele_ia = 'claude-opus-5-5', version_prompt = 'v1', analyse_le = now(), recoupement = tests.recoupement()
     where id = tests.aff('Le ministre') $$);
update public.affirmations set statut_analyse = 'revue_requise', verdict = 'faux', explication = 'Aucune condamnation trouvée.',
  limites = 'Absence de mention ne prouve pas l''absence de procédure.', modele_ia = 'claude-opus-5-5', version_prompt = 'v1',
  analyse_le = now(), recoupement = tests.recoupement()
where id = tests.aff('Le ministre');
reset role;

-- ---------------------------------------------------------------------
-- Administrateur : revue exceptionnelle, retrait, correction
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000a1', 'admin');
set role authenticated;
select tests.doit_echouer('revue : décision sans motif refusée',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible' where id = tests.aff('Le ministre') $$);
select tests.doit_echouer('revue : modifier le verdict pendant la revue refusé',
  $$ update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'trompeur', revue_motif = 'm' where id = tests.aff('Le ministre') $$);
select tests.doit_echouer('revue : l''admin ne réécrit pas l''analyse en la tranchant',
  $$ update public.affirmations set statut_analyse = 'verification_insuffisante', revue_motif = 'Trop grave.',
       motif_abstention = 'Réécrit par l''admin.' where id = tests.aff('Le ministre') $$);
update public.affirmations set statut_analyse = 'analyse_disponible', revue_motif = 'Preuve officielle suffisante, relue par l''équipe.'
where id = tests.aff('Le ministre');
select tests.verifier('revue : cas sensible publié par un admin, relecteur tracé',
  (select statut_analyse = 'analyse_disponible' and reviewed_by = '00000000-0000-0000-0000-0000000000a1' from public.affirmations where id = tests.aff('Le ministre')));
select tests.doit_echouer('retrait sans motif refusé', $$ update public.affirmations set statut_analyse = 'retire' where id = tests.aff('Ce budget') $$);
update public.affirmations set statut_analyse = 'retire', revue_motif = 'Hors sujet pour la démonstration.' where id = tests.aff('Ce budget');
update public.affirmations set statut_analyse = 'non_traite', revue_motif = 'Nouvelle publication INSEE : réanalyser.' where id = tests.aff('Le chômage');
select tests.verifier('correction : version 2, historique conservé',
  (select version = 2 and published_at is null and jsonb_array_length(historique) = 3 from public.affirmations where id = tests.aff('Le chômage')));
reset role;

select tests.sans_jwt();
set role demelo_pipeline;
update public.affirmations set statut_analyse = 'en_cours' where id = tests.aff('Le chômage');
insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve, titre_document,
  date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
values (tests.aff('Le chômage'), tests.src('INSEE'), 'https://www.insee.fr/fr/statistiques/chomage', 'https://www.insee.fr/fr/statistiques/chomage',
  200, 'confirme', 'verifiee', 'Chômage au sens du BIT — T2 2026 (révisé)', '2026-09-14', repeat('9', 64), true,
  'Le taux de chômage des 15-24 ans s''établit à 18,1 %.', 'primaire', 'Producteur de la statistique');
select tests.verifier('correction : même URL réutilisable pour la version 2, anciennes preuves conservées',
  (select count(*) filter (where version_analyse = 1) = 3 and count(*) filter (where version_analyse = 2) = 1
     from public.preuves where affirmation_id = tests.aff('Le chômage')));
update public.affirmations set statut_analyse = 'analyse_disponible', limites = 'Chiffre révisé.', analyse_le = now()
where id = tests.aff('Le chômage');
reset role;

-- ---------------------------------------------------------------------
-- Autres identités : aucune écriture
-- ---------------------------------------------------------------------
select tests.session('00000000-0000-0000-0000-0000000000d4');
set role authenticated;
select tests.doit_echouer('compte sans rôle : aucune modification', $$ update public.affirmations set explication = 'x' where id = tests.aff('Le déficit') $$, true);
select tests.doit_echouer('compte sans rôle : aucun ajout', $$ insert into public.affirmations (contenu_id, texte_affirmation) values (1, 'Tentative sans droit.') $$);
reset role;
select tests.session('00000000-0000-0000-0000-0000000000e5', 'admin', true);
set role authenticated;
select tests.doit_echouer('anonyme avec rôle admin forgé : refusé', $$ update public.affirmations set statut_analyse = 'retire', revue_motif = 'x' where id = tests.aff('Le déficit') $$, true);
reset role;
set role service_role;
select tests.sans_jwt();
select tests.doit_echouer('clé service_role : aucune modification d''analyse (contourne la RLS, pas le trigger)',
  $$ update public.affirmations set statut_analyse = 'retire', revue_motif = 'x' where id = tests.aff('Le déficit') $$);
reset role;

-- ---------------------------------------------------------------------
-- Visibilité publique (policies du fichier manuel appliquées)
-- ---------------------------------------------------------------------
select set_config('request.jwt.claims', '{"role": "anon"}', false);
set role anon;
select tests.verifier('public : les 2 articles réels, pas le fictif', (select count(*) = 2 from public.contenus));
select tests.verifier('public : analyses publiées et abstention visibles, pas le retrait',
  (select array_agg(left(texte_affirmation, 6) order by texte_affirmation) = array['Le chô', 'Le déf', 'Le min'] from public.affirmations));
select tests.verifier('public : seules les preuves vérifiées de la version publiée',
  (select count(*) = 1 from public.preuves where affirmation_id = tests.aff('Le chômage'))
  and not exists (select 1 from public.preuves where statut_preuve <> 'verifiee'));
select tests.verifier('public : fiche avec mention IA, modèle et preuves',
  (select mention = 'Analyse produite par IA' and modele_ia = 'claude-opus-5-5' and jsonb_array_length(preuves) = 1
     from public.v_analyses_publiques where id = tests.aff('Le chômage')));
select tests.verifier('public : flux sans donnée fictive', (select count(*) = 2 and bool_and(domaine_origine not like '%.invalid') from public.v_feed_verifie));
select tests.doit_echouer('public : aucune écriture', $$ update public.affirmations set statut_analyse = 'retire' $$);
reset role;

select tests.session('00000000-0000-0000-0000-0000000000a1', 'admin');
set role authenticated;
select tests.verifier('admin : voit tout, dont le fictif et le retrait',
  (select count(*) = 3 from public.contenus) and (select count(*) = 4 from public.affirmations));
reset role;

-- ---------------------------------------------------------------------
\o
\set QUIET off
select case when ok then 'OK   ' else 'ÉCHEC' end as resultat, nom from tests.resultats order by n;
select count(*) filter (where ok) as reussis, count(*) filter (where not ok) as echoues from tests.resultats;
do $$ begin
  if exists (select 1 from tests.resultats where not ok) then raise exception 'Des tests ont échoué.'; end if;
end $$;
