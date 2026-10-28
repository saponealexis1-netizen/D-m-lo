-- =====================================================================
--  TESTS RLS RÉELS — à exécuter dans le SQL Editor de Supabase
-- =====================================================================
--  Rejouable à volonté, et sans risque :
--  * les données de test sont créées puis ANNULÉES (rollback) à la fin :
--    rien ne reste dans les tables ;
--  * chaque essai s'exécute avec le vrai rôle Postgres (anon ou authenticated)
--    et un JWT simulé, donc avec les vraies policies du projet ;
--  * seuls des objets temporaires (pg_temp), propres à la session, sont créés.
--
--  Prérequis : 3 comptes de test créés dans Authentication > Users
--  (« Auto Confirm User » coché), avec leur rôle (voir docs/tutoriel-rls.md) :
--    editeur@demelo.test    role_equipe = editeur
--    relecteur@demelo.test  role_equipe = relecteur
--    visiteur@demelo.test   aucun rôle (simple compte connecté)
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

do $$
declare
  ed  uuid := (select id from auth.users where email = 'editeur@demelo.test');
  rel uuid := (select id from auth.users where email = 'relecteur@demelo.test');
  vis uuid := (select id from auth.users where email = 'visiteur@demelo.test');
  s_monde bigint := (select id from public.sources where nom = 'Le Monde');
  s_insee bigint := (select id from public.sources where nom = 'INSEE');
  s_inactive bigint; c_visible bigint; c_masque bigint;
  a_brouillon bigint; a_relecture bigint; a_publiee bigint; a_rel_relecture bigint; a_rel_brouillon bigint;
  p_brouillon bigint; p_publiee bigint;
  r jsonb := '[]';
begin
  if ed is null or rel is null or vis is null then
    raise exception 'Créer d''abord les 3 comptes de test (editeur@, relecteur@, visiteur@demelo.test).';
  end if;

  begin
    -- -----------------------------------------------------------------
    -- Données de test (créées par le propriétaire, annulées à la fin).
    -- Les triggers de validation s'appliquent : on simule les bons JWT.
    -- -----------------------------------------------------------------
    insert into public.sources (nom, type_source, url_base, active)
    values ('[TEST] source inactive', 'media', 'https://test.invalid', false) returning id into s_inactive;
    insert into public.contenus (source_id, titre, url_originale, lot_import)
    values (s_monde, '[TEST] article visible', 'https://test.invalid/visible', 'test-rls') returning id into c_visible;
    insert into public.contenus (source_id, titre, url_originale, visible_public, lot_import)
    values (s_monde, '[TEST] article masqué', 'https://test.invalid/masque', false, 'test-rls') returning id into c_masque;

    perform set_config('request.jwt.claims', json_build_object('sub', ed, 'role', 'authenticated',
      'app_metadata', json_build_object('role_equipe', 'editeur'))::text, true);
    insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
    values (c_visible, '[TEST] Brouillon de l''éditeur, jamais public.', 'vrai', 'Test') returning id into a_brouillon;
    insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
    values (a_brouillon, s_insee, 'https://test.invalid/preuve-brouillon', 'confirme') returning id into p_brouillon;

    insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
    values (c_visible, '[TEST] Affirmation de l''éditeur en relecture.', 'vrai', 'Test') returning id into a_relecture;
    insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
    values (a_relecture, s_insee, 'https://test.invalid/preuve-relecture', 'confirme');
    update public.affirmations set statut_workflow = 'en_relecture' where id = a_relecture;

    insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
    values (c_visible, '[TEST] Affirmation publiée et vérifiée.', 'faux', 'Test') returning id into a_publiee;
    insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
    values (a_publiee, s_insee, 'https://test.invalid/preuve-publiee', 'contredit') returning id into p_publiee;
    update public.affirmations set statut_workflow = 'en_relecture' where id = a_publiee;

    perform set_config('request.jwt.claims', json_build_object('sub', rel, 'role', 'authenticated',
      'app_metadata', json_build_object('role_equipe', 'relecteur'))::text, true);
    update public.affirmations set statut_workflow = 'publie' where id = a_publiee;
    insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication)
    values (c_visible, '[TEST] Affirmation du relecteur en relecture.', 'vrai', 'Test') returning id into a_rel_relecture;
    insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation)
    values (a_rel_relecture, s_insee, 'https://test.invalid/preuve-rel', 'confirme');
    update public.affirmations set statut_workflow = 'en_relecture' where id = a_rel_relecture;
    insert into public.affirmations (contenu_id, texte_affirmation)
    values (c_visible, '[TEST] Brouillon du relecteur.') returning id into a_rel_brouillon;

    -- -----------------------------------------------------------------
    -- Table sources (P1 à P3, G1)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P1', 'anon voit une source active', 'anon', '=1',
      format('select 1 from public.sources where id = %s', s_monde));
    r := r || pg_temp.essai('P1', 'anon ne voit pas une source inactive', 'anon', '=0',
      format('select 1 from public.sources where id = %s', s_inactive));
    r := r || pg_temp.essai('P1', 'éditeur voit la source inactive', 'editeur@demelo.test', '=1',
      format('select 1 from public.sources where id = %s', s_inactive));
    r := r || pg_temp.essai('P2', 'éditeur ajoute une source', 'editeur@demelo.test', '=1',
      $q$ insert into public.sources (nom, type_source, url_base) values ('[TEST] nouvelle source', 'media', 'https://test.invalid/n') $q$);
    r := r || pg_temp.essai('P2', 'compte sans rôle : ajout de source bloqué', 'visiteur@demelo.test', 'bloque',
      $q$ insert into public.sources (nom, type_source, url_base) values ('[TEST] pirate', 'media', 'https://test.invalid/p') $q$);
    r := r || pg_temp.essai('P3', 'éditeur modifie une source', 'editeur@demelo.test', '=1',
      format('update public.sources set licence_info = licence_info where id = %s', s_inactive));
    r := r || pg_temp.essai('P3', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.sources set licence_info = %L where id = %s', 'piraté', s_monde));
    r := r || pg_temp.essai('G1', 'anon : écriture interdite (pas de GRANT)', 'anon', 'refus_droit',
      $q$ insert into public.sources (nom, type_source, url_base) values ('[TEST] anon', 'media', 'https://test.invalid/a') $q$);
    r := r || pg_temp.essai('G1', 'éditeur : suppression interdite (pas de GRANT)', 'editeur@demelo.test', 'refus_droit',
      format('delete from public.sources where id = %s', s_inactive));

    -- -----------------------------------------------------------------
    -- Table contenus (P4 à P6, G2)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P4', 'anon voit l''article visible', 'anon', '=1',
      format('select 1 from public.contenus where id = %s', c_visible));
    r := r || pg_temp.essai('P4', 'anon ne voit pas l''article masqué', 'anon', '=0',
      format('select 1 from public.contenus where id = %s', c_masque));
    r := r || pg_temp.essai('P4', 'éditeur voit l''article masqué', 'editeur@demelo.test', '=1',
      format('select 1 from public.contenus where id = %s', c_masque));
    r := r || pg_temp.essai('P5', 'éditeur indexe un article', 'editeur@demelo.test', '=1',
      format('insert into public.contenus (source_id, titre, url_originale) values (%s, %L, %L)', s_monde, '[TEST] nouvel article', 'https://test.invalid/nouveau'));
    r := r || pg_temp.essai('P5', 'compte sans rôle : indexation bloquée', 'visiteur@demelo.test', 'bloque',
      format('insert into public.contenus (source_id, titre, url_originale) values (%s, %L, %L)', s_monde, '[TEST] pirate', 'https://test.invalid/pirate'));
    r := r || pg_temp.essai('P6', 'éditeur modifie un article', 'editeur@demelo.test', '=1',
      format('update public.contenus set theme = %L where id = %s', 'institutions', c_visible));
    r := r || pg_temp.essai('P6', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.contenus set titre = %L where id = %s', '[TEST] piraté', c_visible));
    r := r || pg_temp.essai('G2', 'anon : modification interdite (pas de GRANT)', 'anon', 'refus_droit',
      format('update public.contenus set titre = %L where id = %s', '[TEST] anon', c_visible));

    -- -----------------------------------------------------------------
    -- Table affirmations (P7 à P10, G3) — aucun brouillon ne doit fuiter
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P7', 'anon voit l''affirmation publiée', 'anon', '=1',
      format('select 1 from public.affirmations where id = %s', a_publiee));
    r := r || pg_temp.essai('P7', 'anon ne voit aucun brouillon ni relecture', 'anon', '=0',
      format('select 1 from public.affirmations where id in (%s, %s, %s, %s)', a_brouillon, a_relecture, a_rel_relecture, a_rel_brouillon));
    r := r || pg_temp.essai('P7', 'compte sans rôle ne voit aucun brouillon', 'visiteur@demelo.test', '=0',
      format('select 1 from public.affirmations where id in (%s, %s)', a_brouillon, a_relecture));
    r := r || pg_temp.essai('P7', 'éditeur voit les brouillons de l''équipe', 'editeur@demelo.test', '=2',
      format('select 1 from public.affirmations where id in (%s, %s)', a_brouillon, a_rel_brouillon));
    r := r || pg_temp.essai('P8', 'éditeur crée un brouillon', 'editeur@demelo.test', '=1',
      format('insert into public.affirmations (contenu_id, texte_affirmation, created_by) values (%s, %L, %L)', c_visible, '[TEST] Nouveau brouillon.', ed));
    r := r || pg_temp.essai('P8', 'création directement « publiée » bloquée', 'editeur@demelo.test', 'bloque',
      format('insert into public.affirmations (contenu_id, texte_affirmation, verdict, explication, statut_workflow, created_by) values (%s, %L, %L, %L, %L, %L)',
             c_visible, '[TEST] Publication forcée.', 'vrai', 'x', 'publie', ed));
    r := r || pg_temp.essai('P8', 'compte sans rôle : création bloquée', 'visiteur@demelo.test', 'bloque',
      format('insert into public.affirmations (contenu_id, texte_affirmation, created_by) values (%s, %L, %L)', c_visible, '[TEST] Pirate.', vis));
    r := r || pg_temp.essai('P9', 'compte sans rôle : modification bloquée', 'visiteur@demelo.test', 'bloque',
      format('update public.affirmations set explication = %L where id = %s', 'piraté', a_brouillon));
    r := r || pg_temp.essai('P9', 'éditeur modifie son brouillon', 'editeur@demelo.test', '=1',
      format('update public.affirmations set explication = %L where id = %s', 'Explication complétée.', a_brouillon));
    r := r || pg_temp.essai('P10', 'éditeur supprime son brouillon', 'editeur@demelo.test', '=1',
      format('delete from public.affirmations where id = %s', a_brouillon));
    r := r || pg_temp.essai('P10', 'éditeur ne supprime pas le brouillon d''un autre', 'editeur@demelo.test', 'bloque',
      format('delete from public.affirmations where id = %s', a_rel_brouillon));
    r := r || pg_temp.essai('P10', 'suppression d''une affirmation publiée bloquée', 'relecteur@demelo.test', 'bloque',
      format('delete from public.affirmations where id = %s', a_publiee));
    r := r || pg_temp.essai('G3', 'anon : création interdite (pas de GRANT)', 'anon', 'refus_droit',
      format('insert into public.affirmations (contenu_id, texte_affirmation) values (%s, %L)', c_visible, '[TEST] anon'));

    -- -----------------------------------------------------------------
    -- Validation humaine (triggers, indépendants des policies)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('W1', 'éditeur : publication bloquée', 'editeur@demelo.test', 'bloque',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'publie', a_relecture));
    r := r || pg_temp.essai('W2', 'relecteur publie l''affirmation d''un autre', 'relecteur@demelo.test', '=1',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'publie', a_relecture));
    r := r || pg_temp.essai('W3', 'relecteur : auto-validation bloquée', 'relecteur@demelo.test', 'bloque',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'publie', a_rel_relecture));
    r := r || pg_temp.essai('W4', 'clé service_role : publication bloquée', 'service_role', 'bloque',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'publie', a_relecture));
    r := r || pg_temp.essai('W5', 'envoi en relecture sans preuve bloqué', 'relecteur@demelo.test', 'bloque',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'en_relecture', a_rel_brouillon));
    r := r || pg_temp.essai('W6', 'affirmation publiée : texte figé', 'relecteur@demelo.test', 'bloque',
      format('update public.affirmations set explication = %L where id = %s', 'Réécrite après coup.', a_publiee));
    r := r || pg_temp.essai('W7', 'rôle forgé sur un compte anonyme : bloqué', 'relecteur@demelo.test', 'bloque',
      format('update public.affirmations set statut_workflow = %L where id = %s', 'publie', a_relecture), true);

    -- -----------------------------------------------------------------
    -- Table preuves (P11 à P13, G4)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('P11', 'anon voit la preuve d''une affirmation publiée', 'anon', '=1',
      format('select 1 from public.preuves where id = %s', p_publiee));
    r := r || pg_temp.essai('P11', 'anon ne voit pas la preuve d''un brouillon', 'anon', '=0',
      format('select 1 from public.preuves where id = %s', p_brouillon));
    r := r || pg_temp.essai('P11', 'éditeur voit la preuve du brouillon', 'editeur@demelo.test', '=1',
      format('select 1 from public.preuves where id = %s', p_brouillon));
    r := r || pg_temp.essai('P12', 'éditeur ajoute une preuve à son brouillon', 'editeur@demelo.test', '=1',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, ajoutee_par) values (%s, %s, %L, %L, %L)',
             a_brouillon, s_insee, 'https://test.invalid/preuve-2', 'contextualise', ed));
    r := r || pg_temp.essai('P12', 'preuve ajoutée à une affirmation publiée bloquée', 'editeur@demelo.test', 'bloque',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, ajoutee_par) values (%s, %s, %L, %L, %L)',
             a_publiee, s_insee, 'https://test.invalid/preuve-3', 'confirme', ed));
    r := r || pg_temp.essai('P12', 'extrait d''une source sous licence bloqué', 'editeur@demelo.test', 'bloque',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, extrait, ajoutee_par) values (%s, %s, %L, %L, %L, %L)',
             a_brouillon, s_monde, 'https://test.invalid/preuve-4', 'confirme', 'Texte copié', ed));
    r := r || pg_temp.essai('P12', 'compte sans rôle : ajout de preuve bloqué', 'visiteur@demelo.test', 'bloque',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation, ajoutee_par) values (%s, %s, %L, %L, %L)',
             a_brouillon, s_insee, 'https://test.invalid/preuve-5', 'confirme', vis));
    r := r || pg_temp.essai('P13', 'éditeur supprime la preuve d''un brouillon', 'editeur@demelo.test', '=1',
      format('delete from public.preuves where id = %s', p_brouillon));
    r := r || pg_temp.essai('P13', 'preuve d''une affirmation publiée : suppression bloquée', 'editeur@demelo.test', 'bloque',
      format('delete from public.preuves where id = %s', p_publiee));
    r := r || pg_temp.essai('G4', 'anon : ajout de preuve interdit (pas de GRANT)', 'anon', 'refus_droit',
      format('insert into public.preuves (affirmation_id, source_id, url_preuve, type_relation) values (%s, %s, %L, %L)',
             a_brouillon, s_insee, 'https://test.invalid/preuve-6', 'confirme'));

    -- -----------------------------------------------------------------
    -- Vue v_feed_verifie (G5)
    -- -----------------------------------------------------------------
    r := r || pg_temp.essai('G5', 'anon : la vue compte 1 affirmation publiée (pas les brouillons)', 'anon', '=1',
      format('select 1 from public.v_feed_verifie where id = %s and nb_affirmations_publiees = 1 and statut_verification = %L', c_visible, 'verifie'));
    r := r || pg_temp.essai('G5', 'anon : l''article masqué est absent de la vue', 'anon', '=0',
      format('select 1 from public.v_feed_verifie where id = %s', c_masque));

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
