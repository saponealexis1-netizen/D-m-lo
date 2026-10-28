-- État juste après les migrations, AVANT la configuration manuelle des RLS :
-- la base doit être entièrement fermée aux clients, brouillons compris.
\set QUIET on
\o /dev/null
set client_min_messages = warning;
create schema tests_fermee;
create table tests_fermee.resultats (n serial, nom text, ok boolean);
grant usage on schema tests_fermee to anon, authenticated;
grant insert on tests_fermee.resultats to anon, authenticated;
grant usage on sequence tests_fermee.resultats_n_seq to anon, authenticated;

-- Vrai si la requête est refusée (erreur de droits) pour le rôle courant.
create function tests_fermee.refuse(requete text) returns boolean language plpgsql as $$
begin
  execute requete;
  return false;
exception when insufficient_privilege then
  return true;
end $$;
grant execute on function tests_fermee.refuse(text) to anon, authenticated;

insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-0000000000f1', 'relecteur.fermee@test', '{"role_equipe": "relecteur"}');

-- Un brouillon existe déjà (créé par le propriétaire de la base).
insert into public.contenus (source_id, titre, url_originale)
values ((select id from public.sources where nom = 'INSEE'), 'Article de test fermé', 'https://www.lemonde.fr/test-ferme');
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-0000000000f1"}', false);
insert into public.affirmations (contenu_id, texte_affirmation)
values ((select id from public.contenus where url_originale = 'https://www.lemonde.fr/test-ferme'), 'Brouillon secret qui ne doit jamais fuiter.');

insert into tests_fermee.resultats (nom, ok)
select 'fermée : RLS activée sur les 4 tables, 0 policy',
       (select bool_and(rowsecurity) from pg_tables where schemaname = 'public')
       and not exists (select 1 from pg_policies where schemaname = 'public');
insert into tests_fermee.resultats (nom, ok)
select 'fermée : aucun droit pour anon/authenticated sur les tables et la vue',
       not exists (select 1 from information_schema.role_table_grants
                    where table_schema = 'public' and grantee in ('anon', 'authenticated'));

select set_config('request.jwt.claims', '{"role": "anon"}', false);
set role anon;
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon ne lit pas sources',      tests_fermee.refuse('select * from public.sources');
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon ne lit pas contenus',     tests_fermee.refuse('select * from public.contenus');
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon ne lit pas les brouillons', tests_fermee.refuse('select * from public.affirmations');
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon ne lit pas preuves',      tests_fermee.refuse('select * from public.preuves');
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon ne lit pas la vue',       tests_fermee.refuse('select * from public.v_feed_verifie');
insert into tests_fermee.resultats (nom, ok) select 'fermée : anon n''écrit pas',
  tests_fermee.refuse($$ insert into public.sources (nom, type_source, url_base) values ('X', 'media', 'https://x.fr') $$);
reset role;

-- Même un relecteur connecté n'a encore accès à rien.
select set_config('request.jwt.claims', '{"sub": "00000000-0000-0000-0000-0000000000f1", "role": "authenticated", "app_metadata": {"role_equipe": "relecteur"}}', false);
set role authenticated;
insert into tests_fermee.resultats (nom, ok) select 'fermée : relecteur ne lit pas les brouillons', tests_fermee.refuse('select * from public.affirmations');
insert into tests_fermee.resultats (nom, ok) select 'fermée : relecteur n''écrit pas',
  tests_fermee.refuse($$ insert into public.contenus (source_id, titre, url_originale) values (1, 'X', 'https://x.fr/1') $$);
reset role;

-- Nettoyage des données de ce test.
delete from public.affirmations where texte_affirmation like 'Brouillon secret%';
delete from public.contenus where url_originale = 'https://www.lemonde.fr/test-ferme';
delete from auth.users where id = '00000000-0000-0000-0000-0000000000f1';

\o
\set QUIET off
select case when ok then 'OK   ' else 'ÉCHEC' end as resultat, nom from tests_fermee.resultats order by n;
do $$ begin
  if exists (select 1 from tests_fermee.resultats where not ok) then raise exception 'Base non fermée.'; end if;
end $$;
drop schema tests_fermee cascade;
