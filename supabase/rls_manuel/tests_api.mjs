// Tests RLS « bout en bout » via l'API REST Supabase, avec de vrais JWT.
//
// C'est exactement le chemin d'un futur front : clé publique + connexion.
// À lancer APRÈS la configuration manuelle des RLS (docs/tutoriel-rls.md, étape 6).
//
// Variables d'environnement (jamais commitées, jamais la clé secrète) :
//   SUPABASE_URL                  https://<ref>.supabase.co
//   SUPABASE_PUBLISHABLE_KEY      clé publique (sb_publishable_... ou anon)
//   DEMELO_EDITEUR_EMAIL / DEMELO_EDITEUR_MDP
//   DEMELO_RELECTEUR_EMAIL / DEMELO_RELECTEUR_MDP
//   DEMELO_VISITEUR_EMAIL / DEMELO_VISITEUR_MDP     compte connecté sans rôle
//
// Usage : node supabase/rls_manuel/tests_api.mjs   (Node 18+, aucune dépendance)
//
// Le script crée un article MASQUÉ et une affirmation « [TEST-API] », puis
// retire l'affirmation à la fin. Supprimer ensuite ces lignes avec
// supabase/rls_manuel/nettoyage_tests_api.sql (SQL Editor).

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
const editeur = await connexion("EDITEUR");
const relecteur = await connexion("RELECTEUR");
const visiteur = await connexion("VISITEUR");
console.log(`Rôles lus dans le JWT : éditeur=${editeur.app?.role_equipe}, relecteur=${relecteur.app?.role_equipe}, visiteur=${visiteur.app?.role_equipe ?? "aucun"}\n`);

const insee = (await api(anon, "GET", "sources?select=id&nom=eq.INSEE")).donnees?.[0]?.id;

verifier("P1", "anon lit les sources actives", await api(anon, "GET", "sources?select=id&nom=eq.INSEE"), 1);
verifier("G1", "anon ne peut pas créer de source",
  await api(anon, "POST", "sources", { nom: marque, type_source: "media", url_base: "https://test.invalid" }), "bloque");
verifier("P7", "anon ne voit aucune affirmation non publiée",
  await api(anon, "GET", "affirmations?select=id&statut_workflow=neq.publie"), 0);
verifier("P5", "compte sans rôle ne peut pas indexer d'article",
  await api(visiteur, "POST", "contenus", { source_id: insee, titre: marque, url_originale: `https://test.invalid/v-${Date.now()}` }), "bloque");

const contenu = verifier("P5", "éditeur indexe un article (masqué)",
  await api(editeur, "POST", "contenus", {
    source_id: insee, titre: marque, url_originale: `https://test.invalid/${Date.now()}`,
    visible_public: false, lot_import: "test-rls-api",
  }), 1).donnees?.[0];
verifier("P4", "anon ne voit pas l'article masqué", await api(anon, "GET", `contenus?select=id&id=eq.${contenu?.id}`), 0);

const aff = verifier("P8", "éditeur crée un brouillon",
  await api(editeur, "POST", "affirmations", {
    contenu_id: contenu?.id, texte_affirmation: `${marque} affirmation de test`,
    verdict: "vrai", explication: "Test automatique des RLS.",
  }), 1).donnees?.[0];
resultats.push({ ok: aff?.created_by === editeur.id, code: "P8", test: "auteur enregistré = éditeur connecté", obtenu: aff?.created_by });
console.log(`${aff?.created_by === editeur.id ? "✅" : "❌"} P8   auteur enregistré = éditeur connecté`);

verifier("P7", "anon ne voit pas le brouillon", await api(anon, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 0);
verifier("P7", "compte sans rôle ne voit pas le brouillon", await api(visiteur, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 0);
verifier("W5", "envoi en relecture sans preuve refusé",
  await api(editeur, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "en_relecture" }), "bloque");
verifier("P12", "éditeur ajoute une preuve",
  await api(editeur, "POST", "preuves", { affirmation_id: aff?.id, source_id: insee, url_preuve: "https://test.invalid/preuve", type_relation: "confirme" }), 1);
verifier("P11", "anon ne voit pas la preuve du brouillon", await api(anon, "GET", `preuves?select=id&affirmation_id=eq.${aff?.id}`), 0);
verifier("P9", "éditeur envoie en relecture",
  await api(editeur, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "en_relecture" }), 1);
verifier("W1", "éditeur ne peut pas publier",
  await api(editeur, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "publie" }), "bloque");

// Tentative d'élévation : l'éditeur écrit role_equipe dans SES métadonnées (user_metadata).
await fetch(`${URL_PROJET}/auth/v1/user`, {
  method: "PUT",
  headers: { apikey: CLE, Authorization: `Bearer ${editeur.jeton}`, "Content-Type": "application/json" },
  body: JSON.stringify({ data: { role_equipe: "relecteur" } }),
});
const rafraichi = await (await fetch(`${URL_PROJET}/auth/v1/token?grant_type=refresh_token`, {
  method: "POST",
  headers: { apikey: CLE, "Content-Type": "application/json" },
  body: JSON.stringify({ refresh_token: editeur.rafraichir }),
})).json();
const editeurRafraichi = { jeton: rafraichi.access_token ?? editeur.jeton };
verifier("W1", "élévation via user_metadata sans effet : publication refusée",
  await api(editeurRafraichi, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "publie" }), "bloque");
// Remet user_metadata propre.
await fetch(`${URL_PROJET}/auth/v1/user`, {
  method: "PUT",
  headers: { apikey: CLE, Authorization: `Bearer ${editeurRafraichi.jeton}`, "Content-Type": "application/json" },
  body: JSON.stringify({ data: { role_equipe: null } }),
});

verifier("P7", "relecteur voit l'affirmation en relecture", await api(relecteur, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 1);
const publiee = verifier("W2", "relecteur publie l'affirmation de l'éditeur",
  await api(relecteur, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "publie" }), 1).donnees?.[0];
resultats.push({ ok: publiee?.reviewed_by === relecteur.id, code: "W2", test: "relecteur enregistré", obtenu: publiee?.reviewed_by });
console.log(`${publiee?.reviewed_by === relecteur.id ? "✅" : "❌"} W2   relecteur enregistré dans reviewed_by`);

verifier("P7", "anon voit l'affirmation publiée", await api(anon, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 1);
verifier("P11", "anon voit sa preuve", await api(anon, "GET", `preuves?select=id&affirmation_id=eq.${aff?.id}`), 1);
verifier("P13", "preuve d'une affirmation publiée : suppression refusée",
  await api(editeur, "DELETE", `preuves?affirmation_id=eq.${aff?.id}`), "bloque");
verifier("W6", "affirmation publiée : texte figé",
  await api(relecteur, "PATCH", `affirmations?id=eq.${aff?.id}`, { explication: "Réécrite." }), "bloque");
verifier("P10", "affirmation publiée : suppression refusée",
  await api(relecteur, "DELETE", `affirmations?id=eq.${aff?.id}`), "bloque");

// Fin : on retire l'affirmation de test pour qu'elle ne soit plus publique.
verifier("W8", "relecteur retire l'affirmation de test",
  await api(relecteur, "PATCH", `affirmations?id=eq.${aff?.id}`, { statut_workflow: "retire" }), 1);
verifier("P7", "anon ne la voit plus", await api(anon, "GET", `affirmations?select=id&id=eq.${aff?.id}`), 0);

const echecs = resultats.filter((r) => !r.ok).length;
console.log(`\n${resultats.length - echecs} ✅ / ${echecs} ❌`);
console.log("Nettoyage : exécuter supabase/rls_manuel/nettoyage_tests_api.sql dans le SQL Editor.");
process.exit(echecs ? 1 : 0);
