-- =====================================================================
--  TESTS RLS RÉELS — à exécuter dans le SQL Editor de Supabase
-- =====================================================================
--  Rejouable à volonté, et sans risque :
--  * les données de test sont créées puis ANNULÉES à la fin : rien ne reste ;
--  * chaque essai s'exécute avec le vrai rôle Postgres (anon ou authenticated)
--    et un JWT simulé, donc avec les vraies policies du projet ;
--  * seuls des objets temporaires (pg_temp), propres à la session, sont créés.
--
--  Prérequis : 2 comptes de test créés dans Authentication > Users
--  (« Auto Confirm User » coché) — voir docs/tutoriel-rls.md :
--    admin@demelo.test     role_equipe = admin
--    visiteur@demelo.test  aucun rôle (compte connecté sans privilège)
--
--  Lecture du résultat (dernier tableau affiché) :
--    ✅ conforme   ❌ NON conforme   ⏳ table pas encore ouverte (GRANT pas encore fait)
--  Avant la configuration, tout est ⏳ ou ✅ (rien n'est accessible). À la fin : 100 % ✅.
-- =====================================================================

create temp table if not exists resultats_rls (
  n serial, code text, test text, attendu text, obtenu text, statut text
);
truncate resultats_rls;

-- Exécute une requête avec l'identité demandée et renvoie le résultat.
--   qui     : 'anon' | 'service_role' | e-mail d'un compte de test
--   attendu : '=N' (réussite, N lignes) | 'bloque' (erreur ou 0 ligne) | 'refus_droit' (pas de GRANT)
create or replace function pg_temp.essai(code text, test text, qui text, attendu text, requete text,
                                         anonyme boolean default false)
returns jsonb
language plpgsql
as $$
declare
  v_user   record;
  v_n      bigint;
  v_obtenu text;
  v_erreur text;
  v_statut text;
begin
  if qui = 'anon' then
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  elsif qui = 'service_role' then
    perform set_config('request.jwt.claims', '{"role": "service_role"}', true);
  else
    select u.id, u.raw_app_meta_data into v_user from auth.users u where u.email = qui;
    if v_user.id is null then
      raise exception 'Compte de test introuvable : %', qui;
    end if;
    perform set_config('request.jwt.claims', json_build_object(
      'sub', v_user.id, 'role', 'authenticated', 'email', qui, 'is_anonymous', anonyme,
      'app_metadata', v_user.raw_app_meta_data)::text, true);
  end if;

  begin
    execute format('set local role %I',
                   case when qui in ('anon', 'service_role') then qui else 'authenticated' end);
    if requete ~* '^\s*select' then
      execute format('select count(*) from (%s) t', requete) into v_n;
    else
      execute requete;
      get diagnostics v_n = row_count;
    end if;
    v_obtenu := v_n || ' ligne(s)';
    raise exception 'annuler_essai';          -- annule l'essai, garde le résultat
  exception when others then
    if sqlerrm <> 'annuler_essai' then
      v_erreur := sqlerrm;
      v_obtenu := 'refus : ' || sqlerrm;
    end if;
  end;

  v_statut := case
    when v_erreur like 'permission denied for%' and attendu = 'refus_droit' then '✅'
    when v_erreur like 'permission denied for%' then '⏳'
    when attendu = 'refus_droit' then '❌'
    when attendu = 'bloque' then case when v_erreur is not null or v_n = 0 then '✅' else '❌' end
    when v_erreur is not null then '❌'
    when v_n = substr(attendu, 2)::bigint then '✅'
    else '❌'
  end;

  return jsonb_build_object('code', code, 'test', test, 'attendu', attendu, 'obtenu', v_obtenu, 'statut', v_statut);
end;
$$;

-- Simule l'administrateur pour créer les données de test (les triggers s'appliquent).
create or replace function pg_temp.comme_admin(p_admin uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_admin, 'role', 'authenticated',
    'app_metadata', json_build_object('role_equipe', 'admin'))::text, true)
$$;

create or replace function pg_temp.preuve_ok(p_aff bigint, p_src bigint, p_url text, p_relation text, p_nature text)
returns bigint language sql as $$
  insert into public.preuves (affirmation_id, source_id, url_preuve, url_finale, http_statut, type_relation, statut_preuve,
    titre_document, date_document, empreinte_sha256, passage_verifie, extrait, nature, justification_nature)
  values (p_aff, p_src, p_url, p_url, 200, p_relation::public.type_relation_preuve, 'verifiee',
    '[TEST] Document', current_date, repeat('a', 64), true, '[TEST] passage', p_nature::public.nature_preuve, '[TEST]')
  returning id
$$;

create or replace function pg_temp.recoupement() returns jsonb language sql as $$
  select '{"periode": "t", "definition": "t", "unite": "t", "population": "t", "perimetre": "t",
           "contradictions": "t", "dependances": "t"}'::jsonb
$$;

do $$
declare
  adm uuid := (select id from auth.users where email = 'admin@demelo.test');
  vis uuid := (select id from auth.users where email = 'visiteur@demelo.test');
  s_insee bigint := (select id from public.sources where nom = 'INSEE');
  s_afp   bigint := (select id from public.sources where nom = 'AFP Factuel');
  s_inactive bigint; c_visible bigint; c_masque bigint; c_fictif bigint;
  a_publiee bigint; a_abst bigint; a_cours bigint; a_revue bigint; a_retiree bigint; a_nt bigint; a_masque bigint;
  p_ok bigint; p_echec bigint; p_cours bigint;
  r jsonb := '[]';
begin
  if adm is null or vis is null then
    raise exception 'Créer d''abord les comptes admin@demelo.test et visiteur@demelo.test.';
  end if;

  begin
    -- -----------------------------------------------------------------
    -- Données de test (annulées à la fin). Domaines réservés : .example / .invalid
    -- -----------------------------------------------------------------
    perform pg_temp.comme_admin(adm);
    insert into public.sources (nom, type_source, url_base, active, perimetres)
    values ('[TEST] source inactive', 'statistique', 'https://demelo-test.example', false, array['demelo-test.example'])
    returning id into s_inactive;
    insert into public.contenus (media_nom, titre, url_originale)
    values ('Média de test', '[TEST] article visible', 'https://www.demelo-test.example/visible') returning id into c_visible;
    insert into public.contenus (media_nom, titre, url_originale, visible_public)
    values ('Média de test', '[TEST] article masqué', 'https://www.demelo-test.example/masque', false) returning id into c_masque;
    insert into public.contenus (media_nom, titre, url_originale, est_test)
    values ('Média fictif de test', '[FICTIF] article', 'https://demelo-test.invalid/fictif', true) returning id into c_fictif;

    -- Analyse publiée « vrai », avec une preuve vérifiée et un échec tracé
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee)
    values (c_visible, '[TEST] Affirmation publiée.', true) returning id into a_publiee;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_publiee;
    p_ok := pg_temp.preuve_ok(a_publiee, s_insee, 'https://www.insee.fr/fr/demelo-test-1', 'confirme', 'primaire');
    insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet)
    values (a_publiee, s_insee, 'https://www.insee.fr/fr/demelo-test-404', 'confirme', 'inaccessible', '[TEST] HTTP 404')
    returning id into p_echec;
    update public.affirmations set statut_analyse = 'analyse_disponible', verdict = 'vrai', explication = '[TEST]', limites = '[TEST]',
      modele_ia = 'claude-opus-5-5', version_prompt = 'test', analyse_le = now(), recoupement = pg_temp.recoupement(),
      revue_motif = '[TEST] analyse manuelle'
    where id = a_publiee;

    -- Abstention
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee)
    values (c_visible, '[TEST] Affirmation en abstention.', true) returning id into a_abst;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_abst;
    update public.affirmations set statut_analyse = 'verification_insuffisante', motif_abstention = '[TEST]', limites = '[TEST]',
      modele_ia = 'claude-opus-5-5', analyse_le = now(), revue_motif = '[TEST]' where id = a_abst;

    -- En cours, avec une preuve secondaire seulement
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee)
    values (c_visible, '[TEST] Affirmation en cours.', true) returning id into a_cours;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_cours;
    p_cours := pg_temp.preuve_ok(a_cours, s_insee, 'https://www.insee.fr/fr/demelo-test-2', 'confirme', 'secondaire');

    -- Revue requise (sensible)
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee, sensible, motif_sensibilite)
    values (c_visible, '[TEST] Affirmation sensible.', true, true, '[TEST] accusation') returning id into a_revue;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_revue;
    perform pg_temp.preuve_ok(a_revue, s_insee, 'https://www.insee.fr/fr/demelo-test-3', 'contredit', 'primaire');
    update public.affirmations set statut_analyse = 'revue_requise', verdict = 'faux', explication = '[TEST]', limites = '[TEST]',
      modele_ia = 'claude-opus-5-5', version_prompt = 'test', analyse_le = now(), recoupement = pg_temp.recoupement(),
      revue_motif = '[TEST]' where id = a_revue;

    -- Retirée, non traitée, publiée sur un article masqué
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee)
    values (c_visible, '[TEST] Affirmation retirée.', true) returning id into a_retiree;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_retiree;
    update public.affirmations set statut_analyse = 'verification_insuffisante', motif_abstention = '[TEST]', limites = '[TEST]',
      modele_ia = 'claude-opus-5-5', analyse_le = now(), revue_motif = '[TEST]' where id = a_retiree;
    update public.affirmations set statut_analyse = 'retire', revue_motif = '[TEST] retrait' where id = a_retiree;
    insert into public.affirmations (contenu_id, texte_affirmation)
    values (c_visible, '[TEST] Affirmation non traitée.') returning id into a_nt;
    insert into public.affirmations (contenu_id, texte_affirmation, citation_verifiee)
    values (c_masque, '[TEST] Analyse d''un article masqué.', true) returning id into a_masque;
    update public.affirmations set statut_analyse = 'en_cours' where id = a_masque;
    update public.affirmations set statut_analyse = 'verification_insuffisante', motif_abstention = '[TEST]', limites = '[TEST]',
      modele_ia = 'claude-opus-5-5', analyse_le = now(), revue_motif = '[TEST]' where id = a_masque;

    -- -----------------------------------------------------------------
    -- Table sources (P1 à P3, G1)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P1', 'anon voit un organisme actif', 'anon', '=1', format('select 1 from public.sources where id = %s', s_insee));
    r := r || pg_temp.essai('P1', 'anon ne voit pas un organisme inactif', 'anon', '=0', format('select 1 from public.sources where id = %s', s_inactive));
    r := r || pg_temp.essai('P1', 'admin voit l''organisme inactif', 'admin@demelo.test', '=1', format('select 1 from public.sources where id = %s', s_inactive));
    r := r || pg_temp.essai('P2', 'admin ajoute un organisme', 'admin@demelo.test', '=1',
      $q$ insert into public.sources (nom, type_source, url_base, perimetres) values ('[TEST] nouvelle', 'statistique', 'https://demelo-test.example', array['demelo-test.example']) $q$);
    r := r || pg_temp.essai('P2', 'compte sans rôle : ajout bloqué', 'visiteur@demelo.test', 'bloque',
      $q$ insert into public.sources (nom, type_source, url_base, perimetres) values ('[TEST] pirate', 'statistique', 'https://demelo-test.example', array['demelo-test.example']) $q$);
    r := r || pg_temp.essai('P3', 'admin modifie un organisme', 'admin@demelo.test', '=1',
      format('update public.sources set licence_info = licence_info where id = %s', s_inactive));
    r := r || pg_temp.essai('P3', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.sources set licence_info = %L where id = %s', 'piraté', s_insee));
    r := r || pg_temp.essai('G1', 'anon : écriture interdite (pas de GRANT)', 'anon', 'refus_droit',
      $q$ insert into public.sources (nom, type_source, url_base, perimetres) values ('[TEST] anon', 'statistique', 'https://demelo-test.example', array['demelo-test.example']) $q$);
    r := r || pg_temp.essai('G1', 'admin : suppression interdite (pas de GRANT)', 'admin@demelo.test', 'refus_droit',
      format('delete from public.sources where id = %s', s_inactive));

    -- -----------------------------------------------------------------
    -- Table contenus (P4 à P6, G2)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P4', 'anon voit l''article réel visible', 'anon', '=1', format('select 1 from public.contenus where id = %s', c_visible));
    r := r || pg_temp.essai('P4', 'anon ne voit ni l''article masqué ni le fictif', 'anon', '=0',
      format('select 1 from public.contenus where id in (%s, %s)', c_masque, c_fictif));
    r := r || pg_temp.essai('P4', 'compte sans rôle ne voit pas le fictif', 'visiteur@demelo.test', '=0',
      format('select 1 from public.contenus where id = %s', c_fictif));
    r := r || pg_temp.essai('P4', 'admin voit le masqué et le fictif', 'admin@demelo.test', '=2',
      format('select 1 from public.contenus where id in (%s, %s)', c_masque, c_fictif));
    r := r || pg_temp.essai('P5', 'admin ajoute une donnée fictive', 'admin@demelo.test', '=1',
      $q$ insert into public.contenus (media_nom, titre, url_originale, est_test) values ('Média fictif', '[FICTIF] ajout', 'https://demelo-test.invalid/ajout', true) $q$);
    r := r || pg_temp.essai('P5', 'compte sans rôle : ajout bloqué', 'visiteur@demelo.test', 'bloque',
      $q$ insert into public.contenus (media_nom, titre, url_originale) values ('Pirate', '[TEST] pirate', 'https://www.demelo-test.example/pirate') $q$);
    r := r || pg_temp.essai('P6', 'admin modifie un article', 'admin@demelo.test', '=1',
      format('update public.contenus set theme = %L where id = %s', 'institutions', c_visible));
    r := r || pg_temp.essai('P6', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.contenus set titre = %L where id = %s', '[TEST] piraté', c_visible));
    r := r || pg_temp.essai('G2', 'anon : modification interdite (pas de GRANT)', 'anon', 'refus_droit',
      format('update public.contenus set titre = %L where id = %s', '[TEST] anon', c_visible));

    -- -----------------------------------------------------------------
    -- Table affirmations (P7 à P9, G3) — rien d'interne ne doit fuiter
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P7', 'anon voit l''analyse publiée et l''abstention', 'anon', '=2',
      format('select 1 from public.affirmations where id in (%s, %s)', a_publiee, a_abst));
    r := r || pg_temp.essai('P7', 'anon ne voit ni en cours, ni revue, ni retrait, ni non traité', 'anon', '=0',
      format('select 1 from public.affirmations where id in (%s, %s, %s, %s)', a_cours, a_revue, a_retiree, a_nt));
    r := r || pg_temp.essai('P7', 'anon ne voit pas l''analyse d''un article masqué', 'anon', '=0',
      format('select 1 from public.affirmations where id = %s', a_masque));
    r := r || pg_temp.essai('P7', 'compte sans rôle ne voit rien d''interne', 'visiteur@demelo.test', '=0',
      format('select 1 from public.affirmations where id in (%s, %s)', a_cours, a_revue));
    r := r || pg_temp.essai('P7', 'admin voit tout', 'admin@demelo.test', '=7',
      format('select 1 from public.affirmations where id in (%s, %s, %s, %s, %s, %s, %s)', a_publiee, a_abst, a_cours, a_revue, a_retiree, a_nt, a_masque));
    r := r || pg_temp.essai('P8', 'admin crée une affirmation', 'admin@demelo.test', '=1',
      format('insert into public.affirmations (contenu_id, texte_affirmation) values (%s, %L)', c_visible, '[TEST] Ajout admin.'));
    r := r || pg_temp.essai('P8', 'compte sans rôle : création bloquée', 'visiteur@demelo.test', 'bloque',
      format('insert into public.affirmations (contenu_id, texte_affirmation) values (%s, %L)', c_visible, '[TEST] Pirate.'));
    r := r || pg_temp.essai('P9', 'admin retire une analyse publiée, avec motif', 'admin@demelo.test', '=1',
      format('update public.affirmations set statut_analyse = %L, revue_motif = %L where id = %s', 'retire', '[TEST] retrait', a_publiee));
    r := r || pg_temp.essai('P9', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.affirmations set statut_analyse = %L, revue_motif = %L where id = %s', 'retire', 'x', a_publiee));
    r := r || pg_temp.essai('G3', 'anon : création interdite (pas de GRANT)', 'anon', 'refus_droit',
      format('insert into public.affirmations (contenu_id, texte_affirmation) values (%s, %L)', c_visible, '[TEST] anon'));
    r := r || pg_temp.essai('G3', 'admin : suppression interdite (pas de GRANT)', 'admin@demelo.test', 'refus_droit',
      format('delete from public.affirmations where id = %s', a_nt));

    -- -----------------------------------------------------------------
    -- Contrôles bloquants (triggers, indépendants des policies)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('W1', 'admin : décision sans motif bloquée', 'admin@demelo.test', 'bloque',
      format('update public.affirmations set statut_analyse = %L where id = %s', 'analyse_disponible', a_revue));
    r := r || pg_temp.essai('W2', 'admin : revue d''un cas sensible avec motif', 'admin@demelo.test', '=1',
      format('update public.affirmations set statut_analyse = %L, revue_motif = %L where id = %s', 'analyse_disponible', '[TEST] relu', a_revue));
    r := r || pg_temp.essai('W3', '« vrai » sans preuve primaire bloqué', 'admin@demelo.test', 'bloque',
      format('update public.affirmations set statut_analyse = %L, verdict = %L, explication = %L, limites = %L, modele_ia = %L, version_prompt = %L, analyse_le = now(), recoupement = pg_temp.recoupement(), revue_motif = %L where id = %s',
             'analyse_disponible', 'vrai', 'x', 'x', 'claude-opus-5-5', 't', 'x', a_cours));
    r := r || pg_temp.essai('W4', 'clé service_role : aucune modification d''analyse', 'service_role', 'bloque',
      format('update public.affirmations set statut_analyse = %L, revue_motif = %L where id = %s', 'retire', 'x', a_abst));
    r := r || pg_temp.essai('W5', 'analyse publiée : explication figée', 'admin@demelo.test', 'bloque',
      format('update public.affirmations set explication = %L where id = %s', 'Réécrite', a_abst));
    r := r || pg_temp.essai('W6', 'affirmation sur un contenu fictif bloquée', 'admin@demelo.test', 'bloque',
      format('insert into public.affirmations (contenu_id, texte_affirmation) values (%s, %L)', c_fictif, '[TEST] Sur un faux article.'));
    r := r || pg_temp.essai('W7', 'rôle admin forgé sur un compte anonyme : bloqué', 'admin@demelo.test', 'bloque',
      format('update public.affirmations set statut_analyse = %L, revue_motif = %L where id = %s', 'retire', 'x', a_abst), true);

    -- -----------------------------------------------------------------
    -- Table preuves (P10 à P12, G4)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P10', 'anon voit la preuve vérifiée d''une analyse publiée', 'anon', '=1', format('select 1 from public.preuves where id = %s', p_ok));
    r := r || pg_temp.essai('P10', 'anon ne voit pas l''échec tracé', 'anon', '=0', format('select 1 from public.preuves where id = %s', p_echec));
    r := r || pg_temp.essai('P10', 'anon ne voit pas la preuve d''une analyse en cours', 'anon', '=0', format('select 1 from public.preuves where id = %s', p_cours));
    r := r || pg_temp.essai('P10', 'admin voit l''échec et la preuve en cours', 'admin@demelo.test', '=2',
      format('select 1 from public.preuves where id in (%s, %s)', p_echec, p_cours));
    r := r || pg_temp.essai('P11', 'admin ajoute une preuve pendant l''analyse', 'admin@demelo.test', '=1',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet) values (%s, %s, %L, %L, %L, %L)',
             a_cours, s_insee, 'https://www.insee.fr/fr/demelo-test-4', 'confirme', 'rejetee', '[TEST]'));
    r := r || pg_temp.essai('P11', 'preuve ajoutée à une analyse publiée bloquée', 'admin@demelo.test', 'bloque',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet) values (%s, %s, %L, %L, %L, %L)',
             a_abst, s_insee, 'https://www.insee.fr/fr/demelo-test-5', 'confirme', 'rejetee', '[TEST]'));
    r := r || pg_temp.essai('P11', 'preuve vérifiée hors périmètre bloquée', 'admin@demelo.test', 'bloque',
      format('select pg_temp.preuve_ok(%s, %s, %L, %L, %L)', a_cours, s_insee, 'https://www.demelo-test.example/faux-insee', 'confirme', 'primaire'));
    r := r || pg_temp.essai('P11', 'extrait d''une source sous licence bloqué', 'admin@demelo.test', 'bloque',
      format('select pg_temp.preuve_ok(%s, %s, %L, %L, %L)', a_cours, s_afp, 'https://factuel.afp.com/demelo-test', 'confirme', 'secondaire'));
    r := r || pg_temp.essai('P11', 'compte sans rôle : ajout bloqué', 'visiteur@demelo.test', 'bloque',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet) values (%s, %s, %L, %L, %L, %L)',
             a_cours, s_insee, 'https://www.insee.fr/fr/demelo-test-6', 'confirme', 'rejetee', '[TEST]'));
    r := r || pg_temp.essai('P12', 'admin modifie une preuve pendant l''analyse', 'admin@demelo.test', '=1',
      format('update public.preuves set note = %L where id = %s', '[TEST] note', p_cours));
    r := r || pg_temp.essai('P12', 'preuve d''une analyse publiée figée', 'admin@demelo.test', 'bloque',
      format('update public.preuves set note = %L where id = %s', '[TEST] note', p_ok));
    r := r || pg_temp.essai('G4', 'anon : ajout de preuve interdit (pas de GRANT)', 'anon', 'refus_droit',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, statut_preuve, motif_rejet) values (%s, %s, %L, %L, %L, %L)',
             a_cours, s_insee, 'https://www.insee.fr/fr/demelo-test-7', 'confirme', 'rejetee', 'x'));
    r := r || pg_temp.essai('G4', 'admin : suppression interdite (pas de GRANT)', 'admin@demelo.test', 'refus_droit',
      format('delete from public.preuves where id = %s', p_echec));

    -- -----------------------------------------------------------------
    -- Vues (G5)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('G5', 'anon : fiche publique avec mention IA et 1 preuve', 'anon', '=1',
      format('select 1 from public.v_analyses_publiques where id = %s and mention = %L and jsonb_array_length(preuves) = 1', a_publiee, 'Analyse produite par IA'));
    r := r || pg_temp.essai('G5', 'anon : fiches limitées aux 2 analyses publiques', 'anon', '=2',
      format('select 1 from public.v_analyses_publiques where contenu_id in (%s, %s)', c_visible, c_masque));
    r := r || pg_temp.essai('G5', 'anon : le flux n''affiche ni masqué ni fictif', 'anon', '=0',
      format('select 1 from public.v_feed_verifie where id in (%s, %s)', c_masque, c_fictif));

    raise exception 'annuler_donnees_test';   -- annule TOUTES les données de test
  exception when others then
    if sqlerrm <> 'annuler_donnees_test' then raise; end if;
  end;

  insert into resultats_rls (code, test, attendu, obtenu, statut)
  select x.code, x.test, x.attendu, x.obtenu, x.statut
    from jsonb_to_recordset(r) as x(code text, test text, attendu text, obtenu text, statut text);
end $$;

-- Synthèse, puis détail (le SQL Editor affiche le dernier tableau).
select statut, code, test, attendu, obtenu,
       count(*) filter (where statut = '✅') over () || ' ✅ / ' ||
       count(*) filter (where statut = '❌') over () || ' ❌ / ' ||
       count(*) filter (where statut = '⏳') over () || ' ⏳' as bilan
  from resultats_rls
 order by n;
