-- Démêlo v2 : l'équipe ne conserve que 15 sources de référence (institutions,
-- statistiques, juridique, AFP Factuel). Les 9 médias et 4 autres fact-checkeurs
-- sont retirés (aucun contenu ni aucune preuve ne les référençait).
delete from public.sources
 where nom not in ('INSEE', 'Eurostat', 'Légifrance', 'DARES', 'DREES', 'Banque de France',
                   'SSMSI (ministère de l''Intérieur)', 'Conseil constitutionnel', 'Sénat',
                   'Assemblée nationale', 'Cour des comptes', 'HATVP', 'Vie-publique.fr',
                   'Viginum (SGDSN)', 'AFP Factuel');

do $$
begin
  if (select count(*) from public.sources) <> 15 then
    raise exception 'Il devrait rester exactement 15 sources.';
  end if;
end $$;