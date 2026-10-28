# Spécification du pipeline de fact-checking IA (Claude)

> **Statut : spécification, pipeline non développé.** Aucun appel à l'API Claude n'a été lancé. Les capacités, versions et prix ci-dessous viennent de la documentation officielle Anthropic, consultée le 28/10/2026 : pages *Web search tool*, *Web fetch tool*, *Server tools* et *Pricing* sur platform.claude.com. À revérifier avant le développement.

## 1. Principes
1. **Claude lit, cherche et rédige ; il ne prouve rien.** Une preuve est un document que **notre code** a téléchargé et contrôlé : URL finale, statut HTTP, domaine, empreinte, et passage retrouvé mot pour mot.
2. **Une absence de preuve donne une abstention (`verification_insuffisante`), jamais un verdict.**
3. **Les médias ne sont jamais des preuves.** Les 15 organismes de `sources` sont les seuls admis, et ni Claude ni le code ne peuvent en ajouter.
4. **La base a le dernier mot sur la publication** : triggers de `v2_05`. Elle garantit l'intégrité, pas la vérité : chaque fiche affiche ses limites et la mention « Analyse produite par IA ».
5. **Le texte des articles n'est jamais stocké** (droit voisin) : il est lu en mémoire, puis seules la citation (400 caractères au plus) et les métadonnées sont gardées.

## 2. Ce que fournit chaque outil Anthropic

| Besoin | Claude Code | Application déployée (API Anthropic) |
|---|---|---|
| Écrire le code du projet | ✅ (abonnement Claude Code) | — |
| Analyse, extraction, rédaction | — | API Messages, modèle `claude-opus-5-5` par défaut |
| Recherche web | Outil WebSearch de Claude Code, **pour le développement seulement** | Outil serveur `web_search_20260318` |
| Consultation de pages et PDF | Outil WebFetch de Claude Code, **pour le développement seulement** | Outil serveur `web_fetch_20260318` |
| Facturation | Abonnement Claude Code | **Séparée** : compte Console, clé API, crédits prépayés. **L'abonnement Claude Code n'inclut pas les appels API de l'application** |

### Faits vérifiés dans la documentation
- **Versions.** `web_search_20260318` et `web_fetch_20260318` sont les dernières. Elles intègrent le *dynamic filtering* (Claude filtre les résultats par du code avant de les lire), disponible pour les modèles Claude 4.6 et suivants, donc pour Opus 5.5 et Sonnet 5.5. Les versions `_20260209` restent disponibles.
- **Domaines.**
  - `allowed_domains` ou `blocked_domains`, jamais les deux ; les domaines s'écrivent sans `https://`.
  - Les sous-domaines sont inclus automatiquement.
  - **Les chemins (`ec.europa.eu/eurostat`) ne fonctionnent que pour web search** : web fetch filtre sur le domaine seul. Pour Eurostat (`ec.europa.eu`) et le SSMSI (`interieur.gouv.fr`), le fetch est donc plus large que le périmètre, et **la base revérifie le chemin** (`prive.url_dans_perimetre`).
- **Web fetch.**
  - Il ne récupère que des URL **déjà présentes dans la conversation** (message, résultat de recherche), ce qui interdit à Claude d'inventer une adresse et de la consulter.
  - Il gère le texte, le HTML et le PDF, **mais pas les sites rendus en JavaScript**.
  - Ses résultats peuvent être servis depuis un cache ; `use_cache: false` force une lecture fraîche.
  - `citations: {enabled: true}` renvoie les passages cités.
  - `max_uses` n'a pas de limite par défaut, et les échecs comptent dans ce plafond.
- **Erreurs.** Une erreur d'outil (`url_not_accessible`, `max_uses_exceeded`…) arrive en HTTP 200, dans un bloc de résultat : il faut les lire explicitement. Une boucle serveur longue se termine par `stop_reason: "pause_turn"` et doit être relancée.
- **Administration.** La recherche web doit être **activée pour l'organisation** dans la Console (Settings > Capabilities) ; sinon la requête renvoie une erreur 400.
- **Conservation des données.** Avec le *dynamic filtering*, les outils ne sont pas éligibles au Zero Data Retention par défaut, ce qui est sans conséquence ici. Aucune donnée d'utilisateur n'est envoyée.

### Prix (API Claude, 28/10/2026)
| Élément | Prix |
|---|---|
| `claude-opus-5-5` | 4 $ par million de jetons en entrée, 20 $ en sortie (lecture de cache : 0,20 $) |
| `claude-sonnet-5-5` (option moins chère, à décider par l'équipe) | 2 $ / 10 $ |
| Web search | **10 $ pour 1 000 recherches**, plus les jetons des résultats |
| Web fetch | **Aucun supplément**, seulement les jetons du contenu récupéré |
| Exécution de code du *dynamic filtering* | Gratuite avec web search ou web fetch |
| API Batch (optionnelle) | −50 % sur les jetons ; recherche web au même prix |

**Estimation à mesurer**, ce n'est pas une garantie. Pour une affirmation : environ 4 recherches (0,04 $), 40 000 à 80 000 jetons de documents lus et 4 000 jetons produits, soit **0,20 à 0,45 $ avec Opus 5.5**. L'extraction d'un article coûte environ 0,03 $. Les **3 à 5 vérifications de la démonstration** coûteraient donc **2 à 5 $**, essais compris. Analyser tout le flux n'est pas prévu.

## 3. Schéma des flux

```
 Flux RSS des médias ──► [script d'import] ──insert──► contenus (non_traite)      ◄── données fictives (admin, est_test)
                                                         │   jamais lues par le pipeline
                                                         ▼
 ┌──────────────────────────── pipeline (Node/TypeScript, rôle Postgres demelo_pipeline) ───────────────────────────┐
 │ 1. Télécharge l'article (accès libre) ── texte en mémoire seulement                                               │
 │ 2. Claude R1 (sans outil, sortie JSON) : affirmations + citation exacte + nature + sensibilité + motif            │
 │    └─ code : citation retrouvée mot pour mot ? → citation_verifiee ; sinon rejet                                  │
 │ 3. insert affirmations (non_traite) → en_cours                                                                    │
 │ 4. Claude R2 + web_search (allowed_domains = 15 périmètres) + web_fetch (domaines, citations)                     │
 │    └─ code : collecte les URL réellement consultées dans les blocs web_fetch_tool_result                          │
 │ 5. Code : retéléchargement indépendant de chaque URL → statut, URL finale, type, titre, date, sha256, texte       │
 │    └─ hors périmètre / inaccessible / PDF illisible → preuve « inaccessible » ou « rejetee » avec motif           │
 │ 6. Claude R3 (sans outil, sortie JSON) sur les SEULS documents vérifiés : passages, relation, nature, recoupement  │
 │    └─ code : passage retrouvé mot pour mot dans NOTRE téléchargement ? sinon preuve rejetée                       │
 │ 7. Code : règles de décision (section 5) → verdict, abstention ou revue                                           │
 │ 8. insert preuves + update affirmation → TRIGGERS BLOQUANTS (dernier mot)                                         │
 └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
                                                         │
          analyse_disponible / verification_insuffisante ▼ revue_requise ──► administrateur (motif obligatoire)
                                                    v_analyses_publiques ──► site (clé publique + RLS manuelles)
```

**Pourquoi un retéléchargement par notre code (étape 5) ?** Le cahier des charges impose des vérifications déterministes, et le résultat de web fetch peut venir d'un cache ou être filtré par Claude. Ce téléchargement n'est ni de l'IA ni de la recherche : c'est une requête HTTP de contrôle. Si l'équipe refuse toute requête hors Anthropic, on peut vérifier à la place sur le document renvoyé par web fetch (`use_cache: false`), mais la vérification devient moins indépendante.

## 4. Les trois appels à Claude

| Appel | Entrée | Outils | Sortie | Réglages |
|---|---|---|---|---|
| **R1 Extraction** | Texte de l'article (notre téléchargement), média, date | aucun | JSON strict (`output_config.format`) : citation, contexte, nature (`factuel` / `opinion` / `promesse` / `prevision`), thème, motif de sélection, score de priorité, sensible et motif | effort `medium` |
| **R2 Recherche** | Affirmation, contexte, date, liste des 15 organismes et de leurs domaines | `web_search_20260318` (`allowed_domains` avec les chemins, `max_uses` 5, `user_location` FR) ; `web_fetch_20260318` (`allowed_domains` en domaines seuls, `max_uses` 6, `citations` activées, `max_content_tokens` 30 000, `use_cache` false) | Texte et blocs d'outils : on n'en garde que les **URL réellement consultées** | effort `medium`, gestion de `pause_turn` |
| **R3 Analyse** | Affirmation, et **uniquement** les documents vérifiés à l'étape 5 (texte issu de notre téléchargement, avec leur identifiant) | aucun | JSON strict : pour chaque preuve, passage exact, relation, nature et justification ; recoupement (période, définition, unité, population, périmètre, contradictions, dépendances) ; verdict **ou** motif d'abstention ; explication accessible ; limites | effort `high` |

- Les citations de web search et web fetch sont incompatibles avec la sortie JSON stricte : c'est pourquoi la recherche (R2) et l'analyse (R3) sont deux appels séparés.
- **Modèle enregistré** : `modele_ia` prend la valeur de `response.model`, et non celle de la configuration, pour tracer un éventuel repli. Les champs `version_prompt` (par exemple `r1-v1+r2-v1+r3-v1`) et `id_execution` sont tous deux enregistrés.
- **Refus** : si `stop_reason` vaut `"refusal"`, l'affirmation passe en abstention avec le motif « analyse refusée par le modèle ». Le repli côté serveur (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`) est activé par défaut lors du développement, et le modèle réellement utilisé est tracé.
- **Contenu non fiable** : le texte des articles et des pages consultées est une **donnée**, jamais une instruction. Le prompt système le dit explicitement, et toutes les vérifications de l'étape 5 sont faites par du code.

## 5. Vérification et décision

### 5.1 Contrôles techniques (code déterministe), par document
| Contrôle | Règle | Si le contrôle échoue |
|---|---|---|
| Domaine | URL d'origine **et** URL finale dans le périmètre de l'organisme (la base le revérifie) | `rejetee` |
| Accessibilité | HTTP 2xx, type `text/html`, `text/plain` ou `application/pdf` | `inaccessible` (code HTTP et motif) |
| Identité | Le titre et le domaine correspondent à l'organisme | `rejetee` |
| Date ou version | Date ou version extraite des métadonnées ; elle doit être cohérente avec la période de l'affirmation | `rejetee` ou abstention |
| Empreinte | sha256 du texte extrait, conservée | — |
| Passage | Retrouvé **mot pour mot**, après normalisation des espaces et des apostrophes, dans notre téléchargement | `rejetee` |
| PDF et tableaux | Texte extrait de façon fiable, sinon rien | `rejetee` (« extraction non fiable ») |

Les échecs sont **enregistrés** (`statut_preuve` = `inaccessible` ou `rejetee`, avec `motif_rejet`). Ils restent visibles par l'équipe, jamais par le public.

### 5.2 Recoupement (R3, puis contrôle par le code)
- **Comparer et pas seulement compter** : période, définition (par exemple chômage BIT ou catégorie A), unité, population, périmètre géographique, contexte.
- **Dépendances** : une preuve qui reprend la donnée d'une autre est liée par `reprend_preuve_id` et ne compte pas comme indépendante. Par exemple, Vie-publique qui cite l'INSEE.
- **Nature évaluée par affirmation** : primaire ou secondaire selon le rôle du document pour *cette* affirmation, avec justification. AFP Factuel et Vie-publique sont en général secondaires.

### 5.3 Règles de décision
Le code applique ces règles avant écriture, et la base les revérifie.

| Situation | Décision |
|---|---|
| Opinion, promesse ou prévision | `non_verifiable`, avec explication ; aucune preuve exigée |
| Aucune preuve vérifiée, ou uniquement des preuves secondaires | `verification_insuffisante` |
| Preuves contradictoires sans lecture « trompeur » défendable, ou périodes, définitions ou périmètres non comparables | `verification_insuffisante` |
| `vrai` | Au moins une preuve primaire indépendante qui confirme, et aucune preuve vérifiée qui contredit |
| `faux` | Au moins une preuve primaire indépendante qui contredit, et aucune qui confirme |
| `trompeur` | Une preuve qui confirme et une qui contextualise ou contredit, dont au moins une primaire |
| Cas sensible | `revue_requise` (jamais de publication directe) |
| Refus du modèle, JSON invalide, référence à une preuve inconnue | `verification_insuffisante` ou nouvelle tentative ; rien n'est deviné |

Ces seuils sont des **minima d'intégrité**. Le verdict lui-même vient de l'adéquation analysée en R3 : la présence d'une preuve primaire ne suffit jamais à conclure.

### 5.4 Cas sensibles (revue exceptionnelle)
Un cas est sensible si R1 le signale, **ou** si une liste déterministe de motifs le repère (condamnation, mise en examen, fraude, violences, terrorisme, santé ou vie privée d'une personne nommée, origine ou religion), **ou** s'il s'agit d'un verdict `faux` visant un candidat déclaré à partir du 1er janvier 2027 (référé de l'article L163-2 du code électoral).

Il passe alors en `revue_requise`. Un administrateur publie, écarte ou retire, avec un motif obligatoire qui est archivé dans `historique`.

## 6. Exemple : le parcours d'une affirmation
1. **Import.** L'article de franceinfo « Chômage des jeunes… » est inséré avec `media_nom` franceinfo, `source_id` vide et le statut `non_traite`.
2. **Extraction (R1).** « Le chômage des 15-24 ans atteint 18 % au deuxième trimestre. » La citation est retrouvée dans l'article, donc `citation_verifiee` vaut vrai. L'affirmation est classée `factuel` et non sensible.
3. **Recherche (R2).** Claude cherche sur `insee.fr`, `dares.travail-emploi.gouv.fr`… et consulte 3 pages.
4. **Contrôles (étape 5).**
   - INSEE : HTTP 200, dans le périmètre, passage retrouvé : **vérifiée**.
   - DARES : HTTP 404 : **inaccessible**.
   - AFP Factuel : vérifiée et reprend l'INSEE, donc `reprend_preuve_id` pointe sur la preuve INSEE et elle est secondaire.
5. **Analyse (R3).** Même trimestre, même définition (BIT), même population. Verdict proposé : `vrai`, avec la limite « chiffre provisoire ».
6. **Écriture.** La base vérifie la preuve primaire vérifiée qui confirme, l'absence de contradiction, un recoupement complet, l'explication, les limites et le modèle, puis accepte `analyse_disponible`.
7. **Site.** La fiche affiche l'affirmation, le verdict, l'explication, la preuve INSEE, les limites, la date, le modèle et la mention « Analyse produite par IA ».
8. **Correction.** Si l'INSEE révise son chiffre, un administrateur renvoie l'analyse en `non_traite` avec un motif. Elle passe en version 2, l'ancienne analyse reste dans `historique` et les anciennes preuves sont conservées.

## 7. Données : 500 lignes
- **Articles réels** : 50 à 100 environ, importés par flux RSS, avec le rôle pipeline et dédupliqués par URL et par couple (domaine, GUID).
- **Complément fictif** jusqu'à 500, inséré par un administrateur. Chaque ligne a `est_test = true`, un titre `[FICTIF] …`, un domaine `*.invalid` et un média « Média fictif… », sans rattachement à un organisme ; **la base refuse toute autre forme**. Ces lignes sont invisibles pour le public et le pipeline, et aucune affirmation n'est possible sur elles.
- **3 à 5 vraies vérifications** pour la démonstration, sur des articles réels. Elles sont relues par l'équipe à titre d'audit, même si ce n'est pas obligatoire.

## 8. Actualisation hebdomadaire (préparée, non activée)
- **Exécution** : GitHub Actions, planification hebdomadaire `cron`, **désactivée** pour le MVP. Elle lancera le script d'import, puis le pipeline sur N nouveaux articles au plus.
- **Déduplication** : par `url_originale` (unique) et par couple (`domaine_origine`, `identifiant_externe`) ; `vu_le` est mis à jour à chaque passage.
- **Conservation** : rien n'est supprimé, les anciennes analyses restent avec leur version.
- **Nouveautés et traitement progressif** : `statut_traitement = 'non_traite'`, avec une limite par exécution.
- **Erreurs** : `contenus.statut_traitement = 'erreur'` et `derniere_erreur` par article ; les erreurs de flux vont dans les journaux du job. Il n'y a pas de 5e table : la liste des flux est un fichier de configuration du script.

## 9. Sécurité côté serveur
- **Rôle `demelo_pipeline`** : lecture des organismes et des articles réels ; ajout d'articles ; écriture des analyses et des preuves ; **aucune suppression**, aucun accès à `auth`, à `archive_v1` ni aux données fictives. La RLS s'applique à lui : il n'a pas `BYPASSRLS`.
- **Connexion** : un administrateur active le rôle dans le SQL Editor avec `alter role demelo_pipeline login password '…'`. Le mot de passe n'est jamais versionné. Le pipeline se connecte ensuite par la chaîne Postgres (pooler) ; **à vérifier lors de l'activation : la connexion d'un rôle personnalisé par le pooler Supabase**.
- **Secrets** (`ANTHROPIC_API_KEY`, chaîne de connexion du pipeline) : dans un `.env` local ignoré par git, puis dans les secrets GitHub Actions. Ils ne vont jamais dans le front ni dans le dépôt.
- **La clé `service_role` n'est pas utilisée par le pipeline.**

## 10. Dépendances prévues (pipeline, hors front)
- `@anthropic-ai/sdk` : API Claude.
- `pg` : connexion Postgres avec le rôle pipeline.
- Une bibliothèque d'extraction de texte PDF (à choisir au développement), sinon abstention sur les PDF.
- Aucun framework agentique, aucune vectorisation, aucun RAG, aucune file de messages.

## 11. Limites et problèmes non résolus
1. **Sites rendus en JavaScript** (certaines pages Eurostat, tableaux de données) : web fetch ne les lit pas. Il faut chercher la version HTML ou PDF de la publication, sinon s'abstenir.
2. **PDF et tableaux** : l'extraction de chiffres reste fragile, et l'abstention sera fréquente.
3. **Couverture de la recherche** : les résultats de web search sur des sites officiels français peuvent être pauvres, ce qui donnera un taux d'abstention élevé au début. C'est attendu.
4. **Périmètres larges** : `sgdsn.gouv.fr` (Viginum) et `factuel.afp.com` sont acceptés en entier.
5. **Pooler Supabase et rôle personnalisé** : à tester avant la démonstration. En secours, connexion directe.
6. **Coûts réels** : à mesurer sur 1 ou 2 affirmations avant tout traitement plus large, avec l'accord de l'équipe pour chaque appel payant.
7. **Juridique** : droit voisin (aucun texte d'article stocké), loi de 2018 pendant la campagne, affirmations sur des personnes.
8. **La vérité n'est pas garantie.** La base garantit l'intégrité, pas la justesse : d'où les limites affichées, la mention IA, l'abstention et la possibilité de retrait.
