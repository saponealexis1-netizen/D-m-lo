-- La sauvegarde rejouée doit reproduire l'état relevé sur le projet le 2026-10-28.
do $$
declare
  v_tables int; v_policies int; v_triggers int; v_cron int; v_rls int;
begin
  select count(*) into v_tables from pg_tables where schemaname = 'public';
  select count(*) into v_rls from pg_tables where schemaname = 'public' and rowsecurity;
  select count(*) into v_policies from pg_policies where schemaname = 'public';
  select count(*) into v_triggers from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where not t.tgisinternal and (c.relnamespace = 'public'::regnamespace or t.tgname = 'apres_creation_utilisateur');
  select count(*) into v_cron from cron.job;
  if (v_tables, v_rls, v_policies, v_triggers, v_cron) <> (13, 13, 34, 5, 2) then
    raise exception 'Sauvegarde v1 incohérente : tables %, RLS %, policies %, triggers %, cron %',
      v_tables, v_rls, v_policies, v_triggers, v_cron;
  end if;
  if (select count(*) from public.parametres) <> 4 or (select count(*) from public.verdicts) <> 5
     or (select count(*) from public.medias) <> 9 or (select count(*) from public.organismes) <> 19 then
    raise exception 'Données de référence v1 incomplètes.';
  end if;
  raise notice 'Sauvegarde v1 rejouée : 13 tables, 13 RLS, 34 policies, 5 triggers, 2 cron, 37 lignes de référence.';
end $$;
