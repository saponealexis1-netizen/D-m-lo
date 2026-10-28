-- =====================================================================
--  BROUILLON — NE PAS APPLIQUER SANS VALIDATION EXPLICITE
--  Démêlo v2, étape 5 : fact-checking automatisé par Claude
-- =====================================================================
--  Modifie le schéma v2 en place (les 4 tables sont vides, sauf les 15 sources) :
--  * le circuit éditeur / relecteur disparaît ; un pipeline serveur (rôle
--    Postgres `demelo_pipeline`, moindre privilège) analyse les articles ;
--  * les 4 membres de l'équipe sont administrateurs (app_metadata.role_equipe = 'admin') :
--    revue exceptionnelle, correction, retrait ;
--  * les articles viennent de médias extérieurs : contenus.source_id devient
--    facultatif (rempli seulement si l'article est publié par l'un des 15 organismes),
--    le média est décrit par media_nom + domaine_origine ;
--  * une preuve n'est acceptée que si le document a été téléchargé et vérifié
--    par du code (URL finale, statut HTTP, empreinte, passage retrouvé) et
--    qu'il appartient au périmètre de l'organisme cité ;
--  * données fictives (est_test) : jamais analysées, jamais publiques.
--
--  La base contrôle l'intégrité et les conditions de publication. Elle ne peut
--  pas garantir la justesse d'une analyse : c'est le rôle du pipeline et des limites affichées.
--
--  Policies et GRANT CLIENTS (anon / authenticated) : configuration manuelle
--  (supabase/rls_manuel/). Seuls les droits du rôle serveur `demelo_pipeline` sont ici.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Rôle technique du pipeline (moindre privilège)
-- ---------------------------------------------------------------------
-- NOLOGIN ici : un administrateur active la connexion plus tard avec un mot de
-- passe saisi dans le SQL Editor (jamais versionné). Non accessible via l'API :
-- `authenticator` n'en est pas membre, aucun JWT ne peut l'utiliser.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'demelo_pipeline') then
    create role demelo_pipeline nologin noinherit;
  end if;
end $$;
comment on role demelo_pipeline is 'Pipeline de fact-checking Démêlo : lit les sources et les articles, écrit les analyses et les preuves. Aucune suppression.';


-- ---------------------------------------------------------------------
-- 1. Types
-- ---------------------------------------------------------------------
create type public.statut_analyse    as enum ('non_traite', 'en_cours', 'analyse_disponible',
                                              'verification_insuffisante', 'revue_requise', 'retire');
create type public.nature_enonce     as enum ('factuel', 'opinion', 'promesse', 'prevision');
create type public.statut_preuve     as enum ('verifiee', 'inaccessible', 'rejetee');
create type public.nature_preuve     as enum ('primaire', 'secondaire');
create type public.statut_traitement as enum ('non_traite', 'en_cours', 'traite', 'inaccessible', 'erreur');


-- ---------------------------------------------------------------------
-- 2. Retrait du circuit de validation humaine
-- ---------------------------------------------------------------------
drop view public.v_feed_verifie;                       -- dépend de statut_workflow, recréée en 8
drop trigger controler_affirmation on public.affirmations;
drop trigger controler_preuve on public.preuves;
drop function prive.controler_affirmation();
drop function prive.controler_preuve();

alter table public.affirmations
  drop constraint affirmations_check,                   -- verdict requis en relecture
  drop constraint affirmations_check1,                  -- relecteur requis pour publier
  drop constraint affirmations_check2;                  -- relecteur différent de l'auteur
alter table public.affirmations drop column statut_workflow;
drop type public.statut_workflow;

drop function prive.est_membre();
drop function prive.est_relecteur();


-- ---------------------------------------------------------------------
-- 4. sources : périmètre vérifiable de chaque organisme
-- ---------------------------------------------------------------------
alter table public.sources add column perimetres text[] not null default '{}';

update public.sources s set perimetres = v.perimetres
  from (values
    ('INSEE',                             array['insee.fr']),
    ('Eurostat',                          array['ec.europa.eu/eurostat']),
    ('Légifrance',                        array['legifrance.gouv.fr']),
    ('DARES',                             array['dares.travail-emploi.gouv.fr']),
    ('DREES',                             array['drees.solidarites-sante.gouv.fr']),
    ('Banque de France',                  array['banque-france.fr']),
    ('SSMSI (ministère de l''Intérieur)', array['interieur.gouv.fr/interstats']),
    ('Conseil constitutionnel',           array['conseil-constitutionnel.fr']),
    ('Sénat',                             array['senat.fr']),
    ('Assemblée nationale',               array['assemblee-nationale.fr']),
    ('Cour des comptes',                  array['ccomptes.fr']),
    ('HATVP',                             array['hatvp.fr']),
    ('Vie-publique.fr',                   array['vie-publique.fr']),
    ('Viginum (SGDSN)',                   array['sgdsn.gouv.fr']),
    ('AFP Factuel',                       array['factuel.afp.com'])
  ) as v(nom, perimetres)
 where s.nom = v.nom;

do $$
begin
  if exists (select 1 from public.sources where cardinality(perimetres) = 0) then
    raise exception 'Une source n''a pas de périmètre.';
  end if;
end $$;

alter table public.sources
  add constraint sources_perimetres_check check (
    cardinality(perimetres) >= 1
    and array_to_string(perimetres, ' ') !~ '(^| )(https?://|www\.)'
  );


-- ---------------------------------------------------------------------
-- 5. contenus : articles de médias extérieurs, données fictives isolées
-- ---------------------------------------------------------------------
alter table public.contenus
  drop constraint contenus_source_id_identifiant_externe_key,
  alter column source_id drop not null,
  add column media_nom           text not null check (char_length(media_nom) between 2 and 200),
  add column domaine_origine     text generated always as
                                 (lower(substring(url_originale from '^https?://(?:www\.)?([^/:?#]+)'))) stored,
  add column est_test            boolean not null default false,
  add column statut_traitement   public.statut_traitement not null default 'non_traite',
  add column derniere_analyse_le timestamptz,
  add column derniere_erreur     text check (char_length(derniere_erreur) <= 1000),
  add constraint contenus_domaine_identifiant_key unique (domaine_origine, identifiant_externe),
  -- Une donnée fictive est toujours reconnaissable et jamais attribuée à une institution réelle.
  add constraint contenus_fictif_check check (
    (est_test and source_id is null
              and right(domaine_origine, 8) = '.invalid'
              and titre like '[FICTIF] %'
              and media_nom ilike 'média fictif%')
    or (not est_test and right(domaine_origine, 8) <> '.invalid')
  );
create index on public.contenus (statut_traitement) where not est_test;
comment on column public.contenus.source_id is 'Rempli seulement si l''article est publié par l''un des 15 organismes. Sinon, le média est décrit par media_nom.';


-- ---------------------------------------------------------------------
-- 6. affirmations : statut d'analyse et traçabilité IA
-- ---------------------------------------------------------------------
alter table public.affirmations
  alter column created_by drop not null,
  alter column created_by drop default,
  add column statut_analyse    public.statut_analyse not null default 'non_traite',
  add column nature_enonce     public.nature_enonce not null default 'factuel',
  add column contexte          text check (char_length(contexte) <= 1000),
  add column motif_selection   text check (char_length(motif_selection) <= 500),
  add column date_affirmation  date,
  add column theme             public.theme_contenu,
  add column citation_verifiee boolean not null default false,  -- retrouvée mot pour mot dans l'article (code)
  add column sensible          boolean not null default false,
  add column motif_sensibilite text check (char_length(motif_sensibilite) <= 500),
  add column recoupement       jsonb,                            -- périodes, définitions, unités…
  add column motif_abstention  text check (char_length(motif_abstention) <= 1000),
  add column modele_ia         text check (char_length(modele_ia) <= 100),
  add column version_prompt    text check (char_length(version_prompt) <= 50),
  add column analyse_le        timestamptz,
  add column id_execution      text check (char_length(id_execution) <= 100),
  add column revue_motif       text check (char_length(revue_motif) <= 1000),  -- saisi à chaque décision, archivé dans historique
  add column historique        jsonb not null default '[]'::jsonb check (jsonb_typeof(historique) = 'array'),
  -- Garde-fous indépendants du trigger
  add constraint affirmations_publication_check check (
    statut_analyse <> 'analyse_disponible'
    or (verdict is not null and explication is not null and limites is not null and citation_verifiee
        and modele_ia is not null and version_prompt is not null and analyse_le is not null and published_at is not null)
  ),
  add constraint affirmations_abstention_check check (
    statut_analyse <> 'verification_insuffisante'
    or (verdict is null and motif_abstention is not null and limites is not null
        and modele_ia is not null and analyse_le is not null)
  ),
  add constraint affirmations_revue_check check (
    statut_analyse <> 'revue_requise' or motif_sensibilite is not null or motif_abstention is not null
  ),
  add constraint affirmations_sensible_check check (not sensible or motif_sensibilite is not null),
  -- « non_verifiable » est réservé aux opinions, promesses et prévisions ; un fait sans
  -- preuve suffisante donne une abstention (verification_insuffisante), pas un verdict.
  add constraint affirmations_nature_verdict_check check (
    verdict is null or (verdict = 'non_verifiable') = (nature_enonce <> 'factuel')
  ),
  add constraint affirmations_recoupement_check check (
    statut_analyse <> 'analyse_disponible' or verdict not in ('vrai', 'faux', 'trompeur')
    or (jsonb_typeof(recoupement) = 'object'
        and recoupement ?& array['periode', 'definition', 'unite', 'population', 'perimetre', 'contradictions', 'dependances'])
  );
create index on public.affirmations (statut_analyse);


-- ---------------------------------------------------------------------
-- 7. preuves : documents réellement consultés, réussites ET échecs
-- ---------------------------------------------------------------------
alter table public.preuves
  drop constraint preuves_affirmation_id_url_preuve_key,
  alter column ajoutee_par drop not null,
  alter column ajoutee_par drop default,
  add column version_analyse      integer not null default 1,
  add column statut_preuve        public.statut_preuve not null,
  add column motif_rejet          text check (char_length(motif_rejet) <= 500),
  add column url_finale           text check (url_finale ~* '^https://'),
  add column http_statut          integer check (http_statut between 100 and 599),
  add column type_document        text check (char_length(type_document) <= 100),
  add column titre_document       text check (char_length(titre_document) <= 500),
  add column version_document     text check (char_length(version_document) <= 100),
  add column empreinte_sha256     text check (empreinte_sha256 ~ '^[0-9a-f]{64}$'),
  add column passage_verifie      boolean not null default false,  -- retrouvé mot pour mot (code)
  add column passage_empreinte    text check (passage_empreinte ~ '^[0-9a-f]{64}$'),
  add column nature               public.nature_preuve,
  add column justification_nature text check (char_length(justification_nature) <= 500),
  add column reprend_preuve_id    bigint references public.preuves (id),   -- dépendance entre sources
  add column domaine_conforme     boolean not null default false,  -- calculé par le trigger
  add constraint preuves_analyse_url_key unique (affirmation_id, version_analyse, url_preuve),
  add constraint preuves_verifiee_check check (
    statut_preuve <> 'verifiee'
    or (url_finale is not null and http_statut between 200 and 299 and empreinte_sha256 is not null
        and titre_document is not null and nature is not null and justification_nature is not null
        and passage_verifie and domaine_conforme
        and (extrait is not null or passage_empreinte is not null)
        and (date_document is not null or version_document is not null))
  ),
  add constraint preuves_echec_check check (statut_preuve = 'verifiee' or motif_rejet is not null),
  add constraint preuves_reprise_check check (reprend_preuve_id is null or reprend_preuve_id <> id);
create index on public.preuves (affirmation_id, version_analyse);
create index on public.preuves (reprend_preuve_id);


-- ---------------------------------------------------------------------
-- 7 bis. Fonctions d'aide (schéma prive, non exposé par l'API)
-- ---------------------------------------------------------------------
-- Lecture directe des claims du JWT (équivalent de auth.jwt() / auth.uid()), pour que
-- le rôle demelo_pipeline n'ait besoin d'aucun droit sur le schéma auth.
create function prive.jwt()
returns jsonb
language sql stable
set search_path = ''
as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb;
$$;

create function prive.uid()
returns uuid
language sql stable
set search_path = ''
as $$
  select nullif(prive.jwt() ->> 'sub', '')::uuid;
$$;

create or replace function prive.role_equipe()
returns text
language sql stable
set search_path = ''
as $$
  select case
           when coalesce((prive.jwt() ->> 'is_anonymous')::boolean, false) then null
           else prive.jwt() -> 'app_metadata' ->> 'role_equipe'
         end;
$$;

create function prive.est_admin()
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(prive.role_equipe() = 'admin', false);
$$;

-- Le document est-il dans le périmètre de l'organisme ? Périmètre = 'domaine'
-- ou 'domaine/chemin', sans schéma. Sous-domaines inclus. HTTPS obligatoire.
create function prive.url_dans_perimetre(p_url text, p_perimetres text[])
returns boolean
language sql immutable
set search_path = ''
as $$
  with u as (
    select lower(substring(p_url from '^https://([^/:?#]+)'))                        as hote,
           lower(coalesce(substring(p_url from '^https://[^/?#]+(/[^?#]*)'), '/'))  as chemin
  ), p as (
    select split_part(x, '/', 1) as hote,
           case when position('/' in x) > 0 then rtrim(substr(x, position('/' in x)), '/') else '' end as chemin
      from unnest(p_perimetres) as x
  )
  select coalesce(bool_or(
           u.hote is not null
           and (u.hote = p.hote or right(u.hote, length(p.hote) + 1) = '.' || p.hote)
           and (p.chemin = '' or u.chemin = p.chemin or left(u.chemin, length(p.chemin) + 1) = p.chemin || '/')
         ), false)
    from u, p;
$$;

-- Lectures nécessaires aux triggers, quelles que soient les policies de l'appelant.
create function prive.contenu_est_test(p_contenu bigint)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((select c.est_test from public.contenus c where c.id = p_contenu), true);
$$;

create function prive.etat_affirmation(p_affirmation bigint, out statut public.statut_analyse, out version integer)
language sql stable security definer
set search_path = ''
as $$
  select a.statut_analyse, a.version from public.affirmations a where a.id = p_affirmation;
$$;

create function prive.infos_source(p_source bigint, out reutilisation public.licence_reutilisation, out perimetres text[])
language sql stable security definer
set search_path = ''
as $$
  select s.reutilisation, s.perimetres from public.sources s where s.id = p_source;
$$;

create function prive.preuve_de_la_meme_analyse(p_preuve bigint, p_affirmation bigint, p_version integer)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.preuves p
                  where p.id = p_preuve and p.affirmation_id = p_affirmation and p.version_analyse = p_version);
$$;

-- Bilan des preuves VÉRIFIÉES d'une version d'analyse. « Primaire indépendante » :
-- nature primaire pour cette affirmation et ne reprenant pas une autre preuve.
create function prive.bilan_preuves(p_affirmation bigint, p_version integer,
  out verifiees integer, out primaires integer, out confirme integer, out contredit integer,
  out contextualise integer, out confirme_primaires integer, out contredit_primaires integer)
language sql stable security definer
set search_path = ''
as $$
  select count(*)::integer,
         count(*) filter (where p.nature = 'primaire' and p.reprend_preuve_id is null)::integer,
         count(*) filter (where p.type_relation = 'confirme')::integer,
         count(*) filter (where p.type_relation = 'contredit')::integer,
         count(*) filter (where p.type_relation = 'contextualise')::integer,
         count(*) filter (where p.type_relation = 'confirme'  and p.nature = 'primaire' and p.reprend_preuve_id is null)::integer,
         count(*) filter (where p.type_relation = 'contredit' and p.nature = 'primaire' and p.reprend_preuve_id is null)::integer
    from public.preuves p
   where p.affirmation_id = p_affirmation
     and p.version_analyse = p_version
     and p.statut_preuve = 'verifiee';
$$;


-- ---------------------------------------------------------------------
-- 8. Triggers (SECURITY INVOKER : l'identité réelle de l'appelant compte)
-- ---------------------------------------------------------------------

-- 8.1 Cycle de vie d'une affirmation
--   non_traite -> en_cours -> analyse_disponible | verification_insuffisante | revue_requise
--   en_cours -> non_traite                                   (échec technique, relance)
--   revue_requise -> analyse_disponible | verification_insuffisante | retire   (admin)
--   analyse_disponible | verification_insuffisante -> retire | revue_requise  (admin)
--   tout statut final -> non_traite                          (admin : correction, version + 1)
create function prive.controler_affirmation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_pipeline boolean := current_user = 'demelo_pipeline';
  v_admin    boolean := prive.est_admin();
  v_geres    text[]  := array['updated_at', 'historique', 'statut_analyse', 'reviewed_by',
                              'reviewed_at', 'published_at', 'version', 'revue_motif'];
  v_modifiee boolean;
  v_b        record;
begin
  if not (v_pipeline or v_admin) then
    raise exception 'Écriture refusée : seuls le pipeline et les administrateurs modifient les affirmations.'
      using errcode = 'insufficient_privilege';
  end if;

  if tg_op = 'INSERT' then
    if prive.contenu_est_test(new.contenu_id) then
      raise exception 'Refus : aucune affirmation sur un contenu fictif.' using errcode = 'check_violation';
    end if;
    if new.statut_analyse <> 'non_traite' then
      raise exception 'Une affirmation est toujours créée en « non_traite ».' using errcode = 'check_violation';
    end if;
    new.created_by   := prive.uid();       -- vide pour le pipeline
    new.reviewed_by  := null;
    new.reviewed_at  := null;
    new.published_at := null;
    new.version      := 1;
    new.historique   := '[]'::jsonb;
    return new;
  end if;

  if new.contenu_id is distinct from old.contenu_id or new.created_by is distinct from old.created_by then
    raise exception 'Le contenu et l''auteur d''une affirmation ne sont pas modifiables.' using errcode = 'check_violation';
  end if;

  v_modifiee := (to_jsonb(new) - v_geres) is distinct from (to_jsonb(old) - v_geres);

  -- Champs tenus par la base, jamais modifiables directement.
  new.reviewed_by  := old.reviewed_by;
  new.reviewed_at  := old.reviewed_at;
  new.published_at := old.published_at;
  new.version      := old.version;
  new.historique   := old.historique;

  if new.statut_analyse = old.statut_analyse then
    if old.statut_analyse not in ('non_traite', 'en_cours') and v_modifiee then
      raise exception 'Analyse « % » figée : la renvoyer en « non_traite » pour la corriger.', old.statut_analyse
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- Transitions autorisées
  if old.statut_analyse = 'non_traite' and new.statut_analyse = 'en_cours' then
    null;
  elsif old.statut_analyse = 'en_cours'
        and new.statut_analyse in ('non_traite', 'analyse_disponible', 'verification_insuffisante', 'revue_requise') then
    null;
  elsif v_admin and old.statut_analyse = 'revue_requise'
        and new.statut_analyse in ('analyse_disponible', 'verification_insuffisante', 'retire') then
    if v_modifiee then
      raise exception 'Revue : l''administrateur valide ou écarte l''analyse telle quelle (sinon : « non_traite »).'
        using errcode = 'check_violation';
    end if;
    new.reviewed_by := prive.uid();
    new.reviewed_at := now();
  elsif v_admin and old.statut_analyse in ('analyse_disponible', 'verification_insuffisante')
        and new.statut_analyse in ('retire', 'revue_requise') then
    if v_modifiee then
      raise exception 'Le retrait ou la remise en revue ne modifie pas l''analyse.' using errcode = 'check_violation';
    end if;
  elsif v_admin and old.statut_analyse in ('analyse_disponible', 'verification_insuffisante', 'revue_requise', 'retire')
        and new.statut_analyse = 'non_traite' then
    new.version := old.version + 1;       -- correction : une nouvelle analyse sera produite
    new.published_at := null;
  else
    raise exception 'Transition interdite : % -> % (%).', old.statut_analyse, new.statut_analyse,
      case when v_admin then 'administrateur' else 'pipeline' end
      using errcode = 'check_violation';
  end if;

  -- Toute décision humaine est motivée.
  if v_admin and not v_pipeline and new.revue_motif is null
     and not (old.statut_analyse = 'non_traite' and new.statut_analyse = 'en_cours') then
    raise exception 'Décision d''administrateur : motif obligatoire (revue_motif).' using errcode = 'check_violation';
  end if;

  -- Contrôles bloquants de publication
  if new.statut_analyse = 'analyse_disponible' then
    if prive.contenu_est_test(new.contenu_id) then
      raise exception 'Publication refusée : contenu fictif.' using errcode = 'check_violation';
    end if;
    if new.sensible and not (v_admin and old.statut_analyse = 'revue_requise') then
      raise exception 'Publication refusée : affirmation sensible, passage obligatoire par « revue_requise ».'
        using errcode = 'check_violation';
    end if;
    if new.verdict is null or not new.citation_verifiee then
      raise exception 'Publication refusée : verdict absent ou citation non vérifiée dans l''article.'
        using errcode = 'check_violation';
    end if;

    select * into v_b from prive.bilan_preuves(new.id, new.version);
    if new.verdict = 'vrai' and (v_b.confirme_primaires < 1 or v_b.contredit > 0) then
      raise exception 'Publication refusée : « vrai » exige une preuve primaire vérifiée qui confirme, et aucune qui contredit.'
        using errcode = 'check_violation';
    elsif new.verdict = 'faux' and (v_b.contredit_primaires < 1 or v_b.confirme > 0) then
      raise exception 'Publication refusée : « faux » exige une preuve primaire vérifiée qui contredit, et aucune qui confirme.'
        using errcode = 'check_violation';
    elsif new.verdict = 'trompeur' and (v_b.primaires < 1 or v_b.confirme < 1 or v_b.contredit + v_b.contextualise < 1) then
      raise exception 'Publication refusée : « trompeur » exige une preuve qui confirme et une qui contextualise ou contredit, dont une primaire.'
        using errcode = 'check_violation';
    end if;
    new.published_at := now();
  end if;

  new.historique := old.historique || jsonb_build_array(jsonb_build_object(
    'le', now(), 'de', old.statut_analyse, 'vers', new.statut_analyse,
    'par', coalesce(prive.uid()::text, current_user::text), 'motif', new.revue_motif,
    'version', old.version, 'verdict', old.verdict, 'modele_ia', old.modele_ia, 'analyse_le', old.analyse_le));
  -- Le motif est conservé dans l'historique ; chaque nouvelle décision doit fournir le sien.
  new.revue_motif := null;
  return new;
end;
$$;

create trigger controler_affirmation
  before insert or update on public.affirmations
  for each row execute function prive.controler_affirmation();


-- 8.2 Preuves : écrites seulement pendant l'analyse, dans le périmètre de l'organisme
create function prive.controler_preuve()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_aff record;
  v_src record;
begin
  if not (current_user = 'demelo_pipeline' or prive.est_admin()) then
    raise exception 'Écriture refusée : seuls le pipeline et les administrateurs enregistrent des preuves.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_aff from prive.etat_affirmation(case when tg_op = 'DELETE' then old.affirmation_id else new.affirmation_id end);

  if tg_op = 'DELETE' then
    if v_aff.statut is null then
      return old;                          -- suppression en cascade de l'affirmation
    end if;
    if v_aff.statut <> 'en_cours' then
      raise exception 'Preuves figées : l''affirmation est « % ».', v_aff.statut using errcode = 'check_violation';
    end if;
    return old;
  end if;

  if v_aff.statut is distinct from 'en_cours' then
    raise exception 'Preuves enregistrées uniquement pendant l''analyse (« en_cours »), pas en « % ».', v_aff.statut
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' then
    new.version_analyse := v_aff.version;
    new.ajoutee_par := prive.uid();
  elsif new.affirmation_id <> old.affirmation_id or new.version_analyse <> old.version_analyse then
    raise exception 'Une preuve ne change pas d''affirmation ni de version.' using errcode = 'check_violation';
  end if;

  select * into v_src from prive.infos_source(new.source_id);
  new.domaine_conforme := prive.url_dans_perimetre(new.url_preuve, v_src.perimetres)
                      and prive.url_dans_perimetre(new.url_finale, v_src.perimetres);

  if new.statut_preuve = 'verifiee' and not new.domaine_conforme then
    raise exception 'Preuve refusée : % n''appartient pas au périmètre de l''organisme cité.', coalesce(new.url_finale, new.url_preuve)
      using errcode = 'check_violation';
  end if;
  if v_src.reutilisation = 'lien_seulement' and new.extrait is not null then
    raise exception 'Extrait refusé : source sous licence, seule l''empreinte du passage est conservée.'
      using errcode = 'check_violation';
  end if;
  if new.reprend_preuve_id is not null
     and not prive.preuve_de_la_meme_analyse(new.reprend_preuve_id, new.affirmation_id, new.version_analyse) then
    raise exception 'reprend_preuve_id doit désigner une preuve de la même analyse.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger controler_preuve
  before insert or update or delete on public.preuves
  for each row execute function prive.controler_preuve();


-- ---------------------------------------------------------------------
-- 9. Vues (security_invoker : appliquent la RLS de celui qui lit)
-- ---------------------------------------------------------------------
create view public.v_feed_verifie
with (security_invoker = true) as
select
  c.id,
  c.titre,
  c.url_originale,
  c.media_nom,
  c.domaine_origine,
  c.theme,
  c.resume,
  c.date_publication,
  count(a.id) filter (where a.statut_analyse = 'analyse_disponible')        as nb_analyses_publiees,
  count(a.id) filter (where a.statut_analyse = 'verification_insuffisante') as nb_abstentions,
  case
    when count(a.id) filter (where a.statut_analyse = 'analyse_disponible') > 0 then 'analyse_disponible'
    when count(a.id) filter (where a.statut_analyse = 'verification_insuffisante') > 0 then 'verification_insuffisante'
    else 'non_verifie'
  end                                                                        as statut_verification,
  max(a.analyse_le) filter (where a.statut_analyse in ('analyse_disponible', 'verification_insuffisante')) as derniere_analyse_le
from public.contenus c
left join public.affirmations a on a.contenu_id = c.id
where c.visible_public and not c.est_test
group by c.id;

-- Fiche publique d'une analyse : tout ce que le site doit afficher, avec ses preuves vérifiées.
create view public.v_analyses_publiques
with (security_invoker = true) as
select
  a.id,
  a.texte_affirmation,
  a.contexte,
  a.date_affirmation,
  a.theme,
  a.statut_analyse,
  a.verdict,
  a.explication,
  a.limites,
  a.motif_abstention,
  a.analyse_le,
  a.modele_ia,
  a.version_prompt,
  a.version,
  a.published_at,
  a.reviewed_at is not null                    as revue_par_equipe,
  'Analyse produite par IA'::text              as mention,
  c.id                                         as contenu_id,
  c.titre                                      as contenu_titre,
  c.url_originale                              as contenu_url,
  c.media_nom,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'url', p.url_finale, 'titre', p.titre_document, 'organisme', s.nom,
             'date_document', p.date_document, 'version_document', p.version_document,
             'relation', p.type_relation, 'nature', p.nature, 'extrait', p.extrait,
             'consulte_le', p.date_consultation) order by p.nature, s.nom)
      from public.preuves p
      join public.sources s on s.id = p.source_id
     where p.affirmation_id = a.id
       and p.version_analyse = a.version
       and p.statut_preuve = 'verifiee'
  ), '[]'::jsonb)                              as preuves
from public.affirmations a
join public.contenus c on c.id = a.contenu_id
where a.statut_analyse in ('analyse_disponible', 'verification_insuffisante')
  and c.visible_public and not c.est_test;


-- ---------------------------------------------------------------------
-- 10. Privilèges
-- ---------------------------------------------------------------------
-- Clients : toujours aucun droit (configuration manuelle par l'équipe).
revoke all on public.v_feed_verifie, public.v_analyses_publiques from anon, authenticated;

-- Fonctions internes : appelées par les triggers (invoker) et les futures policies.
revoke all on all functions in schema prive from public;
grant execute on function prive.jwt(), prive.uid(), prive.role_equipe(), prive.est_admin() to anon, authenticated, service_role, demelo_pipeline;
grant execute on function
  prive.url_dans_perimetre(text, text[]), prive.contenu_est_test(bigint), prive.etat_affirmation(bigint),
  prive.infos_source(bigint), prive.preuve_de_la_meme_analyse(bigint, bigint, integer), prive.bilan_preuves(bigint, integer)
  to authenticated, demelo_pipeline;

-- Pipeline : lecture des sources et des articles réels, écriture des analyses.
-- Aucune suppression, aucun accès à archive_v1, à auth ni aux données fictives.
grant usage on schema public, prive to demelo_pipeline;
grant select on public.sources, public.contenus, public.affirmations, public.preuves to demelo_pipeline;
grant insert (media_nom, url_originale, titre, identifiant_externe, date_publication, theme, lot_import, vu_le)
  on public.contenus to demelo_pipeline;
grant update (statut_traitement, derniere_analyse_le, derniere_erreur, vu_le) on public.contenus to demelo_pipeline;
grant insert, update on public.affirmations, public.preuves to demelo_pipeline;

create policy pipeline_sources_lecture on public.sources
  for select to demelo_pipeline using (active);
create policy pipeline_contenus_lecture on public.contenus
  for select to demelo_pipeline using (not est_test);
create policy pipeline_contenus_ajout on public.contenus
  for insert to demelo_pipeline with check (not est_test and source_id is null);
create policy pipeline_contenus_suivi on public.contenus
  for update to demelo_pipeline using (not est_test) with check (not est_test);
create policy pipeline_affirmations on public.affirmations
  for all to demelo_pipeline using (true) with check (true);   -- le trigger 8.1 contrôle tout
create policy pipeline_preuves on public.preuves
  for all to demelo_pipeline using (true) with check (true);   -- le trigger 8.2 contrôle tout

commit;
