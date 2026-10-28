-- Supprime les données créées par tests_api.mjs (SQL Editor, propriétaire de la base).
-- Ne touche qu'aux lignes marquées « [TEST-API] » / lot_import = 'test-rls-api'.
-- Commencer par vérifier ce qui sera supprimé :
select 'affirmations' as table_, count(*) from public.affirmations where texte_affirmation like '[TEST-API]%'
union all
select 'contenus', count(*) from public.contenus where lot_import = 'test-rls-api';

-- Puis supprimer (les preuves partent avec leur affirmation) :
-- delete from public.affirmations where texte_affirmation like '[TEST-API]%';
-- delete from public.contenus where lot_import = 'test-rls-api';
