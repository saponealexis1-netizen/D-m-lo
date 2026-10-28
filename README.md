# Démêlo

> Démêle l'info. Fais-toi ton avis.

Application web pédagogique pour les 18–25 ans : l'actualité politique française avant la présidentielle 2027, avec des analyses factuelles produites par IA (Claude) et appuyées sur des preuves vérifiables issues de 15 organismes publics.

| Dossier | Contenu |
|---|---|
| `supabase/migrations/` | Migrations appliquées sur Supabase (4 tables métier : `sources`, `contenus`, `affirmations`, `preuves`) |
| `supabase/brouillons/` | Migrations préparées, non appliquées (dont `v2_05_pipeline_ia.sql`) et tests locaux |
| `supabase/rls_manuel/` | Policies RLS et GRANT à configurer **à la main** par l'équipe, et leurs tests |
| `supabase/donnees/` | Données fictives identifiées (`est_test`) pour atteindre 500 lignes |
| `collecte/` | Collecte hebdomadaire des articles (flux RSS) |
| `.github/workflows/` | Workflow GitHub Actions de la collecte (lundi 9 h, heure de Paris) |
| `sauvegarde/` | Sauvegarde du schéma v1 avant reconstruction |
| `docs/` | Plan, tutoriel RLS, spécification du pipeline IA, mise en route de la collecte |
