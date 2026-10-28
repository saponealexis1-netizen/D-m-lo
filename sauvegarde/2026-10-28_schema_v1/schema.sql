-- =====================================================================
--  Sauvegarde du schéma Supabase « v1 » de Démêlo (avant reconstruction)
-- =====================================================================
--  Projet  : aoysmqeasnfnyvmfwktt (« saponealexis1-netizen's SQL », eu-west-2)
--  Date    : 2026-10-28, export en lecture seule depuis le catalogue PostgreSQL
--            (pg_catalog, pg_policies, cron.job) via le connecteur Supabase.
--  Contenu : types, tables, contraintes, index, fonctions, triggers, vue,
--            RLS, policies, droits et tâches pg_cron du schéma public.
--  Exclus  : aucune donnée utilisateur (0 compte), aucun secret (Vault vide),
--            objets gérés par Supabase (event trigger ensure_rls, voir README).
--
--  Ce fichier documente l'existant : il n'est PAS destiné à être rejoué tel
--  quel sur le projet. Extensions requises : vector (schéma extensions), pg_cron.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------
create type public.auteur_message as enum ('utilisateur', 'assistant');
create type public.reutilisation as enum ('ouverte', 'lien_seulement');
create type public.role_utilisateur as enum ('viewer', 'editeur', 'admin');
create type public.statut_affirmation as enum ('brouillon', 'publie', 'a_verifier', 'retire');
create type public.statut_article as enum ('en_attente', 'en_cours', 'traite', 'inaccessible', 'erreur');
create type public.type_organisme as enum ('statistique', 'juridique', 'institution', 'fact_checking', 'securite_information');


-- ---------------------------------------------------------------------
-- Tables (13)
-- ---------------------------------------------------------------------
create table public.affirmation_candidats (
  affirmation_id bigint not null,
  candidat_id bigint not null
);

create table public.affirmation_sources (
  affirmation_id bigint not null,
  source_id bigint not null
);

create table public.affirmations (
  id bigint generated always as identity not null,
  article_id bigint not null,
  citation text not null,
  verdict text not null default 'non_verifiable'::text,
  explication text not null,
  statut statut_affirmation not null default 'brouillon'::statut_affirmation,
  nb_signalements integer not null default 0,
  publie_le timestamp with time zone,
  created_at timestamp with time zone not null default now()
);

create table public.articles (
  id bigint generated always as identity not null,
  media_id bigint not null,
  url text not null,
  titre text not null,
  resume text,
  publie_le timestamp with time zone,
  ajoute_par uuid,
  statut statut_article not null default 'en_attente'::statut_article,
  created_at timestamp with time zone not null default now()
);

create table public.candidats (
  id bigint generated always as identity not null,
  nom text not null,
  parti text,
  statut_candidature text,
  source_url text,
  created_at timestamp with time zone not null default now()
);

create table public.medias (
  id bigint generated always as identity not null,
  nom text not null,
  site_url text not null,
  flux_rss_url text,
  created_at timestamp with time zone not null default now()
);

create table public.messages (
  id bigint generated always as identity not null,
  user_id uuid not null default auth.uid(),
  auteur auteur_message not null default 'utilisateur'::auteur_message,
  contenu text not null,
  created_at timestamp with time zone not null default now()
);

create table public.organismes (
  id bigint generated always as identity not null,
  nom text not null,
  site_url text not null,
  type type_organisme not null,
  reutilisation reutilisation not null,
  actif boolean not null default true,
  created_at timestamp with time zone not null default now()
);

create table public.parametres (
  cle text not null,
  valeur integer not null,
  description text not null
);

create table public.profils (
  id uuid not null,
  role role_utilisateur not null default 'viewer'::role_utilisateur,
  created_at timestamp with time zone not null default now()
);

create table public.signalements (
  id bigint generated always as identity not null,
  affirmation_id bigint not null,
  user_id uuid not null default auth.uid(),
  motif text,
  created_at timestamp with time zone not null default now()
);

create table public.sources (
  id bigint generated always as identity not null,
  organisme_id bigint not null,
  titre text not null,
  url text not null,
  extrait text,
  embedding extensions.vector(1024),
  publie_le date,
  mis_a_jour_le timestamp with time zone not null default now(),
  created_at timestamp with time zone not null default now()
);

create table public.verdicts (
  code text not null,
  libelle text not null,
  description text not null,
  sources_min integer not null,
  ordre integer not null
);


-- ---------------------------------------------------------------------
-- Contraintes (clés primaires, uniques, checks, clés étrangères)
-- ---------------------------------------------------------------------
alter table public.affirmation_candidats add constraint affirmation_candidats_pkey PRIMARY KEY (affirmation_id, candidat_id);
alter table public.affirmation_sources add constraint affirmation_sources_pkey PRIMARY KEY (affirmation_id, source_id);
alter table public.affirmations add constraint affirmations_pkey PRIMARY KEY (id);
alter table public.affirmations add constraint affirmations_citation_check CHECK (((char_length(citation) >= 10) AND (char_length(citation) <= 400)));
alter table public.articles add constraint articles_pkey PRIMARY KEY (id);
alter table public.articles add constraint articles_url_key UNIQUE (url);
alter table public.articles add constraint articles_resume_check CHECK ((char_length(resume) <= 600));
alter table public.articles add constraint articles_url_check CHECK ((url ~* '^https?://'::text));
alter table public.candidats add constraint candidats_pkey PRIMARY KEY (id);
alter table public.candidats add constraint candidats_nom_key UNIQUE (nom);
alter table public.medias add constraint medias_pkey PRIMARY KEY (id);
alter table public.medias add constraint medias_nom_key UNIQUE (nom);
alter table public.messages add constraint messages_pkey PRIMARY KEY (id);
alter table public.messages add constraint messages_check CHECK ((((auteur = 'utilisateur'::auteur_message) AND ((char_length(contenu) >= 1) AND (char_length(contenu) <= 1000))) OR ((auteur = 'assistant'::auteur_message) AND ((char_length(contenu) >= 1) AND (char_length(contenu) <= 8000)))));
alter table public.organismes add constraint organismes_pkey PRIMARY KEY (id);
alter table public.organismes add constraint organismes_nom_key UNIQUE (nom);
alter table public.parametres add constraint parametres_pkey PRIMARY KEY (cle);
alter table public.parametres add constraint parametres_valeur_check CHECK ((valeur >= 0));
alter table public.profils add constraint profils_pkey PRIMARY KEY (id);
alter table public.signalements add constraint signalements_pkey PRIMARY KEY (id);
alter table public.signalements add constraint signalements_affirmation_id_user_id_key UNIQUE (affirmation_id, user_id);
alter table public.signalements add constraint signalements_motif_check CHECK ((char_length(motif) <= 500));
alter table public.sources add constraint sources_pkey PRIMARY KEY (id);
alter table public.sources add constraint sources_url_key UNIQUE (url);
alter table public.sources add constraint sources_url_check CHECK ((url ~* '^https?://'::text));
alter table public.verdicts add constraint verdicts_pkey PRIMARY KEY (code);
alter table public.verdicts add constraint verdicts_sources_min_check CHECK ((sources_min >= 0));

-- Clés étrangères (après toutes les clés primaires et uniques)
alter table public.affirmation_candidats add constraint affirmation_candidats_affirmation_id_fkey FOREIGN KEY (affirmation_id) REFERENCES affirmations(id) ON DELETE CASCADE;
alter table public.affirmation_candidats add constraint affirmation_candidats_candidat_id_fkey FOREIGN KEY (candidat_id) REFERENCES candidats(id) ON DELETE RESTRICT;
alter table public.affirmation_sources add constraint affirmation_sources_affirmation_id_fkey FOREIGN KEY (affirmation_id) REFERENCES affirmations(id) ON DELETE CASCADE;
alter table public.affirmation_sources add constraint affirmation_sources_source_id_fkey FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE RESTRICT;
alter table public.affirmations add constraint affirmations_article_id_fkey FOREIGN KEY (article_id) REFERENCES articles(id) ON DELETE CASCADE;
alter table public.affirmations add constraint affirmations_verdict_fkey FOREIGN KEY (verdict) REFERENCES verdicts(code);
alter table public.articles add constraint articles_ajoute_par_fkey FOREIGN KEY (ajoute_par) REFERENCES profils(id) ON DELETE SET NULL;
alter table public.articles add constraint articles_media_id_fkey FOREIGN KEY (media_id) REFERENCES medias(id) ON DELETE RESTRICT;
alter table public.messages add constraint messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.profils add constraint profils_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.signalements add constraint signalements_affirmation_id_fkey FOREIGN KEY (affirmation_id) REFERENCES affirmations(id) ON DELETE CASCADE;
alter table public.signalements add constraint signalements_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
alter table public.sources add constraint sources_organisme_id_fkey FOREIGN KEY (organisme_id) REFERENCES organismes(id) ON DELETE RESTRICT;


-- ---------------------------------------------------------------------
-- Index (hors index des clés primaires et uniques)
-- ---------------------------------------------------------------------
CREATE INDEX affirmation_candidats_candidat_id_idx ON public.affirmation_candidats USING btree (candidat_id);
CREATE INDEX affirmation_sources_source_id_idx ON public.affirmation_sources USING btree (source_id);
CREATE INDEX affirmations_article_id_idx ON public.affirmations USING btree (article_id);
CREATE INDEX affirmations_statut_idx ON public.affirmations USING btree (statut);
CREATE INDEX articles_media_id_idx ON public.articles USING btree (media_id);
CREATE INDEX articles_statut_idx ON public.articles USING btree (statut);
CREATE INDEX messages_created_at_idx ON public.messages USING btree (created_at) WHERE (auteur = 'utilisateur'::auteur_message);
CREATE INDEX messages_user_id_created_at_idx ON public.messages USING btree (user_id, created_at);
CREATE INDEX sources_embedding_idx ON public.sources USING hnsw (embedding extensions.vector_cosine_ops);
CREATE INDEX sources_organisme_id_idx ON public.sources USING btree (organisme_id);


-- ---------------------------------------------------------------------
-- Fonctions (schéma public, hors rls_auto_enable gérée par Supabase)
-- ---------------------------------------------------------------------
-- Ordre alphabétique : comme pg_dump, on ne valide pas les corps à la création
-- (est_admin appelle est_anonyme et role_courant, définies plus bas).
set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.controler_source()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.creer_profil()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.profils (id) values (new.id);
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.est_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select not public.est_anonyme()
     and coalesce(public.role_courant() = 'admin', false);
$function$;

CREATE OR REPLACE FUNCTION public.est_anonyme()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
$function$;

CREATE OR REPLACE FUNCTION public.est_editeur()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select not public.est_anonyme()
     and coalesce(public.role_courant() in ('editeur', 'admin'), false);
$function$;

CREATE OR REPLACE FUNCTION public.proteger_sources_publiees()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.questions_restantes()
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.rechercher_sources(requete extensions.vector, nb integer DEFAULT 5)
 RETURNS TABLE(id bigint, titre text, url text, extrait text, organisme text, similarite double precision)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  select s.id, s.titre, s.url, s.extrait, o.nom,
         1 - (s.embedding <=> requete) as similarite
    from public.sources s
    join public.organismes o on o.id = s.organisme_id
   where s.embedding is not null
     and o.actif
   order by s.embedding <=> requete
   limit least(greatest(nb, 1), 20);
$function$;

CREATE OR REPLACE FUNCTION public.role_courant()
 RETURNS role_utilisateur
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p.role from public.profils p where p.id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.traiter_signalement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.verifier_sources_avant_publication()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;


-- ---------------------------------------------------------------------
-- Triggers (dont un sur auth.users)
-- ---------------------------------------------------------------------
CREATE TRIGGER apres_suppression_preuve AFTER DELETE ON public.affirmation_sources FOR EACH ROW EXECUTE FUNCTION proteger_sources_publiees();
CREATE TRIGGER avant_publication_affirmation BEFORE INSERT OR UPDATE ON public.affirmations FOR EACH ROW EXECUTE FUNCTION verifier_sources_avant_publication();
CREATE TRIGGER apres_signalement AFTER INSERT ON public.signalements FOR EACH ROW EXECUTE FUNCTION traiter_signalement();
CREATE TRIGGER avant_ecriture_source BEFORE INSERT OR UPDATE ON public.sources FOR EACH ROW EXECUTE FUNCTION controler_source();
CREATE TRIGGER apres_creation_utilisateur AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION creer_profil();


-- ---------------------------------------------------------------------
-- Vue
-- ---------------------------------------------------------------------
create view public.affirmations_publiques with (security_invoker=true) as
 SELECT a.id,
    a.citation,
    a.verdict,
    v.libelle AS verdict_libelle,
    a.explication,
    a.statut,
    a.nb_signalements,
    a.publie_le,
    ar.id AS article_id,
    ar.titre AS article_titre,
    ar.url AS article_url,
    ar.publie_le AS article_publie_le,
    m.nom AS media,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('nom', c.nom, 'parti', c.parti) ORDER BY c.nom) AS jsonb_agg
           FROM affirmation_candidats ac
             JOIN candidats c ON c.id = ac.candidat_id
          WHERE ac.affirmation_id = a.id), '[]'::jsonb) AS candidats,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('titre', s.titre, 'url', s.url, 'organisme', o.nom) ORDER BY o.nom, s.titre) AS jsonb_agg
           FROM affirmation_sources asr
             JOIN sources s ON s.id = asr.source_id
             JOIN organismes o ON o.id = s.organisme_id
          WHERE asr.affirmation_id = a.id), '[]'::jsonb) AS sources
   FROM affirmations a
     JOIN verdicts v ON v.code = a.verdict
     JOIN articles ar ON ar.id = a.article_id
     JOIN medias m ON m.id = ar.media_id
  WHERE a.statut = ANY (ARRAY['publie'::statut_affirmation, 'a_verifier'::statut_affirmation]);


-- ---------------------------------------------------------------------
-- Row Level Security (activée sur les 13 tables, sans FORCE)
-- ---------------------------------------------------------------------
alter table public.affirmation_candidats enable row level security;
alter table public.affirmation_sources enable row level security;
alter table public.affirmations enable row level security;
alter table public.articles enable row level security;
alter table public.candidats enable row level security;
alter table public.medias enable row level security;
alter table public.messages enable row level security;
alter table public.organismes enable row level security;
alter table public.parametres enable row level security;
alter table public.profils enable row level security;
alter table public.signalements enable row level security;
alter table public.sources enable row level security;
alter table public.verdicts enable row level security;


-- ---------------------------------------------------------------------
-- Policies (34)
-- ---------------------------------------------------------------------
create policy candidats_concernes_ajout on public.affirmation_candidats as permissive for insert to authenticated
  with check (( SELECT est_editeur() AS est_editeur));
create policy candidats_concernes_lecture on public.affirmation_candidats as permissive for select to anon, authenticated
  using ((EXISTS ( SELECT 1
   FROM affirmations a
  WHERE (a.id = affirmation_candidats.affirmation_id))));
create policy candidats_concernes_suppression on public.affirmation_candidats as permissive for delete to authenticated
  using (( SELECT est_editeur() AS est_editeur));
create policy preuves_ajout on public.affirmation_sources as permissive for insert to authenticated
  with check (( SELECT est_editeur() AS est_editeur));
create policy preuves_lecture on public.affirmation_sources as permissive for select to anon, authenticated
  using ((EXISTS ( SELECT 1
   FROM affirmations a
  WHERE (a.id = affirmation_sources.affirmation_id))));
create policy preuves_suppression on public.affirmation_sources as permissive for delete to authenticated
  using (( SELECT est_editeur() AS est_editeur));
create policy affirmations_lecture on public.affirmations as permissive for select to anon, authenticated
  using (((statut = ANY (ARRAY['publie'::statut_affirmation, 'a_verifier'::statut_affirmation])) OR ( SELECT est_editeur() AS est_editeur)));
create policy affirmations_modif on public.affirmations as permissive for update to authenticated
  using (( SELECT est_editeur() AS est_editeur))
  with check (( SELECT est_editeur() AS est_editeur));
create policy affirmations_suppression on public.affirmations as permissive for delete to authenticated
  using (( SELECT est_admin() AS est_admin));
create policy articles_ajout on public.articles as permissive for insert to authenticated
  with check ((( SELECT est_editeur() AS est_editeur) AND (ajoute_par = ( SELECT auth.uid() AS uid)) AND (statut = 'en_attente'::statut_article)));
create policy articles_lecture on public.articles as permissive for select to anon, authenticated
  using (((statut = 'traite'::statut_article) OR ( SELECT est_editeur() AS est_editeur)));
create policy articles_modif on public.articles as permissive for update to authenticated
  using (( SELECT est_editeur() AS est_editeur))
  with check (( SELECT est_editeur() AS est_editeur));
create policy articles_suppression on public.articles as permissive for delete to authenticated
  using (( SELECT est_admin() AS est_admin));
create policy candidats_ecriture on public.candidats as permissive for all to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy candidats_lecture on public.candidats as permissive for select to anon, authenticated
  using (true);
create policy medias_ajout on public.medias as permissive for insert to authenticated
  with check (( SELECT est_editeur() AS est_editeur));
create policy medias_lecture on public.medias as permissive for select to anon, authenticated
  using (true);
create policy medias_modif on public.medias as permissive for update to authenticated
  using (( SELECT est_editeur() AS est_editeur))
  with check (( SELECT est_editeur() AS est_editeur));
create policy medias_suppression on public.medias as permissive for delete to authenticated
  using (( SELECT est_admin() AS est_admin));
create policy messages_lecture on public.messages as permissive for select to authenticated
  using ((user_id = ( SELECT auth.uid() AS uid)));
create policy messages_question on public.messages as permissive for insert to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (auteur = 'utilisateur'::auteur_message) AND (questions_restantes() > 0)));
create policy organismes_ecriture on public.organismes as permissive for all to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy organismes_lecture on public.organismes as permissive for select to anon, authenticated
  using (true);
create policy parametres_ecriture on public.parametres as permissive for all to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy parametres_lecture on public.parametres as permissive for select to authenticated
  using (( SELECT est_editeur() AS est_editeur));
create policy profils_lecture on public.profils as permissive for select to authenticated
  using (((id = ( SELECT auth.uid() AS uid)) OR ( SELECT est_admin() AS est_admin)));
create policy profils_modif_admin on public.profils as permissive for update to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy signalements_ajout on public.signalements as permissive for insert to authenticated
  with check (((user_id = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM affirmations a
  WHERE ((a.id = signalements.affirmation_id) AND (a.statut = ANY (ARRAY['publie'::statut_affirmation, 'a_verifier'::statut_affirmation])))))));
create policy signalements_lecture on public.signalements as permissive for select to authenticated
  using (((user_id = ( SELECT auth.uid() AS uid)) OR ( SELECT est_editeur() AS est_editeur)));
create policy signalements_suppression on public.signalements as permissive for delete to authenticated
  using (( SELECT est_admin() AS est_admin));
create policy sources_ecriture on public.sources as permissive for all to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy sources_lecture on public.sources as permissive for select to anon, authenticated
  using (true);
create policy verdicts_ecriture on public.verdicts as permissive for all to authenticated
  using (( SELECT est_admin() AS est_admin))
  with check (( SELECT est_admin() AS est_admin));
create policy verdicts_lecture on public.verdicts as permissive for select to anon, authenticated
  using (true);


-- ---------------------------------------------------------------------
-- Droits relevés (ACL), traduits en GRANT
-- ---------------------------------------------------------------------
-- service_role : TRUNCATE, REFERENCES, TRIGGER, MAINTAIN sur toutes les tables
-- (lecture/écriture via le contournement de la RLS de la clé service_role).
grant select on public.affirmation_candidats, public.affirmation_sources, public.affirmations,
  public.affirmations_publiques, public.articles, public.candidats, public.medias,
  public.organismes, public.sources, public.verdicts to anon;
grant select, insert, delete on public.affirmation_candidats, public.affirmation_sources, public.signalements to authenticated;
grant select, update, delete on public.affirmations to authenticated;
grant select on public.affirmations_publiques to authenticated;
grant select, insert, update, delete on public.articles, public.candidats, public.medias,
  public.organismes, public.parametres, public.sources, public.verdicts to authenticated;
grant select, insert on public.messages to authenticated;
grant select, update on public.profils to authenticated;

-- Fonctions : droits d'exécution relevés
--   controler_source, creer_profil, proteger_sources_publiees,
--   traiter_signalement, verifier_sources_avant_publication : postgres uniquement
--   est_admin, est_anonyme, est_editeur, questions_restantes,
--   rechercher_sources, role_courant, rls_auto_enable : PUBLIC (défaut)
-- Pour reproduire exactement ces droits en cas de reconstruction complète :
revoke execute on function
  public.controler_source(), public.creer_profil(), public.proteger_sources_publiees(),
  public.traiter_signalement(), public.verifier_sources_avant_publication()
from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- Tâches pg_cron
-- ---------------------------------------------------------------------
select cron.schedule('purge-messages-chatbot', '15 3 * * *',
  $$ delete from public.messages
      where created_at < now() - make_interval(
        days => (select valeur from public.parametres where cle = 'retention_messages_jours')
      ) $$);

select cron.schedule('purge-visiteurs-anonymes', '30 3 * * *',
  $$ delete from auth.users
      where is_anonymous is true
        and coalesce(last_sign_in_at, created_at) < now() - interval '30 days' $$);
