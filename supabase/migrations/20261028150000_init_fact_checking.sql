-- =====================================================================
--  Fact-checking présidentielle 2027 — migration initiale Supabase
-- =====================================================================
--  Principes
--  * Lecture publique sans compte (rôle `anon`) des vérifications publiées.
--  * Signalements et chatbot via la connexion anonyme Supabase : le visiteur
--    a le rôle `authenticated` avec le claim `is_anonymous = true`.
--  * L'IA (Edge Functions Supabase) écrit avec la clé `service_role`, qui
--    contourne la RLS. Cette clé ne doit JAMAIS se trouver dans le front.
--  * Les règles critiques sont dans la base, sous forme de triggers. Un
--    trigger s'applique à tout le monde, y compris `service_role`, alors que
--    la RLS, elle, est contournée par cette clé.
--
--  Deux couches de sécurité, à ne pas confondre :
--  1. GRANT : quelles ACTIONS un rôle peut tenter sur une table.
--  2. RLS   : sur quelles LIGNES cette action est autorisée.
--  RLS activée sans aucune policy = tout est refusé (fermé par défaut).
--
--  Edge Functions appelées par la base (pg_net), voir docs/mise-en-place.md :
--  * importer-rss     : chaque jour, importe les articles des flux RSS (statut 'importe').
--  * analyser-article : quand un éditeur passe un article en 'en_attente'.
--  * maj-sources      : chaque semaine, sources officielles + embeddings + candidats.
--  * chatbot          : appelée directement par le front (session anonyme).
--  L'URL du projet et la clé interne d'appel sont lues dans le Vault.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Extensions
-- ---------------------------------------------------------------------
create extension if not exists vector with schema extensions;
-- Appels HTTP sortants depuis la base (triggers et tâches planifiées).
-- Si cette ligne échoue, active pg_net dans le dashboard (Database > Extensions).
create extension if not exists pg_net with schema extensions;


-- ---------------------------------------------------------------------
-- 2. Types
-- ---------------------------------------------------------------------
create type public.role_utilisateur  as enum ('viewer', 'editeur', 'admin');
-- 'importe'    : arrivé par le flux RSS, pas encore choisi pour l'analyse.
-- 'en_attente' : choisi par un éditeur, l'analyse IA est demandée (voir 6.6).
create type public.statut_article     as enum ('importe', 'en_attente', 'en_cours', 'traite', 'inaccessible', 'erreur');
create type public.statut_affirmation as enum ('brouillon', 'publie', 'a_verifier', 'retire');
create type public.auteur_message     as enum ('utilisateur', 'assistant');
create type public.type_organisme     as enum ('statistique', 'juridique', 'institution', 'fact_checking', 'securite_information');
-- 'lien_seulement' : contenu sous licence (AFP, presse) -> on stocke le titre et le lien, jamais le texte.
create type public.reutilisation      as enum ('ouverte', 'lien_seulement');


-- ---------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------

-- Rôle applicatif de chaque utilisateur (créé automatiquement, voir trigger).
create table public.profils (
  id         uuid primary key references auth.users (id) on delete cascade,
  role       public.role_utilisateur not null default 'viewer',
  created_at timestamptz not null default now()
);

-- Réglages métier : rien n'est codé en dur dans les fonctions.
create table public.parametres (
  cle         text primary key,
  valeur      integer not null check (valeur >= 0),
  description text not null
);

-- Échelle des verdicts et nombre minimum de sources exigé pour chacun.
create table public.verdicts (
  code        text primary key,
  libelle     text not null,
  description text not null,
  sources_min integer not null check (sources_min >= 0),
  ordre       integer not null
);

create table public.medias (
  id           bigint generated always as identity primary key,
  nom          text not null unique,
  site_url     text not null,
  flux_rss_url text,
  created_at   timestamptz not null default now()
);

-- Liste blanche des organismes fiables. Une source ne peut venir que d'ici.
-- flux_url : flux RSS/Atom officiel lu chaque semaine par maj-sources.
create table public.organismes (
  id            bigint generated always as identity primary key,
  nom           text not null unique,
  site_url      text not null,
  type          public.type_organisme not null,
  reutilisation public.reutilisation not null,
  flux_url      text check (flux_url ~* '^https?://'),
  actif         boolean not null default true,
  created_at    timestamptz not null default now()
);

-- Documents de référence, mis à jour chaque semaine par maj-sources.
-- embedding : 1024 dimensions = modèle mistral-embed. À adapter si autre modèle.
create table public.sources (
  id            bigint generated always as identity primary key,
  organisme_id  bigint not null references public.organismes (id) on delete restrict,
  titre         text not null,
  url           text not null unique check (url ~* '^https?://'),
  extrait       text,
  embedding     extensions.vector(1024),
  publie_le     date,
  mis_a_jour_le timestamptz not null default now(),
  created_at    timestamptz not null default now()
);

-- Alimentée chaque semaine par maj-sources depuis le jeu de données data.gouv.fr
-- « Candidatures à l'élection présidentielle 2027 — statuts sourcés ».
create table public.candidats (
  id                  bigint generated always as identity primary key,
  nom                 text not null unique,
  parti               text,
  statut_candidature  text,
  source_url          text,
  created_at          timestamptz not null default now()
);

-- Métadonnées d'articles en accès libre. Jamais le texte intégral (droit voisin).
create table public.articles (
  id                  bigint generated always as identity primary key,
  media_id            bigint not null references public.medias (id) on delete restrict,
  url                 text not null unique check (url ~* '^https?://'),
  titre               text not null,
  resume              text check (char_length(resume) <= 600),
  publie_le           timestamptz,
  ajoute_par          uuid references public.profils (id) on delete set null,
  statut              public.statut_article not null default 'en_attente',
  -- Rempli par le trigger 6.6 quand l'analyse est demandée.
  analyse_demandee_le timestamptz,
  created_at          timestamptz not null default now()
);

-- Une affirmation = une courte citation extraite d'un article + son verdict.
-- La limite de 400 caractères garde la citation dans le cadre de la courte citation.
create table public.affirmations (
  id              bigint generated always as identity primary key,
  article_id      bigint not null references public.articles (id) on delete cascade,
  citation        text not null check (char_length(citation) between 10 and 400),
  verdict         text not null default 'non_verifiable' references public.verdicts (code),
  explication     text not null,
  statut          public.statut_affirmation not null default 'brouillon',
  -- Signalements reçus depuis la dernière publication ou validation.
  nb_signalements integer not null default 0,
  publie_le       timestamptz,
  created_at      timestamptz not null default now()
);

-- Preuves : quelles sources justifient quel verdict.
create table public.affirmation_sources (
  affirmation_id bigint not null references public.affirmations (id) on delete cascade,
  source_id      bigint not null references public.sources (id) on delete restrict,
  primary key (affirmation_id, source_id)
);

-- Candidats concernés par une affirmation (fait, pas intention).
create table public.affirmation_candidats (
  affirmation_id bigint not null references public.affirmations (id) on delete cascade,
  candidat_id    bigint not null references public.candidats (id) on delete restrict,
  primary key (affirmation_id, candidat_id)
);

-- Un seul signalement par visiteur et par affirmation.
create table public.signalements (
  id             bigint generated always as identity primary key,
  affirmation_id bigint not null references public.affirmations (id) on delete cascade,
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  motif          text check (char_length(motif) <= 500),
  created_at     timestamptz not null default now(),
  unique (affirmation_id, user_id)
);

-- Historique du chatbot, supprimé automatiquement (voir section 12).
create table public.messages (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  auteur     public.auteur_message not null default 'utilisateur',
  contenu    text not null,
  created_at timestamptz not null default now(),
  check (
    (auteur = 'utilisateur' and char_length(contenu) between 1 and 1000)
    or (auteur = 'assistant' and char_length(contenu) between 1 and 8000)
  )
);


-- ---------------------------------------------------------------------
-- 4. Index
-- ---------------------------------------------------------------------
create index on public.sources (organisme_id);
create index on public.sources using hnsw (embedding extensions.vector_cosine_ops);
create index on public.articles (media_id);
create index on public.articles (statut);
create index on public.articles (media_id, analyse_demandee_le);
create index on public.affirmations (article_id);
create index on public.affirmations (statut);
create index on public.affirmation_sources (source_id);
create index on public.affirmation_candidats (candidat_id);
create index on public.messages (user_id, created_at);
create index on public.messages (created_at) where auteur = 'utilisateur';


-- ---------------------------------------------------------------------
-- 5. Fonctions d'aide pour la RLS
-- ---------------------------------------------------------------------
-- Toutes les fonctions fixent search_path pour éviter le détournement d'objets.

create or replace function public.est_anonyme()
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
$$;

-- security definer : lit profils sans repasser par sa RLS (évite la récursion).
create or replace function public.role_courant()
returns public.role_utilisateur
language sql stable security definer
set search_path = ''
as $$
  select p.role from public.profils p where p.id = auth.uid();
$$;

-- Un visiteur anonyme n'est jamais éditeur, même si son profil le prétendait.
create or replace function public.est_editeur()
returns boolean
language sql stable
set search_path = ''
as $$
  select not public.est_anonyme()
     and coalesce(public.role_courant() in ('editeur', 'admin'), false);
$$;

create or replace function public.est_admin()
returns boolean
language sql stable
set search_path = ''
as $$
  select not public.est_anonyme()
     and coalesce(public.role_courant() = 'admin', false);
$$;


-- ---------------------------------------------------------------------
-- 6. Triggers métier
-- ---------------------------------------------------------------------

-- 6.1 Chaque nouvel utilisateur (anonyme ou non) reçoit un profil 'viewer'.
create or replace function public.creer_profil()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profils (id) values (new.id);
  return new;
end;
$$;

create trigger apres_creation_utilisateur
  after insert on auth.users
  for each row execute function public.creer_profil();


-- 6.2 Une source doit venir d'un organisme actif de la liste blanche,
--     et un organisme sous licence ne peut pas avoir d'extrait stocké.
create or replace function public.controler_source()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_actif         boolean;
  v_reutilisation public.reutilisation;
begin
  select o.actif, o.reutilisation into v_actif, v_reutilisation
    from public.organismes o where o.id = new.organisme_id;

  if not v_actif then
    raise exception 'Source refusée : l''organisme % est désactivé.', new.organisme_id
      using errcode = 'check_violation';
  end if;

  if v_reutilisation = 'lien_seulement' and new.extrait is not null then
    raise exception 'Source refusée : contenu sous licence, seuls le titre et le lien sont autorisés.'
      using errcode = 'check_violation';
  end if;

  new.mis_a_jour_le := now();
  return new;
end;
$$;

create trigger avant_ecriture_source
  before insert or update on public.sources
  for each row execute function public.controler_source();


-- 6.3 RÈGLE CENTRALE : pas de publication sans le nombre de sources exigé
--     par le verdict. C'est ce qui empêche l'IA de publier un verdict inventé.
--     Ordre d'écriture attendu côté Edge Function analyser-article :
--       1. insérer l'affirmation en 'brouillon'
--       2. insérer ses lignes dans affirmation_sources
--       3. passer le statut à 'publie'
create or replace function public.verifier_sources_avant_publication()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_min integer;
  v_nb  integer;
begin
  if new.statut = 'publie'
     and (tg_op = 'INSERT'
          or old.statut is distinct from new.statut
          or old.verdict is distinct from new.verdict) then

    select v.sources_min into v_min from public.verdicts v where v.code = new.verdict;
    select count(*) into v_nb from public.affirmation_sources s where s.affirmation_id = new.id;

    if v_nb < v_min then
      raise exception 'Publication refusée : le verdict « % » exige au moins % source(s), % liée(s).',
        new.verdict, v_min, v_nb
        using errcode = 'check_violation';
    end if;

    if new.publie_le is null then
      new.publie_le := now();
    end if;

    -- Revalidation après signalements : le compteur repart de zéro.
    if tg_op = 'UPDATE' and old.statut = 'a_verifier' then
      new.nb_signalements := 0;
    end if;
  end if;

  return new;
end;
$$;

create trigger avant_publication_affirmation
  before insert or update on public.affirmations
  for each row execute function public.verifier_sources_avant_publication();


-- 6.4 On ne peut pas retirer une preuve d'une affirmation publiée
--     si elle passe sous le minimum exigé.
create or replace function public.proteger_sources_publiees()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_statut  public.statut_affirmation;
  v_verdict text;
  v_min     integer;
  v_nb      integer;
begin
  select a.statut, a.verdict into v_statut, v_verdict
    from public.affirmations a where a.id = old.affirmation_id;

  -- Affirmation supprimée (cascade) ou non publiée : rien à protéger.
  if v_statut is distinct from 'publie' then
    return old;
  end if;

  select v.sources_min into v_min from public.verdicts v where v.code = v_verdict;
  select count(*) into v_nb from public.affirmation_sources s where s.affirmation_id = old.affirmation_id;

  if v_nb < v_min then
    raise exception 'Suppression refusée : l''affirmation % publiée tomberait à % source(s) pour % exigée(s).',
      old.affirmation_id, v_nb, v_min
      using errcode = 'check_violation';
  end if;

  return old;
end;
$$;

create trigger apres_suppression_preuve
  after delete on public.affirmation_sources
  for each row execute function public.proteger_sources_publiees();


-- 6.5 Signalements : incrémente le compteur et, au-delà du seuil,
--     repasse l'affirmation « à vérifier ». Elle reste visible avec ce statut,
--     pour qu'un groupe ne puisse pas faire disparaître une vérification gênante.
create or replace function public.traiter_signalement()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_seuil integer;
begin
  select p.valeur into v_seuil from public.parametres p where p.cle = 'seuil_signalements';

  update public.affirmations a
     set nb_signalements = a.nb_signalements + 1,
         statut = case
                    when a.statut = 'publie'
                     and v_seuil is not null
                     and a.nb_signalements + 1 >= v_seuil
                    then 'a_verifier'::public.statut_affirmation
                    else a.statut
                  end
   where a.id = new.affirmation_id;

  return new;
end;
$$;

create trigger apres_signalement
  after insert on public.signalements
  for each row execute function public.traiter_signalement();


-- 6.6 Demande d'analyse : un éditeur choisit un article (statut 'en_attente').
--     Seuls les articles choisis sont analysés, pour rester dans les limites
--     gratuites de Mistral. Règle de neutralité appliquée par la base :
--     le même nombre maximum d'analyses par média et par jour.

-- Appelle une Edge Function via pg_net. L'URL du projet et la clé interne
-- sont lues dans le Vault (secrets 'url_projet' et 'cle_interne').
-- La requête part après le COMMIT : si la transaction échoue, rien n'est envoyé.
create or replace function public.appeler_edge_function(nom text, corps jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  v_url text;
  v_cle text;
begin
  select s.decrypted_secret into v_url from vault.decrypted_secrets s where s.name = 'url_projet';
  select s.decrypted_secret into v_cle from vault.decrypted_secrets s where s.name = 'cle_interne';

  if v_url is null or v_cle is null then
    raise warning 'Edge Function % non appelée : secrets url_projet / cle_interne absents du Vault.', nom;
    return null;
  end if;

  return net.http_post(
    url                  := rtrim(v_url, '/') || '/functions/v1/' || nom,
    body                 := corps,
    headers              := jsonb_build_object('Content-Type', 'application/json', 'x-cle-interne', v_cle),
    timeout_milliseconds := 10000
  );
end;
$$;

create or replace function public.controler_demande_analyse()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_debut timestamptz := date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris';
  v_quota integer;
  v_nb    integer;
begin
  if new.statut <> 'en_attente' or (tg_op = 'UPDATE' and old.statut = 'en_attente') then
    return new;
  end if;

  -- Réanalyser un article déjà traité créerait des affirmations en double.
  if tg_op = 'UPDATE' and old.statut in ('en_cours', 'traite') then
    raise exception 'Analyse refusée : l''article % est déjà « % ».', new.id, old.statut
      using errcode = 'check_violation';
  end if;

  -- Sérialise les demandes d'un même média pour que le quota soit exact.
  perform pg_advisory_xact_lock(hashtext('analyse_media'), new.media_id::integer);

  select p.valeur into v_quota from public.parametres p where p.cle = 'analyses_max_par_media_jour';
  select count(*) into v_nb from public.articles a
   where a.media_id = new.media_id
     and a.analyse_demandee_le >= v_debut
     and a.id <> new.id;

  if v_quota is not null and v_nb >= v_quota then
    raise exception 'Analyse refusée : % analyse(s) déjà demandée(s) aujourd''hui pour ce média (maximum %, identique pour tous les médias).',
      v_nb, v_quota
      using errcode = 'check_violation';
  end if;

  new.analyse_demandee_le := now();
  return new;
end;
$$;

create trigger avant_demande_analyse
  before insert or update of statut on public.articles
  for each row execute function public.controler_demande_analyse();

create or replace function public.lancer_analyse()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.statut = 'en_attente' then
    return null;
  end if;
  perform public.appeler_edge_function('analyser-article', jsonb_build_object('article_id', new.id));
  return null;
end;
$$;

create trigger apres_demande_analyse
  after insert or update of statut on public.articles
  for each row when (new.statut = 'en_attente')
  execute function public.lancer_analyse();

-- Filet de sécurité (appelé toutes les 15 minutes, section 12) :
-- une analyse bloquée passe en 'erreur', une demande restée sans réponse est relancée.
create or replace function public.relancer_analyses()
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare
  v_id bigint;
  v_nb integer := 0;
begin
  update public.articles a
     set statut = 'erreur'
   where a.statut = 'en_cours'
     and a.analyse_demandee_le < now() - interval '30 minutes';

  for v_id in
    select a.id from public.articles a
     where a.statut = 'en_attente'
       and a.analyse_demandee_le < now() - interval '15 minutes'
     order by a.analyse_demandee_le
     limit 10
  loop
    perform public.appeler_edge_function('analyser-article', jsonb_build_object('article_id', v_id));
    v_nb := v_nb + 1;
  end loop;

  return v_nb;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Fonctions appelables par le front ou les Edge Functions (RPC)
-- ---------------------------------------------------------------------

-- 7.1 Questions restantes aujourd'hui (heure de Paris) pour le visiteur,
--     en tenant compte du quota individuel ET du plafond global de l'app.
create or replace function public.questions_restantes()
returns integer
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_debut   timestamptz := date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris';
  v_quota   integer;
  v_plafond integer;
  v_perso   integer;
  v_global  integer;
begin
  if auth.uid() is null then
    return 0;
  end if;

  select p.valeur into v_quota   from public.parametres p where p.cle = 'quota_questions_jour';
  select p.valeur into v_plafond from public.parametres p where p.cle = 'plafond_global_questions_jour';

  select count(*) into v_perso from public.messages m
   where m.user_id = auth.uid() and m.auteur = 'utilisateur' and m.created_at >= v_debut;

  select count(*) into v_global from public.messages m
   where m.auteur = 'utilisateur' and m.created_at >= v_debut;

  return greatest(0, least(coalesce(v_quota, 0) - v_perso,
                           coalesce(v_plafond, 0) - v_global));
end;
$$;

-- 7.2 Recherche sémantique dans les sources (RAG du fact-checking et du chatbot).
create or replace function public.rechercher_sources(
  requete extensions.vector(1024),
  nb      integer default 5
)
returns table (
  id         bigint,
  titre      text,
  url        text,
  extrait    text,
  organisme  text,
  similarite double precision
)
language sql stable
set search_path = public, extensions
as $$
  select s.id, s.titre, s.url, s.extrait, o.nom,
         1 - (s.embedding <=> requete) as similarite
    from public.sources s
    join public.organismes o on o.id = s.organisme_id
   where s.embedding is not null
     and o.actif
   order by s.embedding <=> requete
   limit least(greatest(nb, 1), 20);
$$;


-- ---------------------------------------------------------------------
-- 8. Vue publique
-- ---------------------------------------------------------------------
-- security_invoker = true : la vue applique la RLS de celui qui la lit.
-- Sans cette option, une vue s'exécute avec les droits de son créateur
-- et contourne toute la RLS.
create view public.affirmations_publiques
with (security_invoker = true) as
select
  a.id,
  a.citation,
  a.verdict,
  v.libelle      as verdict_libelle,
  a.explication,
  a.statut,
  a.nb_signalements,
  a.publie_le,
  ar.id          as article_id,
  ar.titre       as article_titre,
  ar.url         as article_url,
  ar.publie_le   as article_publie_le,
  m.nom          as media,
  coalesce((
    select jsonb_agg(jsonb_build_object('nom', c.nom, 'parti', c.parti) order by c.nom)
      from public.affirmation_candidats ac
      join public.candidats c on c.id = ac.candidat_id
     where ac.affirmation_id = a.id
  ), '[]'::jsonb) as candidats,
  coalesce((
    select jsonb_agg(jsonb_build_object('titre', s.titre, 'url', s.url, 'organisme', o.nom) order by o.nom, s.titre)
      from public.affirmation_sources asr
      join public.sources s    on s.id = asr.source_id
      join public.organismes o on o.id = s.organisme_id
     where asr.affirmation_id = a.id
  ), '[]'::jsonb) as sources
from public.affirmations a
join public.verdicts v  on v.code = a.verdict
join public.articles ar on ar.id = a.article_id
join public.medias m    on m.id = ar.media_id
where a.statut in ('publie', 'a_verifier');


-- ---------------------------------------------------------------------
-- 9. Row Level Security
-- ---------------------------------------------------------------------
-- Astuce performance : (select fonction()) est évalué une fois par requête
-- au lieu d'une fois par ligne.

alter table public.profils               enable row level security;
alter table public.parametres            enable row level security;
alter table public.verdicts              enable row level security;
alter table public.medias                enable row level security;
alter table public.organismes            enable row level security;
alter table public.sources               enable row level security;
alter table public.candidats             enable row level security;
alter table public.articles              enable row level security;
alter table public.affirmations          enable row level security;
alter table public.affirmation_sources   enable row level security;
alter table public.affirmation_candidats enable row level security;
alter table public.signalements          enable row level security;
alter table public.messages              enable row level security;

-- profils : chacun lit le sien ; seul un admin lit tout et change les rôles.
-- Aucune policy INSERT/DELETE : création par trigger, suppression par cascade.
create policy profils_lecture on public.profils
  for select to authenticated
  using (id = (select auth.uid()) or (select public.est_admin()));

create policy profils_modif_admin on public.profils
  for update to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

-- parametres : lisibles par l'équipe, modifiables par l'admin.
create policy parametres_lecture on public.parametres
  for select to authenticated
  using ((select public.est_editeur()));

create policy parametres_ecriture on public.parametres
  for all to authenticated
  using ((select public.est_admin()))
  with check ((select public.est_admin()));

-- Référentiels publics : lecture pour tous, écriture admin.
create policy verdicts_lecture on public.verdicts
  for select to anon, authenticated using (true);
create policy verdicts_ecriture on public.verdicts
  for all to authenticated
  using ((select public.est_admin())) with check ((select public.est_admin()));

create policy organismes_lecture on public.organismes
  for select to anon, authenticated using (true);
create policy organismes_ecriture on public.organismes
  for all to authenticated
  using ((select public.est_admin())) with check ((select public.est_admin()));

create policy sources_lecture on public.sources
  for select to anon, authenticated using (true);
create policy sources_ecriture on public.sources
  for all to authenticated
  using ((select public.est_admin())) with check ((select public.est_admin()));

create policy candidats_lecture on public.candidats
  for select to anon, authenticated using (true);
create policy candidats_ecriture on public.candidats
  for all to authenticated
  using ((select public.est_admin())) with check ((select public.est_admin()));

-- medias : lecture publique ; un éditeur peut ajouter ou corriger un média.
create policy medias_lecture on public.medias
  for select to anon, authenticated using (true);
create policy medias_ajout on public.medias
  for insert to authenticated with check ((select public.est_editeur()));
create policy medias_modif on public.medias
  for update to authenticated
  using ((select public.est_editeur())) with check ((select public.est_editeur()));
create policy medias_suppression on public.medias
  for delete to authenticated using ((select public.est_admin()));

-- articles : le public voit les articles traités, l'équipe voit tout.
-- Les articles du flux RSS arrivent en 'importe' (Edge Function importer-rss) ;
-- un éditeur les passe en 'en_attente' pour lancer l'analyse.
create policy articles_lecture on public.articles
  for select to anon, authenticated
  using (statut = 'traite' or (select public.est_editeur()));

create policy articles_ajout on public.articles
  for insert to authenticated
  with check (
    (select public.est_editeur())
    and ajoute_par = (select auth.uid())
    and statut = 'en_attente'
  );

create policy articles_modif on public.articles
  for update to authenticated
  using ((select public.est_editeur())) with check ((select public.est_editeur()));

create policy articles_suppression on public.articles
  for delete to authenticated using ((select public.est_admin()));

-- affirmations : écrites par l'IA via service_role (pas de policy INSERT).
-- L'équipe peut les retirer ou les revalider ; le trigger 6.3 s'applique aussi à elle.
create policy affirmations_lecture on public.affirmations
  for select to anon, authenticated
  using (statut in ('publie', 'a_verifier') or (select public.est_editeur()));

create policy affirmations_modif on public.affirmations
  for update to authenticated
  using ((select public.est_editeur())) with check ((select public.est_editeur()));

create policy affirmations_suppression on public.affirmations
  for delete to authenticated using ((select public.est_admin()));

-- Tables de liaison : visibles si l'affirmation l'est (la sous-requête
-- passe elle-même par la RLS d'affirmations).
create policy preuves_lecture on public.affirmation_sources
  for select to anon, authenticated
  using (exists (select 1 from public.affirmations a where a.id = affirmation_id));
create policy preuves_ajout on public.affirmation_sources
  for insert to authenticated with check ((select public.est_editeur()));
create policy preuves_suppression on public.affirmation_sources
  for delete to authenticated using ((select public.est_editeur()));

create policy candidats_concernes_lecture on public.affirmation_candidats
  for select to anon, authenticated
  using (exists (select 1 from public.affirmations a where a.id = affirmation_id));
create policy candidats_concernes_ajout on public.affirmation_candidats
  for insert to authenticated with check ((select public.est_editeur()));
create policy candidats_concernes_suppression on public.affirmation_candidats
  for delete to authenticated using ((select public.est_editeur()));

-- signalements : un visiteur (même anonyme) signale une affirmation visible
-- et ne voit que ses propres signalements. L'équipe voit tout.
create policy signalements_ajout on public.signalements
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.affirmations a
       where a.id = affirmation_id and a.statut in ('publie', 'a_verifier')
    )
  );

create policy signalements_lecture on public.signalements
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.est_editeur()));

create policy signalements_suppression on public.signalements
  for delete to authenticated using ((select public.est_admin()));

-- messages : chacun ne voit que sa conversation, personne d'autre.
-- Le visiteur n'écrit que ses questions, dans la limite du quota.
-- Les réponses sont écrites par l'Edge Function chatbot via service_role.
create policy messages_lecture on public.messages
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy messages_question on public.messages
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and auteur = 'utilisateur'
    and public.questions_restantes() > 0
  );


-- ---------------------------------------------------------------------
-- 10. Privilèges de table (GRANT)
-- ---------------------------------------------------------------------
-- On repart de zéro pour anon et authenticated, puis on donne le minimum.
-- service_role garde ses privilèges par défaut (usage serveur uniquement).
revoke all on all tables in schema public from anon, authenticated;

grant select on
  public.verdicts, public.medias, public.organismes, public.sources,
  public.candidats, public.articles, public.affirmations,
  public.affirmation_sources, public.affirmation_candidats,
  public.affirmations_publiques
to anon, authenticated;

grant select on public.profils, public.parametres, public.signalements, public.messages
to authenticated;

grant update on public.profils to authenticated;
grant insert, update, delete on
  public.parametres, public.verdicts, public.organismes, public.sources,
  public.candidats, public.medias, public.articles
to authenticated;
grant update, delete on public.affirmations to authenticated;
grant insert, delete on public.affirmation_sources, public.affirmation_candidats to authenticated;
grant insert, delete on public.signalements to authenticated;
grant insert on public.messages to authenticated;

-- Les fonctions de trigger ne doivent pas être appelables via l'API.
-- appeler_edge_function lit le Vault : jamais exposée, sinon n'importe qui
-- pourrait déclencher des appels à l'IA.
revoke execute on function
  public.creer_profil(), public.controler_source(),
  public.verifier_sources_avant_publication(), public.proteger_sources_publiees(),
  public.traiter_signalement(), public.controler_demande_analyse(),
  public.lancer_analyse(), public.relancer_analyses(),
  public.appeler_edge_function(text, jsonb)
from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 11. Données de référence
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur, description) values
  ('seuil_signalements',            5,   'Nombre de signalements qui repasse une affirmation « à vérifier »'),
  ('quota_questions_jour',          10,  'Questions au chatbot par visiteur et par jour'),
  ('plafond_global_questions_jour', 900, 'Questions par jour pour toute l''app, sous la limite du fournisseur d''IA'),
  ('retention_messages_jours',      30,  'Durée de conservation des conversations du chatbot'),
  ('articles_max_par_media_import', 50,  'Articles importés au maximum par média à chaque import RSS (identique pour tous)'),
  ('analyses_max_par_media_jour',   5,   'Analyses IA demandées au maximum par média et par jour (identique pour tous)'),
  ('affirmations_max_par_article',  5,   'Affirmations extraites au maximum par article analysé'),
  ('sources_par_affirmation',       6,   'Sources proposées à l''IA pour vérifier une affirmation'),
  ('sources_max_par_organisme_maj', 50,  'Nouvelles sources ajoutées au maximum par organisme à chaque mise à jour');

insert into public.verdicts (code, libelle, description, sources_min, ordre) values
  ('vrai',               'Vrai',                  'L''affirmation est confirmée par les sources.',                        1, 1),
  ('manque_de_contexte', 'Manque de contexte',    'Exact, mais présenté d''une façon qui peut induire en erreur.',       1, 2),
  ('trompeur',           'Trompeur',              'Mélange d''éléments exacts et faux, ou chiffres détournés.',          2, 3),
  ('faux',               'Faux',                  'L''affirmation est contredite par les sources.',                      2, 4),
  ('non_verifiable',     'Non vérifiable',        'Aucune source fiable ne permet de trancher. Rien n''est inventé.',   0, 5);

-- flux_url : à compléter par l'admin avec le flux RSS officiel de chaque organisme
-- (update public.organismes set flux_url = '...' where nom = '...').
insert into public.organismes (nom, site_url, type, reutilisation, flux_url) values
  ('INSEE',                           'https://www.insee.fr',                   'statistique',          'ouverte',        null),
  ('Eurostat',                        'https://ec.europa.eu/eurostat',          'statistique',          'ouverte',        null),
  ('DREES',                           'https://drees.solidarites-sante.gouv.fr','statistique',          'ouverte',        null),
  ('DARES',                           'https://dares.travail-emploi.gouv.fr',   'statistique',          'ouverte',        null),
  ('Banque de France',                'https://www.banque-france.fr',           'statistique',          'ouverte',        null),
  ('SSMSI (ministère de l''Intérieur)','https://www.interieur.gouv.fr',         'statistique',          'ouverte',        null),
  ('Légifrance',                      'https://www.legifrance.gouv.fr',         'juridique',            'ouverte',        null),
  ('Conseil constitutionnel',         'https://www.conseil-constitutionnel.fr', 'juridique',            'ouverte',        null),
  ('Assemblée nationale',             'https://www.assemblee-nationale.fr',     'institution',          'ouverte',        null),
  ('Sénat',                           'https://www.senat.fr',                   'institution',          'ouverte',        null),
  ('Cour des comptes',                'https://www.ccomptes.fr',                'institution',          'ouverte',        null),
  ('Vie-publique.fr',                 'https://www.vie-publique.fr',            'institution',          'ouverte',        null),
  ('HATVP',                           'https://www.hatvp.fr',                   'institution',          'ouverte',        null),
  ('Viginum (SGDSN)',                 'https://www.sgdsn.gouv.fr',              'securite_information', 'ouverte',        null),
  ('AFP Factuel',                     'https://factuel.afp.com',                'fact_checking',        'lien_seulement', null),
  ('Les Décodeurs (Le Monde)',        'https://www.lemonde.fr',                 'fact_checking',        'lien_seulement', 'https://www.lemonde.fr/les-decodeurs/rss_full.xml'),
  ('CheckNews (Libération)',          'https://www.liberation.fr',              'fact_checking',        'lien_seulement', null),
  ('Vrai ou faux (franceinfo)',       'https://www.francetvinfo.fr',            'fact_checking',        'lien_seulement', 'https://www.francetvinfo.fr/vrai-ou-fake.rss'),
  ('Les Surligneurs',                 'https://www.lessurligneurs.eu',          'fact_checking',        'lien_seulement', 'https://www.lessurligneurs.eu/feed/');

-- Médias de départ : à compléter, avec la même règle de sélection pour tous.
-- Flux « politique » de chaque média ; ceux laissés vides sont à renseigner
-- pour que tous les médias soient importés de la même façon.
insert into public.medias (nom, site_url, flux_rss_url) values
  ('Le Monde',     'https://www.lemonde.fr',      'https://www.lemonde.fr/politique/rss_full.xml'),
  ('Le Figaro',    'https://www.lefigaro.fr',     'https://www.lefigaro.fr/rss/figaro_politique.xml'),
  ('Libération',   'https://www.liberation.fr',   'https://www.liberation.fr/arc/outboundfeeds/rss-all/category/politique/?outputType=xml'),
  ('CNews',        'https://www.cnews.fr',        null),
  ('franceinfo',   'https://www.francetvinfo.fr', 'https://www.francetvinfo.fr/politique.rss'),
  ('BFMTV',        'https://www.bfmtv.com',       'https://www.bfmtv.com/rss/politique/'),
  ('Le Parisien',  'https://www.leparisien.fr',   'https://feeds.leparisien.fr/leparisien/rss/politique'),
  ('Ouest-France', 'https://www.ouest-france.fr', null),
  ('20 Minutes',   'https://www.20minutes.fr',    'https://www.20minutes.fr/feeds/rss-politique.xml');


-- ---------------------------------------------------------------------
-- 12. Tâches planifiées
-- ---------------------------------------------------------------------
-- Si cette ligne échoue, active Cron dans le dashboard (Integrations > Cron).
create extension if not exists pg_cron with schema pg_catalog;

-- RGPD : supprime les conversations plus anciennes que la durée de conservation.
select cron.schedule(
  'purge-messages-chatbot',
  '15 3 * * *',
  $$ delete from public.messages
      where created_at < now() - make_interval(
        days => (select valeur from public.parametres where cle = 'retention_messages_jours')
      ) $$
);

-- RGPD : supprime les visiteurs anonymes inactifs depuis 30 jours
-- (leurs signalements et messages partent en cascade ; les compteurs restent).
select cron.schedule(
  'purge-visiteurs-anonymes',
  '30 3 * * *',
  $$ delete from auth.users
      where is_anonymous is true
        and coalesce(last_sign_in_at, created_at) < now() - interval '30 days' $$
);

-- Import quotidien des flux RSS des médias (heure UTC).
select cron.schedule(
  'importer-rss',
  '10 5 * * *',
  $$ select public.appeler_edge_function('importer-rss') $$
);

-- Mise à jour hebdomadaire des sources et des candidats (lundi, heure UTC).
select cron.schedule(
  'maj-sources',
  '40 4 * * 1',
  $$ select public.appeler_edge_function('maj-sources') $$
);

-- Filet de sécurité des analyses (voir 6.6).
select cron.schedule(
  'relance-analyses',
  '*/15 * * * *',
  $$ select public.relancer_analyses() $$
);
