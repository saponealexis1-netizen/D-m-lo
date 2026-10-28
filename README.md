# Démêlo

> Démêle l'info. Fais-toi ton avis.

Application web de vérification de l'information politique pour les 18–25 ans, à l'approche de l'élection présidentielle 2027 (1er tour le 18 avril 2027, 2nd tour le 2 mai 2027).

On ajoute des articles de médias en accès libre ; une IA (Mistral) en extrait les affirmations factuelles et les vérifie uniquement à partir de sources fiables stockées en base (INSEE, Légifrance, Cour des comptes, fact-checkeurs professionnels…). Chaque vérification affiche ses sources et les candidats concernés. Un chatbot répond aux questions à partir de la même base.

## Structure

| Chemin | Contenu |
|---|---|
| `supabase/migrations/` | Schéma complet : 13 tables, RLS, triggers, RPC, vue publique, tâches planifiées |
| `supabase/functions/importer-rss/` | Import quotidien des flux RSS des médias (articles en statut `importe`) |
| `supabase/functions/analyser-article/` | Extraction et vérification des affirmations d'un article choisi par un éditeur |
| `supabase/functions/chatbot/` | Réponses aux visiteurs à partir des sources (RAG), avec quota |
| `supabase/functions/maj-sources/` | Mise à jour hebdomadaire des sources (embeddings) et des candidats |
| `supabase/tests/` | Tests de la migration dans un Postgres local |
| `docs/mise-en-place.md` | Réglages du dashboard Supabase, secrets, déploiement, premiers tests |

## Contraintes du projet

- 4 tables liées par clé étrangère minimum : `medias → articles → affirmations → affirmation_sources ← sources ← organismes` (et d'autres)
- Zéro donnée en dur : verdicts, organismes, médias, paramètres et candidats sont en base
- Authentification : comptes de l'équipe (viewer / éditeur / admin) et connexions anonymes pour les visiteurs
- RLS sur les 13 tables
- Table de 500 lignes minimum : `articles`, alimentée par les flux RSS
- Logique côté base : triggers (publication sourcée, quota d'analyses par média, signalements), RPC, vue `affirmations_publiques`
