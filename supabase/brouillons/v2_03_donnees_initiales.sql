-- =====================================================================
--  BROUILLON — NE PAS APPLIQUER SANS VALIDATION EXPLICITE
--  Étape 3/3 : sources de départ, reprises des données de référence v1
-- =====================================================================
--  9 médias + 19 organismes de la v1 (sauvegarde/2026-10-28_schema_v1/)
--  deviennent 28 lignes de `sources`. Collecte 'manuel' par défaut : les flux
--  RSS et les chaînes YouTube seront renseignés après vérification.
--  À compléter par l'équipe : chaînes YouTube (type 'chaine_youtube',
--  mode 'api_youtube', identifiant_externe = ID de la chaîne).
-- =====================================================================

insert into public.sources (nom, type_source, url_base, reutilisation) values
  -- Médias (presse : lien seulement)
  ('Le Monde',                         'media',         'https://www.lemonde.fr',                    'lien_seulement'),
  ('Le Figaro',                        'media',         'https://www.lefigaro.fr',                   'lien_seulement'),
  ('Libération',                       'media',         'https://www.liberation.fr',                 'lien_seulement'),
  ('CNews',                            'media',         'https://www.cnews.fr',                      'lien_seulement'),
  ('franceinfo',                       'media',         'https://www.francetvinfo.fr',               'lien_seulement'),
  ('BFMTV',                            'media',         'https://www.bfmtv.com',                     'lien_seulement'),
  ('Le Parisien',                      'media',         'https://www.leparisien.fr',                 'lien_seulement'),
  ('Ouest-France',                     'media',         'https://www.ouest-france.fr',               'lien_seulement'),
  ('20 Minutes',                       'media',         'https://www.20minutes.fr',                  'lien_seulement'),
  -- Sources primaires (données publiques réutilisables, Licence Ouverte)
  ('INSEE',                            'statistique',   'https://www.insee.fr',                      'ouverte'),
  ('Eurostat',                         'statistique',   'https://ec.europa.eu/eurostat',             'ouverte'),
  ('DREES',                            'statistique',   'https://drees.solidarites-sante.gouv.fr',   'ouverte'),
  ('DARES',                            'statistique',   'https://dares.travail-emploi.gouv.fr',      'ouverte'),
  ('Banque de France',                 'statistique',   'https://www.banque-france.fr',              'ouverte'),
  ('SSMSI (ministère de l''Intérieur)','statistique',   'https://www.interieur.gouv.fr',             'ouverte'),
  ('Légifrance',                       'juridique',     'https://www.legifrance.gouv.fr',            'ouverte'),
  ('Conseil constitutionnel',          'juridique',     'https://www.conseil-constitutionnel.fr',    'ouverte'),
  ('Assemblée nationale',              'institution',   'https://www.assemblee-nationale.fr',        'ouverte'),
  ('Sénat',                            'institution',   'https://www.senat.fr',                      'ouverte'),
  ('Cour des comptes',                 'institution',   'https://www.ccomptes.fr',                   'ouverte'),
  ('Vie-publique.fr',                  'institution',   'https://www.vie-publique.fr',               'ouverte'),
  ('HATVP',                            'institution',   'https://www.hatvp.fr',                      'ouverte'),
  ('Viginum (SGDSN)',                  'institution',   'https://www.sgdsn.gouv.fr',                 'ouverte'),
  -- Fact-checkeurs professionnels (lien seulement)
  ('AFP Factuel',                      'fact_checking', 'https://factuel.afp.com',                   'lien_seulement'),
  ('Les Décodeurs (Le Monde)',         'fact_checking', 'https://www.lemonde.fr/les-decodeurs',      'lien_seulement'),
  ('CheckNews (Libération)',           'fact_checking', 'https://www.liberation.fr/checknews',       'lien_seulement'),
  ('Vrai ou faux (franceinfo)',        'fact_checking', 'https://www.francetvinfo.fr/vrai-ou-fake',  'lien_seulement'),
  ('Les Surligneurs',                  'fact_checking', 'https://www.lessurligneurs.eu',             'lien_seulement');
