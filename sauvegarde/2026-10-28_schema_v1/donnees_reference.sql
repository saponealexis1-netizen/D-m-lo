-- =====================================================================
--  Données de référence du schéma v1 (projet aoysmqeasnfnyvmfwktt)
-- =====================================================================
--  Exportées le 2026-10-28 en lecture seule. Aucune donnée personnelle :
--  ce sont des réglages et des listes publiques (médias, organismes).
--  Toutes les autres tables étaient vides (0 utilisateur, 0 article,
--  0 source, 0 affirmation, 0 candidat, 0 signalement, 0 message).
-- =====================================================================

-- parametres (4 lignes)
insert into public.parametres (cle, valeur, description) values ('plafond_global_questions_jour', 900, 'Questions par jour pour toute l''app, sous la limite du fournisseur d''IA');
insert into public.parametres (cle, valeur, description) values ('quota_questions_jour', 10, 'Questions au chatbot par visiteur et par jour');
insert into public.parametres (cle, valeur, description) values ('retention_messages_jours', 30, 'Durée de conservation des conversations du chatbot');
insert into public.parametres (cle, valeur, description) values ('seuil_signalements', 5, 'Nombre de signalements qui repasse une affirmation « à vérifier »');

-- verdicts (5 lignes)
insert into public.verdicts (code, libelle, description, sources_min, ordre) values ('vrai', 'Vrai', 'L''affirmation est confirmée par les sources.', 1, 1);
insert into public.verdicts (code, libelle, description, sources_min, ordre) values ('manque_de_contexte', 'Manque de contexte', 'Exact, mais présenté d''une façon qui peut induire en erreur.', 1, 2);
insert into public.verdicts (code, libelle, description, sources_min, ordre) values ('trompeur', 'Trompeur', 'Mélange d''éléments exacts et faux, ou chiffres détournés.', 2, 3);
insert into public.verdicts (code, libelle, description, sources_min, ordre) values ('faux', 'Faux', 'L''affirmation est contredite par les sources.', 2, 4);
insert into public.verdicts (code, libelle, description, sources_min, ordre) values ('non_verifiable', 'Non vérifiable', 'Aucune source fiable ne permet de trancher. Rien n''est inventé.', 0, 5);

-- medias (9 lignes, aucun flux RSS renseigné)
insert into public.medias (nom, site_url, flux_rss_url) values ('Le Monde', 'https://www.lemonde.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('Le Figaro', 'https://www.lefigaro.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('Libération', 'https://www.liberation.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('CNews', 'https://www.cnews.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('franceinfo', 'https://www.francetvinfo.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('BFMTV', 'https://www.bfmtv.com', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('Le Parisien', 'https://www.leparisien.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('Ouest-France', 'https://www.ouest-france.fr', null);
insert into public.medias (nom, site_url, flux_rss_url) values ('20 Minutes', 'https://www.20minutes.fr', null);

-- organismes (19 lignes, tous actifs)
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('INSEE', 'https://www.insee.fr', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Eurostat', 'https://ec.europa.eu/eurostat', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('DREES', 'https://drees.solidarites-sante.gouv.fr', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('DARES', 'https://dares.travail-emploi.gouv.fr', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Banque de France', 'https://www.banque-france.fr', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('SSMSI (ministère de l''Intérieur)', 'https://www.interieur.gouv.fr', 'statistique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Légifrance', 'https://www.legifrance.gouv.fr', 'juridique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Conseil constitutionnel', 'https://www.conseil-constitutionnel.fr', 'juridique', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Assemblée nationale', 'https://www.assemblee-nationale.fr', 'institution', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Sénat', 'https://www.senat.fr', 'institution', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Cour des comptes', 'https://www.ccomptes.fr', 'institution', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Vie-publique.fr', 'https://www.vie-publique.fr', 'institution', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('HATVP', 'https://www.hatvp.fr', 'institution', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Viginum (SGDSN)', 'https://www.sgdsn.gouv.fr', 'securite_information', 'ouverte', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('AFP Factuel', 'https://factuel.afp.com', 'fact_checking', 'lien_seulement', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Les Décodeurs (Le Monde)', 'https://www.lemonde.fr', 'fact_checking', 'lien_seulement', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('CheckNews (Libération)', 'https://www.liberation.fr', 'fact_checking', 'lien_seulement', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Vrai ou faux (franceinfo)', 'https://www.francetvinfo.fr', 'fact_checking', 'lien_seulement', true);
insert into public.organismes (nom, site_url, type, reutilisation, actif) values ('Les Surligneurs', 'https://www.lessurligneurs.eu', 'fact_checking', 'lien_seulement', true);
