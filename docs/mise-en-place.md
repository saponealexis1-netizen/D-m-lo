# Mise en place de Démêlo sur Supabase

Tout se fait depuis le dashboard Supabase, sans n8n. Les emplacements des menus peuvent varier un peu selon la version du dashboard.

## 1. Fonctionnement : sélection des articles par un éditeur

Décision retenue : **seuls les articles choisis par un éditeur sont analysés**. On reste ainsi dans les limites gratuites de Mistral, et la sélection reste maîtrisée.

```
flux RSS ──(importer-rss, chaque jour)──> articles 'importe'
                                              │  un éditeur choisit l'article
                                              ▼
                                         'en_attente' ──(trigger + pg_net)──> analyser-article
                                              │
                         'en_cours' ──> 'traite' | 'inaccessible' (payant, illisible) | 'erreur'
```

- Un éditeur qui ajoute un article à la main (statut `en_attente`) déclenche aussi l'analyse.
- **Règle de neutralité appliquée par la base** : au maximum `analyses_max_par_media_jour` analyses par média et par jour (5 par défaut), la même limite pour tous les médias. L'import applique de la même façon `articles_max_par_media_import` à chaque média.
- Un article déjà `traite` ne peut pas être réanalysé : cela créerait des doublons. Un article en `erreur` ou `inaccessible` peut être relancé.
- Filet de sécurité toutes les 15 minutes (`relancer_analyses`) : une demande restée sans réponse est relancée, et une analyse bloquée depuis plus de 30 minutes passe en `erreur`.

## 2. Appliquer la migration

Dans **SQL Editor**, colle et exécute `supabase/migrations/20261028150000_init_fact_checking.sql`. Avec la CLI, `supabase db push` fait la même chose.

Si une ancienne version de la migration a déjà été appliquée, il faut repartir d'une base vide (**Database > Reset**, ou un nouveau projet). Le type `statut_article` et la table `articles` ont changé.

Si la migration échoue sur une extension, active-la d'abord :
- **Database > Extensions** : `vector`, `pg_net` ;
- **Integrations > Cron** : `pg_cron`.

## 3. Réglages du dashboard

### Authentification
1. **Authentication > Sign In / Providers** : active **Allow anonymous sign-ins**.
2. **Authentication > Attack Protection** : active la protection **Captcha**, choisis **Cloudflare Turnstile**, puis colle la clé secrète Turnstile. La clé de site Turnstile va dans le front.
3. Crée ton compte (Authentication > Users > Add user), puis donne-toi le rôle admin dans le SQL Editor :

```sql
update public.profils set role = 'admin'
 where id = (select id from auth.users where email = 'TON_EMAIL');
-- Pour les autres membres de l'équipe : role = 'editeur'.
```

### Vault : URL du projet et clé interne
La base appelle les Edge Functions avec une **clé interne**, pas avec la clé `service_role`. Si cette clé fuitait, elle permettrait seulement de déclencher les fonctions, pas d'accéder aux données.

Génère une chaîne aléatoire d'au moins 32 caractères (par exemple `openssl rand -hex 32`), puis exécute :

```sql
select vault.create_secret('https://TON_PROJET.supabase.co', 'url_projet');
select vault.create_secret('LA_CLE_INTERNE_GENEREE', 'cle_interne');
```

### Secrets des Edge Functions
Dans **Edge Functions > Secrets**, ajoute :

| Secret | Valeur |
|---|---|
| `MISTRAL_API_KEY` | clé API Mistral (plan Experiment en développement, payant au lancement) |
| `CLE_INTERNE` | **la même** clé interne que dans le Vault |
| `CANDIDATS_CSV_URL` | URL stable du CSV du jeu de données data.gouv.fr (voir section 5) |
| `MISTRAL_MODELE` | facultatif, `mistral-small-latest` par défaut |
| `ORIGINE_AUTORISEE` | facultatif, URL du site Netlify (CORS du chatbot) |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` et `SUPABASE_SERVICE_ROLE_KEY` sont fournies automatiquement aux fonctions.

### Déployer les 4 fonctions
**Edge Functions > Deploy a new function > Via Editor** : donne à chaque fonction **exactement** le nom de son dossier, colle son `index.ts`, puis déploie.

| Fonction | Verify JWT | Appelée par |
|---|---|---|
| `importer-rss` | **désactivé** | pg_cron, chaque jour à 5 h 10 UTC |
| `analyser-article` | **désactivé** | trigger pg_net (sélection par un éditeur) |
| `maj-sources` | **désactivé** | pg_cron, chaque lundi à 4 h 40 UTC |
| `chatbot` | activé | le front, avec la session anonyme |

Pour les trois premières, désactive « Enforce JWT verification » dans les réglages de la fonction. C'est l'en-tête `x-cle-interne` qui les protège, et elles refusent toute requête sans la bonne clé.

Avec la CLI, `supabase functions deploy` lit ces réglages dans `supabase/config.toml`.

## 4. Premiers tests

```sql
-- Lancer un import tout de suite (sans attendre le cron)
select public.appeler_edge_function('importer-rss');

-- Réponse HTTP des derniers appels (202 = lancé, 401 = clé interne différente)
select id, status_code, content from net._http_response order by id desc limit 5;

-- Combien d'articles importés, par média
select m.nom, count(a.id) from public.medias m
  left join public.articles a on a.media_id = m.id group by m.nom order by m.nom;

-- Lancer la mise à jour des sources et des candidats
select public.appeler_edge_function('maj-sources');
```

Le rapport détaillé de chaque exécution s'affiche dans **Edge Functions > (fonction) > Logs**.

Pour analyser un article : `update public.articles set statut = 'en_attente' where id = ...;` (en tant qu'éditeur, depuis l'app, ou dans le SQL Editor).

### À compléter dans la base
Les flux n'ont pas pu être testés depuis l'environnement de développement. Vérifie-les avec la requête « par média » ci-dessus et les logs :
- **Médias sans flux** : CNews et Ouest-France. Tant qu'ils ne sont pas renseignés, ces médias ne sont pas importés, et la règle « même traitement pour tous » n'est donc pas encore respectée.
  ```sql
  update public.medias set flux_rss_url = 'https://...' where nom = 'CNews';
  ```
- **Organismes sans flux** (`organismes.flux_url`) : seuls Les Décodeurs, Vrai ou faux et Les Surligneurs sont renseignés. Ajoute les flux RSS officiels de l'INSEE, de vie-publique.fr, de la Cour des comptes, etc. Sans sources institutionnelles, la plupart des verdicts seront « non vérifiable », ce qui est voulu : rien n'est inventé.

### Atteindre 500 lignes dans `articles`
Un flux RSS ne contient que les derniers articles, environ 20 à 50. Avec 7 flux, le premier import donne donc à peu près 150 à 300 articles, puis chaque import quotidien n'ajoute que les nouveautés. Il faut compter quelques jours pour atteindre 500. Pour aller plus vite, lance `importer-rss` plusieurs fois par jour, et renseigne les flux de CNews et d'Ouest-France.

## 5. Candidats (data.gouv.fr)
1. Sur data.gouv.fr, ouvre le jeu de données « Candidatures à l'élection présidentielle 2027 — statuts sourcés ».
2. Copie l'URL stable de la ressource CSV et mets-la dans le secret `CANDIDATS_CSV_URL`.
3. Lance `select public.appeler_edge_function('maj-sources');`.

`maj-sources` repère les colonnes par leur nom (`nom`, `prénom`, `parti` ou `formation`, `statut`, `source`), puis met à jour la table `candidats` chaque semaine. Si une colonne n'est pas reconnue, les logs affichent la liste des colonnes du fichier.

## 6. Côté front (rappel)
- Lecture sans compte : `supabase.from('affirmations_publiques').select('*')`.
- Chatbot : d'abord `supabase.auth.signInAnonymously({ options: { captchaToken } })` (token Turnstile), puis `supabase.functions.invoke('chatbot', { body: { question } })`. La réponse contient `reponse`, `sources` et `questions_restantes` ; le code 429 signifie que le quota du jour est atteint.
- Signalement : `supabase.from('signalements').insert({ affirmation_id, motif })` avec la session anonyme.
- Ne jamais mettre la clé `service_role` dans le front.

## 7. Garde-fous à présenter
- **Pas de verdict inventé** : si l'IA ne cite pas assez de sources pour son verdict, la fonction le ramène à « non vérifiable ». Et dans tous les cas, le trigger 6.3 refuse la publication.
- **Pas de fausse citation** : une affirmation n'est gardée que si elle figure mot pour mot dans l'article.
- **Droit voisin** : le texte de l'article est lu en mémoire puis oublié. On ne stocke que l'URL, le titre, une citation de 400 caractères maximum et un résumé rédigé par l'IA. Les articles payants (`isAccessibleForFree: false`) sont marqués `inaccessible` et ne sont pas analysés.
- **Neutralité** : même plafond d'import et d'analyse pour chaque média, et mêmes consignes pour tous les candidats. Aucun « qui ça avantage ».
- **RGPD** : aucune opinion n'est demandée, et les conversations sont supprimées après 30 jours.
- **Cadre légal** : le référé de l'article L163-2 du code électoral (loi de 2018 sur la manipulation de l'information) s'applique à partir du 1er janvier 2027 pour ce scrutin.

## 8. Limites gratuites
- Edge Functions : 150 s par appel (les fonctions répondent tout de suite, puis travaillent en tâche de fond) et 2 s de calcul CPU (les parseurs RSS et HTML sont volontairement légers).
- Mistral, plan gratuit : environ 1 requête par seconde. Les fonctions réessaient automatiquement en cas d'erreur 429.
- Supabase : 500 Mo de base, et le projet est mis en pause après 7 jours d'inactivité.

## 9. Tests de la migration en local
`supabase/tests/lancer_tests.sh` lance un Postgres 16 jetable, simule ce que fournit Supabase (auth, Vault, pg_net, pg_cron, vector) et vérifie : la sélection, l'appel pg_net, le quota par média, la relance, les droits d'exécution et les règles de publication. Postgres refuse de s'exécuter en root : sous Linux, lance le script avec un utilisateur non root.
