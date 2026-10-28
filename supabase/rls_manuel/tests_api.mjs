// Tests RLS « bout en bout » via l'API REST Supabase, avec de vrais JWT.
//
// C'est exactement le chemin du futur front : clé publique + connexion.
// À lancer APRÈS la configuration manuelle des RLS (docs/tutoriel-rls.md, étape 7).
// Le pipeline IA n'est pas testé ici : il n'utilise pas l'API mais son rôle serveur.
//
// Variables d'environnement (jamais commitées, jamais la clé secrète) :
//   SUPABASE_URL                  https://<ref>.supabase.co
//   SUPABASE_PUBLISHABLE_KEY      clé publique (sb_publishable_... ou anon)
//   DEMELO_ADMIN_EMAIL / DEMELO_ADMIN_MDP
//   DEMELO_VISITEUR_EMAIL / DEMELO_VISITEUR_MDP     compte connecté sans rôle
//
// Usage : node supabase/rls_manuel/tests_api.mjs   (Node 18+, aucune dépendance)
//
// Le script crée un article MASQUÉ, une donnée fictive et une affirmation « [TEST-API] »
// non publiée. Les supprimer ensuite avec supabase/rls_manuel/nettoyage_tests_api.sql.

const URL_PROJET = process.env.SUPABASE_URL?.replace(/\/$/, "");
const CLE = process.env.SUPABASE_PUBLISHABLE_KEY;
if (!URL_PROJET || !CLE) {
  console.error("Définir SUPABASE_URL et SUPABASE_PUBLISHABLE_KEY.");
  process.exit(2);
}
if (CLE.startsWith("sb_secret_") || jwtRole(CLE) === "service_role") {
  console.error("Refus : c'est une clé SECRÈTE. Utiliser la clé publique.");
  process.exit(2);
}

const resultats = [];
const marque = `[TEST-API] ${new Date().toISOString()}`;
const suffixe = Date.now();

// --- Outils -----------------------------------------------------------
function jwtRole(jeton) {
  try {
    return JSON.parse(Buffer.from(jeton.split(".")[1], "base64url").toString()).role;
  } catch {
    return null;
  }
}

async function connexion(prefixe) {
  const email = process.env[`DEMELO_${prefixe}_EMAIL`];
  const mdp = process.env[`DEMELO_${prefixe}_MDP`];
  if (!email || !mdp) throw new Error(`Définir DEMELO_${prefixe}_EMAIL et DEMELO_${prefixe}_MDP.`);
  const res = await fetch(`${URL_PROJET}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: CLE, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: mdp }),
  });
  const corps = await res.json();
  if (!res.ok) throw new Error(`Connexion ${prefixe} impossible : ${corps.msg ?? corps.error_description ?? res.status}`);
  return { jeton: corps.access_token, rafraichir: corps.refresh_token, id: corps.user.id, app: corps.user.app_metadata };
}

async function api(qui, methode, chemin, corps) {
  const res = await fetch(`${URL_PROJET}/rest/v1/${chemin}`, {
    method: methode,
    headers: {
      apikey: CLE,
      Authorization: `Bearer ${qui?.jeton ?? CLE}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: corps ? JSON.stringify(corps) : undefined,
  });
  const texte = await res.text();
  let donnees = null;
  try { donnees = texte ? JSON.parse(texte) : null; } catch { donnees = texte; }
  return { statut: res.status, donnees, lignes: Array.isArray(donnees) ? donnees.length : 0 };
}

// attendu : nombre de lignes (réussite) ou "bloque" (erreur HTTP ou 0 ligne).
function verifier(code, test, r, attendu) {
  const ok = attendu === "bloque"
    ? r.statut >= 400 || r.lignes === 0
    : r.statut < 300 && r.lignes === attendu;
  const obtenu = r.statut >= 400 ? `HTTP ${r.statut} ${r.donnees?.message ?? ""}`.trim() : `HTTP ${r.statut}, ${r.lignes} ligne(s)`;
  resultats.push({ ok, code, test, obtenu });
  console.log(`${ok ? "✅" : "❌"} ${code.padEnd(4)} ${test} — ${obtenu}`);
  return r;
}

// --- Scénario ---------------------------------------------------------
const anon = null;
const admin = await connexion("ADMIN");
const visiteur = await connexion("VISITEUR");
console.log(`Rôles lus dans le JWT : admin=${admin.app?.role_equipe}, visiteur=${visiteur.app?.role_equipe ?? "aucun"}\n`);

verifier("P1", "anon lit les organismes actifs (15)", await api(anon, "GET", "sources?select=id&active=eq.true"), 15);
verifier("G1", "anon ne peut pas créer d'organisme",
  await api(anon, "POST", "sources", { nom: marque, type_source: "statistique", url_base: "https://demelo-test.example", perimetres: ["demelo-test.example"] }), "bloque");
verifier("P2", "compte sans rôle ne peut pas créer d'organisme",
  await api(visiteur, "POST", "sources", { nom: marque, type_source: "statistique", url_base: "https://demelo-test.example", perimetres: ["demelo-test.example"] }), "bloque");
verifier("P7", "anon ne voit aucune analyse interne",
  await api(anon, "GET", "affirmations?select=id&statut_analyse=not.in.(analyse_disponible,verification_insuffisante)"), 0);
verifier("P4", "anon ne voit aucune donnée fictive", await api(anon, "GET", "contenus?select=id&est_test=eq.true"), 0);

const contenu = verifier("P5", "admin indexe un article (masqué)",
  await api(admin, "POST", "contenus", {
    media_nom: "Média de test", titre: marque, url_originale: `https://www.demelo-test.example/${suffixe}`,
    visible_public: false, lot_import: "test-rls-api",
  }), 1).donnees?.[0];
verifier("P5", "admin ajoute une donnée fictive",
  await api(admin, "POST", "contenus", {
    media_nom: "Média fictif de test", titre: `[FICTIF] ${marque}`, url_originale: `https://demelo-test.invalid/${suffixe}`,
    est_test: true, lot_import: "test-rls-api",
  }), 1);
verifier("P5", "compte sans rôle ne peut pas indexer d'article",
  await api(visiteur, "POST", "contenus", { media_nom: "Pirate", titre: marque, url_originale: `https://www.demelo-test.example/v-${suffixe}` }), "bloque");
verifier("P4", "anon ne voit pas l'article masqué", await api(anon, "GET", `contenus?select=id&id=eq.${contenu?.id}`), 0);

const aff = verifier("P8", "admin crée une affirmation (non traitée)",
  await api(admin, "POST", "affirmations", { contenu_id: contenu?.id, texte_affirmation: `${marque} affirmation de test` }), 1).donnees?.[0];
verifier("P7", "anon ne voit pas l'affirmation non traitée", await api(anon, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 0);
verifier("P7", "compte sans rôle ne la voit pas non plus", await api(visiteur, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 0);
verifier("W1", "publication directe refusée (statut non_traite -> analyse_disponible)",
  await api(admin, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_analyse: "analyse_disponible", revue_motif: "test" }), "bloque");
verifier("P9", "compte sans rôle ne peut pas modifier",
  await api(visiteur, "PATCH", `affirmations?id=eq.${aff?.id}`, { contexte: "piraté" }), "bloque");
verifier("G3", "admin ne peut pas supprimer (pas de GRANT)", await api(admin, "DELETE", `affirmations?id=eq.${aff?.id}`), "bloque");

// Tentative d'élévation : le visiteur écrit role_equipe dans SES métadonnées (user_metadata).
await fetch(`${URL_PROJET}/auth/v1/user`, {
  method: "PUT",
  headers: { apikey: CLE, Authorization: `Bearer ${visiteur.jeton}`, "Content-Type": "application/json" },
  body: JSON.stringify({ data: { role_equipe: "admin" } }),
});
const rafraichi = await (await fetch(`${URL_PROJET}/auth/v1/token?grant_type=refresh_token`, {
  method: "POST",
  headers: { apikey: CLE, "Content-Type": "application/json" },
  body: JSON.stringify({ refresh_token: visiteur.rafraichir }),
})).json();
const visiteurRafraichi = { jeton: rafraichi.access_token ?? visiteur.jeton };
verifier("P4", "élévation via user_metadata sans effet : fictifs toujours invisibles",
  await api(visiteurRafraichi, "GET", "contenus?select=id&est_test=eq.true"), 0);
verifier("P9", "élévation via user_metadata sans effet : modification refusée",
  await api(visiteurRafraichi, "PATCH", `affirmations?id=eq.${aff?.id}`, { contexte: "piraté" }), "bloque");
await fetch(`${URL_PROJET}/auth/v1/user`, {
  method: "PUT",
  headers: { apikey: CLE, Authorization: `Bearer ${visiteurRafraichi.jeton}`, "Content-Type": "application/json" },
  body: JSON.stringify({ data: { role_equipe: null } }),
});

verifier("G5", "anon lit la fiche publique (vue)", await api(anon, "GET", "v_analyses_publiques?select=id&limit=1"),
  (await api(admin, "GET", "v_analyses_publiques?select=id&limit=1")).lignes);

const echecs = resultats.filter((r) => !r.ok).length;
console.log(`\n${resultats.length - echecs} ✅ / ${echecs} ❌`);
console.log("Nettoyage : exécuter supabase/rls_manuel/nettoyage_tests_api.sql dans le SQL Editor.");
process.exit(echecs ? 1 : 0);
