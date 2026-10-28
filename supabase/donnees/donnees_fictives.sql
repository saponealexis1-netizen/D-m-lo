-- =====================================================================
--  Données FICTIVES pour atteindre 500 lignes dans `contenus` (autorisé par le professeur)
-- =====================================================================
--  À exécuter par un administrateur dans le SQL Editor, APRÈS la migration v2_05.
--  Rejouable sans doublon (URL unique, « on conflict do nothing »).
--
--  Garanties (contrainte contenus_fictif_check + RLS) :
--  * est_test = true, titre « [FICTIF] … », domaine *.invalid (réservé, n'existe pas),
--    média « Média fictif … », jamais rattaché à l'un des 15 organismes ;
--  * invisibles pour le public et pour le pipeline ; aucune affirmation possible.
--  Variées (5 médias, 6 thèmes, 12 mois, articles masqués) pour tester filtres,
--  recherches, jointures et statistiques côté équipe.
-- =====================================================================
insert into public.contenus (media_nom, titre, url_originale, identifiant_externe, theme,
                             date_publication, visible_public, est_test, lot_import, statut_traitement)
select
  'Média fictif ' || (array['Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo'])[1 + n % 5],
  '[FICTIF] ' || (array['Débat budgétaire', 'Transition énergétique', 'Réforme institutionnelle',
                        'Emploi des jeunes', 'Politique européenne', 'Sécurité du quotidien'])[1 + n % 6]
              || ' — article de démonstration n° ' || n,
  'https://demelo-fictif.invalid/article-' || n,
  'fictif-' || n,
  (array['economie', 'ecologie', 'institutions', 'societe', 'international', 'autre'])[1 + n % 6]::public.theme_contenu,
  timestamptz '2026-01-01 08:00+01' + (n * interval '15 hours'),
  n % 10 <> 0,
  true,
  'fictif-v1',
  'traite'
from generate_series(1, 500) as n
on conflict do nothing;

-- Contrôle
select count(*) filter (where est_test) as fictifs, count(*) filter (where not est_test) as reels, count(*) as total
  from public.contenus;

-- Retour arrière (si besoin, uniquement les données fictives) :
-- delete from public.contenus where est_test and lot_import = 'fictif-v1';
