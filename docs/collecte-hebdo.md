# Collecte hebdomadaire des articles

Le script `collecte/collecte.mjs`, lancé par le workflow `.github/workflows/collecte-hebdo.yml`, récupère chaque lundi à 9 h (heure de Paris) les nouveaux articles politiques des flux RSS listés dans `collecte/flux.json`.

- **Indépendante du fact-checking** : aucun appel à Claude. Les nouveaux articles arrivent en `non_traite` (non vérifiés).
- **Médias et organismes séparés** : le média d'origine va dans `contenus.media_nom`. La table `sources` (les 15 organismes de preuve) n'est jamais modifiée.
- **Droit voisin** : seuls le titre, le lien canonique, la date et le média sont conservés.
- **Dédoublonnage** : par URL canonique (débarrassée des paramètres `utm_`, `xtor`… et de l'ancre) et par couple (domaine, identifiant du flux).
- **Rien n'est supprimé** : un article déjà connu garde son titre et sa date de collecte ; seul `vu_le` est mis à jour.
- **Données fictives exclues** : le rôle `demelo_pipeline` ne peut ni en créer ni en voir, et les liens `.invalid` sont ignorés.
- **Suivi** : `date_collecte` (première vue), `vu_le` (dernière vue), `lot_import` (`rss-AAAA-MM-JJ`) et un rapport par flux (lus, retenus, nouveaux, déjà connus, erreur). Le rapport est affiché dans le résumé du job et conservé 90 jours en artefact.
- **Moindre privilège** : le script refuse tout autre rôle que `demelo_pipeline`, qui n'a aucun droit de suppression. Il n'utilise pas la clé `service_role`, et aucune clé n'apparaît dans le front.
- **Erreurs** : un flux en erreur (HTTP, XML invalide) n'arrête pas les autres. Le job échoue seulement si **tous** les flux échouent.

## Mise en route (dans l'ordre)
1. 🔒 **Appliquer la migration `v2_05`** (pipeline IA). Elle est nécessaire, car c'est elle qui ajoute `media_nom`, rend `source_id` facultatif et crée le rôle `demelo_pipeline`.
2. 🔒 **Activer la connexion du rôle**, dans le SQL Editor, par un membre de l'équipe. Utilisez un mot de passe long et aléatoire, et n'enregistrez pas la requête comme snippet :
   ```sql
   alter role demelo_pipeline with login password 'MOT_DE_PASSE_ALEATOIRE';
   ```
3. **Préparer la chaîne de connexion.** Dans **Connect > Session pooler**, copiez la chaîne et remplacez l'utilisateur `postgres.<ref>` par `demelo_pipeline.<ref>`, sans `sslmode`. Par exemple : `postgresql://demelo_pipeline.aoysmqeasnfnyvmfwktt:MDP@<hôte-du-pooler>:5432/postgres`.
4. **Récupérer le certificat** : **Database Settings > SSL Configuration > Download certificate**.
5. 🔒 **Créer les secrets GitHub** (Settings > Secrets and variables > Actions) : `DEMELO_DATABASE_URL` (étape 3) et `DEMELO_DB_CA` (contenu du certificat). ⚠ **Le dépôt est public** : les secrets ne doivent jamais se trouver dans un fichier.
6. 🔒 **Fusionner la branche dans `main`.** GitHub n'exécute une tâche planifiée que si le workflow est sur la branche par défaut (`main`), ce qui n'est pas encore le cas.
7. **Premier test réel** : **Actions > Collecte hebdomadaire des articles > Run workflow**.
   - D'abord en mode `essai` : les flux sont lus, rien n'est écrit. On vérifie ainsi quels flux répondent réellement.
   - Ensuite en mode `collecte`.
   - Si un flux de `flux.json` ne répond pas, on le corrige ou on le retire.

## Planification
Le cron de GitHub est en UTC, et 9 h à Paris correspond à 8 h UTC en hiver et à 7 h UTC en été. Le workflow se déclenche donc aux deux horaires, puis une première étape ne garde que l'exécution qui tombe à 9 h à Paris. GitHub peut retarder une tâche planifiée de quelques minutes.

## Indicateur « dernière mise à jour » (pour le site)
Il n'y a rien à créer : la RLS publique (P4) laisse lire `vu_le` sur les articles réels visibles.
```
GET /rest/v1/contenus?select=vu_le&order=vu_le.desc&limit=1
```
Pour le détail par flux et les erreurs : le résumé du job dans l'onglet Actions, ou l'artefact `rapport-collecte`.

## Tests
- `collecte/tests/test_local.sh` : exécution réelle et contrôlée, avec un vrai Postgres local (schéma complet et rôle `demelo_pipeline`) et un vrai serveur HTTP de flux. Il fait deux collectes successives et 11 contrôles : rôle trop puissant refusé, dédoublonnage, URL canonique, aucune suppression, données fictives intactes, erreurs tracées, aucune affirmation créée.
- Les vrais flux des médias n'ont pas pu être joints depuis l'environnement de développement (réseau restreint) : **leur accessibilité sera vérifiée par la première exécution en mode `essai`** sur GitHub Actions.
