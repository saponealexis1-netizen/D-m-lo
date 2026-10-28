-- Les 3 comptes de test exigés par supabase/rls_manuel/tests_sql_editor.sql.
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000e001', 'editeur@demelo.test',   '{"role_equipe": "editeur"}'),
  ('00000000-0000-0000-0000-00000000e002', 'relecteur@demelo.test', '{"role_equipe": "relecteur"}'),
  ('00000000-0000-0000-0000-00000000e003', 'visiteur@demelo.test',  '{}');
