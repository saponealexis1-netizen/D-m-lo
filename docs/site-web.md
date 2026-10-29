# Site web (`web/`)

React 18 + Vite + TypeScript, avec `@supabase/supabase-js`. Toutes les données viennent de Supabase ; aucune n'est écrite en dur.

| Page | Lecture | Rôle |
|---|---|---|
| Articles (`/`) | `v_feed_verifie` : filtres thème/statut, recherche, 20 par page | visiteur |
| Fiche (`/article/:id`) | `v_feed_verifie` et `v_analyses_publiques` (verdict ou abstention, preuves vérifiées, mention « Analyse produite par IA ») | visiteur |
| Sources (`/sources`) | `sources` actives | visiteur |
| Bandeau « dernière mise à jour » | `contenus.vu_le` le plus récent | visiteur |
| Équipe (`/equipe`) | compteurs (dont les 500 lignes fictives) et file des cas sensibles (`revue_requise`) : publier, abstention ou écarter, avec un motif obligatoire | admin |

- **Clés** : uniquement `VITE_SUPABASE_URL` et `VITE_SUPABASE_PUBLISHABLE_KEY` (voir `.env.example`). Le site refuse de démarrer avec une clé `sb_secret_…` ou `service_role`.
- **Droits** : c'est la RLS qui décide. L'affichage de l'espace équipe dépend de `app_metadata.role_equipe`, mais chaque décision est contrôlée par `prive.controler_affirmation`.
- **Comptes** : il n'y a pas d'inscription publique. Les 4 comptes admin sont créés dans Supabase Auth.
- **Base pas encore configurée** : le site affiche « Accès refusé par la base : les droits de lecture (RLS et GRANT) ne sont pas encore configurés » au lieu de planter.

## Lancer en local
```bash
cd web && cp .env.example .env.local   # renseigner la clé publishable
npm ci && npm run dev
```

## Tests effectués
- `npm run build` (typecheck strict, puis build).
- Rendu réel dans Chromium (Playwright) contre un faux PostgREST : toutes les pages s'affichent sans erreur console, et il n'y a pas de débordement horizontal à 375 px. Le cas « droits non configurés » (401/42501) et le refus d'une clé secrète ont aussi été vérifiés.
- `supabase/brouillons/tests/tests_requetes_front.sql` (dans `lancer_tests.sh`) : les requêtes du site sont rejouées sur le vrai schéma local, en visiteur (15 sources, aucune donnée fictive) puis en admin (500 lignes fictives visibles).
- Testé le 29/10/2026 contre le projet distant, en visiteur (clé publishable) : 15 sources, 260 articles, 9 analyses publiques, aucune donnée fictive visible ; pages Articles et Sources rendues dans Edge. Non testé : la connexion admin (Supabase Auth) et l'espace Équipe.

## Déploiement
Choix de l'équipe (29/10/2026) : le site reste **en local**, lancé depuis le dépôt (`npm run dev`, ou `npm run build && npm run preview`). Pour un hébergement futur (🔒 accord requis), Netlify ou Vercel : base `web`, commande `npm run build`, dossier `dist`, deux variables d'environnement `VITE_…`. Ajouter une règle SPA (`/* /index.html 200`).
