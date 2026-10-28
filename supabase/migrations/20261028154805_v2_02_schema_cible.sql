-- Démêlo v2, étape 2/3 : 4 tables métier, base FERMÉE (RLS activée, 0 policy, 0 GRANT client),
-- triggers de validation humaine, vue v_feed_verifie. Policies et GRANT : configuration manuelle.

-- 0. Schéma privé pour les fonctions internes (non exposé par l'API)
create schema prive;
revoke all on schema prive from public;
grant usage on schema prive to anon, authenticated, service_role;

-- 1. Types
create type public.type_source           as enum ('media', 'institution', 'statistique', 'juridique', 'fact_checking');
create type public.mode_collecte         as enum ('manuel', 'rss');
create type public.licence_reutilisation as enum ('ouverte', 'lien_seulement');
create type public.format_contenu        as enum ('article');
create type public.theme_contenu         as enum ('economie', 'ecologie', 'institutions', 'societe', 'international', 'autre');
create type public.statut_workflow       as enum ('brouillon', 'en_relecture', 'publie', 'retire');
create type public.verdict_affirmation   as enum ('vrai', 'faux', 'trompeur', 'non_verifiable');
create type public.type_relation_preuve  as enum ('confirme', 'contredit', 'contextualise');

-- 2. Tables — RLS activée immédiatement après chaque création
create table public.sources (
  id                       bigint generated always as identity primary key,
  nom                      text not null unique check (char_length(nom) between 2 and 200),
  type_source              public.type_source not null,
  url_base                 text not null check (url_base ~* '^https?://'),
  reutilisation            public.licence_reutilisation not null default 'lien_seulement',
  licence_info             text check (char_length(licence_info) <= 500),
  mode_collecte            public.mode_collecte not null default 'manuel',
  flux_url                 text check (flux_url ~* '^https?://'),
  frequence_collecte_jours integer not null default 7 check (frequence_collecte_jours between 1 and 90),
  derniere_collecte_le     timestamptz,
  derniere_erreur_collecte text check (char_length(derniere_erreur_collecte) <= 1000),
  active                   boolean not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  check (mode_collecte <> 'rss' or flux_url is not null)
);
alter table public.sources enable row level security;

create table public.contenus (
  id                  bigint generated always as identity primary key,
  source_id           bigint not null references public.sources (id) on delete restrict,
  format              public.format_contenu not null default 'article',
  titre               text not null check (char_length(titre) between 3 and 500),
  url_originale       text not null unique check (url_originale ~* '^https?://'),
  identifiant_externe text check (char_length(identifiant_externe) <= 500),
  theme               public.theme_contenu,
  resume              text check (char_length(resume) <= 600),
  date_publication    timestamptz,
  visible_public      boolean not null default true,
  date_collecte       timestamptz not null default now(),
  vu_le               timestamptz not null default now(),
  lot_import          text check (char_length(lot_import) <= 100),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (source_id, identifiant_externe)
);
alter table public.contenus enable row level security;

create table public.affirmations (
  id                bigint generated always as identity primary key,
  contenu_id        bigint not null references public.contenus (id) on delete restrict,
  texte_affirmation text not null check (char_length(texte_affirmation) between 10 and 400),
  localisation      text check (char_length(localisation) <= 200),
  score_priorite    integer check (score_priorite between 0 and 100),
  verdict           public.verdict_affirmation,
  explication       text check (char_length(explication) <= 2000),
  limites           text check (char_length(limites) <= 1000),
  statut_workflow   public.statut_workflow not null default 'brouillon',
  created_by        uuid not null default auth.uid() references auth.users (id) on delete restrict,
  reviewed_by       uuid references auth.users (id) on delete restrict,
  reviewed_at       timestamptz,
  published_at      timestamptz,
  version           integer not null default 1 check (version >= 1),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (statut_workflow not in ('en_relecture', 'publie') or (verdict is not null and explication is not null)),
  check (statut_workflow <> 'publie' or (reviewed_by is not null and reviewed_at is not null and published_at is not null)),
  check (reviewed_by is null or reviewed_by <> created_by)
);
alter table public.affirmations enable row level security;

create table public.preuves (
  id                bigint generated always as identity primary key,
  affirmation_id    bigint not null references public.affirmations (id) on delete cascade,
  source_id         bigint not null references public.sources (id) on delete restrict,
  url_preuve        text not null check (url_preuve ~* '^https?://'),
  type_relation     public.type_relation_preuve not null,
  note              text check (char_length(note) <= 1000),
  extrait           text check (char_length(extrait) <= 400),
  date_document     date,
  date_consultation date not null default current_date,
  ajoutee_par       uuid not null default auth.uid() references auth.users (id) on delete restrict,
  created_at        timestamptz not null default now(),
  unique (affirmation_id, url_preuve)
);
alter table public.preuves enable row level security;

-- 3. Index
create index on public.contenus (source_id);
create index on public.contenus (date_publication desc);
create index on public.contenus (theme);
create index on public.affirmations (contenu_id);
create index on public.affirmations (statut_workflow);
create index on public.affirmations (created_by);
create index on public.affirmations (reviewed_by);
create index on public.preuves (affirmation_id);
create index on public.preuves (source_id);
create index on public.preuves (ajoutee_par);

-- 4. Rôles d'équipe (lus dans le JWT : app_metadata.role_equipe)
create function prive.role_equipe()
returns text
language sql stable
set search_path = ''
as $$
  select case
           when coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then null
           else auth.jwt() -> 'app_metadata' ->> 'role_equipe'
         end;
$$;

create function prive.est_membre()
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(prive.role_equipe() in ('editeur', 'relecteur'), false);
$$;

create function prive.est_relecteur()
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(prive.role_equipe() = 'relecteur', false);
$$;

-- 5. Triggers
create function prive.maj_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger maj_updated_at before update on public.sources
  for each row execute function prive.maj_updated_at();
create trigger maj_updated_at before update on public.contenus
  for each row execute function prive.maj_updated_at();
create trigger maj_updated_at before update on public.affirmations
  for each row execute function prive.maj_updated_at();

-- 5.2 Validation humaine des affirmations
create function prive.controler_affirmation()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_nb        integer;
  v_confirme  integer;
  v_contredit integer;
  v_contenu_modifie boolean;
begin
  if tg_op = 'INSERT' then
    if new.statut_workflow <> 'brouillon' then
      raise exception 'Une affirmation est toujours créée en brouillon.' using errcode = 'check_violation';
    end if;
    if v_uid is not null then
      new.created_by := v_uid;
    end if;
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.published_at := null;
    new.version := 1;
    return new;
  end if;

  if new.created_by is distinct from old.created_by or new.contenu_id is distinct from old.contenu_id then
    raise exception 'L''auteur et le contenu d''une affirmation ne sont pas modifiables.' using errcode = 'check_violation';
  end if;

  v_contenu_modifie :=
    (new.texte_affirmation, new.verdict, new.explication, new.limites,
     new.localisation, new.score_priorite)
    is distinct from
    (old.texte_affirmation, old.verdict, old.explication, old.limites,
     old.localisation, old.score_priorite);

  new.reviewed_by := old.reviewed_by;
  new.reviewed_at := old.reviewed_at;
  new.published_at := old.published_at;
  new.version := old.version;

  if new.statut_workflow = old.statut_workflow then
    if old.statut_workflow <> 'brouillon' and v_contenu_modifie then
      raise exception 'Affirmation « % » : repasser en brouillon pour la modifier.', old.statut_workflow
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  select count(*),
         count(*) filter (where p.type_relation = 'confirme'),
         count(*) filter (where p.type_relation = 'contredit')
    into v_nb, v_confirme, v_contredit
    from public.preuves p
   where p.affirmation_id = new.id;

  if new.statut_workflow = 'brouillon' then
    if old.statut_workflow in ('publie', 'retire') then
      if not prive.est_relecteur() then
        raise exception 'Seul un relecteur peut dépublier une affirmation.' using errcode = 'insufficient_privilege';
      end if;
      new.version := old.version + 1;
    end if;
    new.reviewed_by := null;
    new.reviewed_at := null;
    new.published_at := null;
    return new;
  end if;

  if old.statut_workflow = 'brouillon' and new.statut_workflow = 'en_relecture' then
    if v_nb < 1 then
      raise exception 'Envoi en relecture refusé : au moins une preuve est exigée.' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.statut_workflow = 'en_relecture' and new.statut_workflow = 'publie' then
    if v_uid is null then
      raise exception 'Publication refusée : elle exige un relecteur humain connecté (clé serveur interdite).'
        using errcode = 'insufficient_privilege';
    end if;
    if not prive.est_relecteur() then
      raise exception 'Publication refusée : réservée aux relecteurs.' using errcode = 'insufficient_privilege';
    end if;
    if v_uid = old.created_by then
      raise exception 'Publication refusée : le relecteur doit être différent de l''auteur.' using errcode = 'check_violation';
    end if;
    if v_contenu_modifie then
      raise exception 'Publication refusée : le relecteur valide le texte tel quel ; le renvoyer en brouillon pour le modifier.'
        using errcode = 'check_violation';
    end if;
    if v_nb < 1 then
      raise exception 'Publication refusée : aucune preuve.' using errcode = 'check_violation';
    end if;
    if new.verdict = 'vrai' and v_confirme < 1 then
      raise exception 'Publication refusée : le verdict « vrai » exige une preuve qui confirme.' using errcode = 'check_violation';
    end if;
    if new.verdict = 'faux' and v_contredit < 1 then
      raise exception 'Publication refusée : le verdict « faux » exige une preuve qui contredit.' using errcode = 'check_violation';
    end if;
    new.reviewed_by := v_uid;
    new.reviewed_at := now();
    new.published_at := now();
    return new;
  end if;

  if old.statut_workflow = 'publie' and new.statut_workflow = 'retire' then
    if not prive.est_relecteur() then
      raise exception 'Seul un relecteur peut retirer une affirmation.' using errcode = 'insufficient_privilege';
    end if;
    if v_contenu_modifie then
      raise exception 'Retrait refusé : le contenu ne change pas lors d''un retrait.' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  raise exception 'Transition interdite : % -> %.', old.statut_workflow, new.statut_workflow
    using errcode = 'check_violation';
end;
$$;

create trigger controler_affirmation
  before insert or update on public.affirmations
  for each row execute function prive.controler_affirmation();

-- 5.3 Preuves figées hors brouillon ; pas d'extrait pour une source sous licence
create function prive.controler_preuve()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_statut        public.statut_workflow;
  v_reutilisation public.licence_reutilisation;
begin
  select a.statut_workflow into v_statut
    from public.affirmations a
   where a.id = case when tg_op = 'DELETE' then old.affirmation_id else new.affirmation_id end;

  if tg_op = 'DELETE' and v_statut is null then
    return old;
  end if;

  if v_statut is distinct from 'brouillon' then
    raise exception 'Preuves figées : l''affirmation est « % » (repasser en brouillon pour les modifier).', v_statut
      using errcode = 'check_violation';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  select s.reutilisation into v_reutilisation from public.sources s where s.id = new.source_id;
  if v_reutilisation = 'lien_seulement' and new.extrait is not null then
    raise exception 'Extrait refusé : source sous licence, seuls le lien et une note sont autorisés.'
      using errcode = 'check_violation';
  end if;

  if tg_op = 'INSERT' and auth.uid() is not null then
    new.ajoutee_par := auth.uid();
  end if;
  return new;
end;
$$;

create trigger controler_preuve
  before insert or update or delete on public.preuves
  for each row execute function prive.controler_preuve();

-- 6. Vue du flux (security_invoker : applique la RLS de celui qui la lit)
create view public.v_feed_verifie
with (security_invoker = true) as
select
  c.id,
  c.titre,
  c.url_originale,
  c.format,
  c.theme,
  c.resume,
  c.date_publication,
  s.id   as source_id,
  s.nom  as source_nom,
  s.type_source,
  count(a.id) filter (where a.statut_workflow = 'publie')            as nb_affirmations_publiees,
  case when count(a.id) filter (where a.statut_workflow = 'publie') > 0
       then 'verifie' else 'non_verifie' end                          as statut_verification,
  max(a.published_at)                                                 as derniere_verification_le
from public.contenus c
join public.sources s on s.id = c.source_id
left join public.affirmations a on a.contenu_id = c.id
where c.visible_public
group by c.id, s.id;

-- 7. Fermeture par défaut (aucun accès client)
revoke all on public.sources, public.contenus, public.affirmations, public.preuves,
              public.v_feed_verifie
  from anon, authenticated;

revoke all on all functions in schema prive from public;
grant execute on function prive.role_equipe(), prive.est_membre(), prive.est_relecteur()
  to anon, authenticated, service_role;

revoke execute on function public.rls_auto_enable() from public, anon, authenticated;