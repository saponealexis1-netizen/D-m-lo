# Démêlo — Guide Supabase pour l'équipe

## 1. Connexion
- Projet : `aoysmqeasnfnyvmfwktt` — URL : `https://aoysmqeasnfnyvmfwktt.supabase.co`.
- Le site n'utilise **que la clé publishable** (`sb_publishable_…`, Dashboard > Project Settings > API Keys).
  Elle est publique par nature : la sécurité repose sur la RLS.
- Côté site : variables `VITE_SUPABASE_URL` et `VITE_SUPABASE_PUBLISHABLE_KEY` (`web/.env.example`).

## 2. Ce que le site lit (et rien d'autre)
| Besoin | Objet | Filtre / tri |
|---|---|---|
| Fil des articles | vue `v_feed_verifie` | `order=date_publication.desc`, filtres `theme`, `statut_verification` |
| Fiche d'un article | `v_feed_verifie?id=eq.<id>` + `v_analyses_publiques?contenu_id=eq.<id>` | — |
| Organismes de preuve | table `sources` | `active=eq.true`, `order=nom` |
| « Dernière mise à jour » | `contenus?select=vu_le&order=vu_le.desc&limit=1` | — |

### Champs à afficher
- **`v_feed_verifie`** : `titre`, `media_nom`, `date_publication`, `theme`, `url_originale` (lien vers le média), `statut_verification` (`analyse_disponible` / `verification_insuffisante` / `non_verifie`), `nb_analyses_publiees`.
- **`v_analyses_publiques`** :
  - `texte_affirmation` (citation exacte de l'article), `contexte` ;
  - `verdict` (`vrai`, `faux`, `trompeur`, `non_verifiable`) **ou**, si `statut_analyse = verification_insuffisante`, `motif_abstention` ;
  - `explication`, `limites` (**toujours affichées**) ;
  - `mention` (« Analyse produite par IA ») — **obligatoire à l'écran** ;
  - `revue_par_equipe`, `analyse_le`, `version`, `modele_ia` ;
  - `preuves` (tableau JSON) : `url`, `titre`, `organisme`, `relation` (`confirme` / `contredit` / `contextualise`), `nature` (`primaire` / `secondaire`), `date_document`, `extrait`, `consulte_le`.

## 3. Ce que voit chaque profil (vérifié le 28/10/2026)
| Profil | Articles | Données fictives | Analyses | Écriture |
|---|---|---|---|---|
| Visiteur (`anon`) | 260 | 0 | 9 publiées, 13 preuves | refusée |
| Compte connecté sans rôle | 260 | 0 | 9 publiées | 0 ligne modifiable |
| Admin (`app_metadata.role_equipe = 'admin'`) | 760 | 500 | 10 (dont 1 en `revue_requise`) | via les triggers uniquement |

## 4. Authentification (espace équipe seulement)
- Pas d'inscription publique : comptes créés dans **Authentication > Users**.
- Le rôle admin se donne **uniquement** dans `raw_app_meta_data` (SQL Editor), jamais `user_metadata`
  (modifiable par l'utilisateur lui-même). Se reconnecter pour que le rôle entre dans le jeton.
- Une décision admin (publier, abstention, écarter) **exige un motif** (`revue_motif`) ; le trigger refuse sinon.
- Cas sensibles : passage obligatoire par `revue_requise` puis décision d'un admin.

## 5. Précautions de sécurité
- **Jamais** la clé secrète / `service_role` dans le site, le dépôt, un message ou une capture (le dépôt est **public**).
- Ne jamais écrire `using (true)` sur `affirmations` ou `preuves`, ne pas désactiver la RLS.
- Aucune suppression n'est prévue pour les clients (pas de `DELETE` accordé).
- Les données fictives (`est_test = true`, domaine `.invalid`) ne doivent jamais apparaître sur le site.
- Secrets GitHub existants : `DEMELO_DATABASE_URL`, `DEMELO_DB_CA` (collecte) — ne pas les recopier ailleurs.
- À faire : désactiver les connexions anonymes (Authentication > Sign In / Providers).

## 6. Tests
- SQL Editor : `supabase/rls_manuel/tests_sql_editor.sql` → attendu **52 ✅ / 0 ❌ / 0 ⏳**.
- API réelle : workflow **Tests API Supabase** (manuel), puis `supabase/rls_manuel/nettoyage_tests_api.sql`.
