-- Contrôle le tableau produit par tests_sql_editor.sql selon l'état attendu (:etat).
\o
select statut, count(*) from resultats_rls group by statut order by statut;
select statut, code, test, obtenu from resultats_rls where statut <> '✅' order by n;
do $$
declare v_etat text := current_setting('demelo.etat');
begin
  if (select count(*) from resultats_rls) < 40 then raise exception 'Trop peu d''essais.'; end if;
  if exists (select 1 from resultats_rls where statut = '❌') then raise exception 'Essai non conforme (❌).'; end if;
  if v_etat = 'configure' and exists (select 1 from resultats_rls where statut <> '✅') then
    raise exception 'Après configuration, tout doit être ✅.';
  end if;
  if v_etat = 'ferme' and exists (select 1 from resultats_rls where statut = '✅' and attendu not in ('bloque', 'refus_droit')) then
    raise exception 'Base fermée : aucun accès ne doit réussir.';
  end if;
  if (select count(*) from public.affirmations where texte_affirmation like '[TEST]%')
   + (select count(*) from public.contenus where url_originale like '%demelo-test%')
   + (select count(*) from public.sources where nom like '[TEST]%') > 0 then
    raise exception 'Des données de test sont restées en base.';
  end if;
end $$;
