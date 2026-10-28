// Collecte des articles politiques de Démêlo à partir de flux RSS publics.
//
// Indépendante du fact-checking : aucun appel à Claude ici. Les nouveaux articles
// arrivent avec statut_traitement = 'non_traite' (non vérifiés) ; le pipeline IA
// ne les analyse que sur décision de l'équipe.
//
// Règles :
//  * on ne stocke que le titre, le lien canonique, la date et le média (droit voisin) ;
//  * dédoublonnage par URL canonique et par (domaine, identifiant du flux) ;
//  * un article déjà connu n'est jamais supprimé ni réécrit : seul `vu_le` est mis à jour ;
//  * aucune donnée fictive : le rôle de la base (demelo_pipeline) ne peut pas en créer ;
//  * un flux en erreur est signalé dans le rapport sans bloquer les autres.
//
// Variables d'environnement (secrets côté serveur / GitHub Actions uniquement) :
//   DEMELO_DATABASE_URL   chaîne Postgres du rôle demelo_pipeline (pooler Supabase, sans sslmode)
//   DEMELO_DB_CA          certificat CA Supabase (PEM), recommandé
//   DEMELO_DB_SSL         'desactive' (tests locaux) | 'sans-verification' (dépannage uniquement)
//   DEMELO_FLUX_FICHIER   fichier de flux (défaut : flux.json à côté du script)
//
// Usage : node collecte.mjs            collecte et enregistrement
//         node collecte.mjs --essai    lecture des flux seulement, aucune écriture

import { readFile, writeFile, appendFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { XMLParser, XMLValidator } from "fast-xml-parser";
import pg from "pg";

const ICI = dirname(fileURLToPath(import.meta.url));
const ESSAI = process.argv.includes("--essai");
const MAX_PAR_FLUX = 1000;   // garde-fou contre un flux anormal, pas une limite éditoriale
const USER_AGENT = "DemeloBot/1.0 (projet etudiant de fact-checking; collecte hebdomadaire des titres)";
// Paramètres de suivi retirés pour obtenir une URL canonique.
const PARAMS_SUIVI = /^(utm_|xtor$|at_|xts$|ns_|fbclid$|gclid$|mc_|cmp$|origin$|ref$)/i;

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  processEntities: true,
  htmlEntities: true,
  trimValues: true,
});

// ---------------------------------------------------------------------
// Lecture d'un flux
// ---------------------------------------------------------------------
export function lireFlux(xml) {
  const valide = XMLValidator.validate(xml);
  if (valide !== true) throw new Error(`XML invalide (ligne ${valide.err?.line ?? "?"})`);
  const doc = parser.parse(xml);
  const rss = doc?.rss?.channel?.item ?? doc?.["rdf:RDF"]?.item;
  const atom = doc?.feed?.entry;
  const items = rss ?? atom;
  if (items === undefined) throw new Error("format non reconnu (ni RSS ni Atom)");
  return (Array.isArray(items) ? items : [items]).map((it) => ({
    titre: texte(it.title),
    lien: lienAtom(it.link) ?? texte(it.link),
    guid: texte(it.guid) ?? texte(it.id),
    date: texte(it.pubDate) ?? texte(it["dc:date"]) ?? texte(it.published) ?? texte(it.updated),
  }));
}

function texte(v) {
  if (v === undefined || v === null) return null;
  if (typeof v === "object") v = v["#text"] ?? null;
  if (v === null) return null;
  const t = decoderEntites(String(v).replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
  return t || null;
}

// Les flux mettent souvent des entités HTML dans des blocs CDATA, que le parseur XML ne décode pas.
const ENTITES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘",
  ldquo: "“", rdquo: "”", laquo: "«", raquo: "»", hellip: "…", ndash: "–", mdash: "—", eacute: "é",
  egrave: "è", ecirc: "ê", agrave: "à", acirc: "â", ccedil: "ç", ocirc: "ô", ucirc: "û", icirc: "î",
  iuml: "ï", euml: "ë", oelig: "œ", Eacute: "É" };
function decoderEntites(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (tout, e) => {
    if (e[0] === "#") {
      const code = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : tout;
    }
    return ENTITES[e] ?? tout;
  });
}

function lienAtom(l) {
  if (!l || typeof l !== "object") return null;
  const liens = Array.isArray(l) ? l : [l];
  const choisi = liens.find((x) => x?.["@_rel"] === "alternate" || !x?.["@_rel"]) ?? liens[0];
  return choisi?.["@_href"] ?? null;
}

export function urlCanonique(brute) {
  let u;
  try {
    u = new URL(brute);
  } catch {
    return null;
  }
  if (!/^https?:$/.test(u.protocol)) return null;
  u.hash = "";
  u.hostname = u.hostname.toLowerCase();
  for (const cle of [...u.searchParams.keys()]) if (PARAMS_SUIVI.test(cle)) u.searchParams.delete(cle);
  return u.toString().replace(/\?$/, "");
}

// Domaine « de base » du média (ex. feeds.leparisien.fr -> leparisien.fr).
function domaineDeBase(hote) {
  return hote.toLowerCase().replace(/^www\./, "").split(".").slice(-2).join(".");
}

export function preparerArticles(items, flux, lot) {
  // `domaine` (facultatif) : domaine des articles quand il diffère de celui du flux.
  const base = flux.domaine ?? domaineDeBase(new URL(flux.url).hostname);
  const vus = new Set();
  const articles = [];
  let ignores = 0;
  let plafond = false;
  for (const it of items) {
    const url = it.lien ? urlCanonique(it.lien) : null;
    const hote = url ? new URL(url).hostname : "";
    const valide =
      url && it.titre && it.titre.length >= 3 &&
      !hote.endsWith(".invalid") &&                       // jamais de domaine réservé aux données fictives
      (hote === base || hote.endsWith("." + base));       // l'article est bien sur le site du média
    if (!valide || vus.has(url)) {
      ignores++;
      continue;
    }
    vus.add(url);
    const date = it.date ? new Date(it.date) : null;
    articles.push({
      media_nom: flux.media,
      url_originale: url,
      titre: it.titre.slice(0, 500),
      identifiant_externe: (it.guid ?? url).slice(0, 500),
      date_publication: date && !isNaN(date) ? date.toISOString() : null,
      lot_import: lot,
    });
    if (articles.length >= MAX_PAR_FLUX) { plafond = items.indexOf(it) < items.length - 1; break; }
  }
  return { articles, ignores, plafond };
}

// ---------------------------------------------------------------------
// Écriture dans Supabase (rôle demelo_pipeline : aucun droit de suppression)
// ---------------------------------------------------------------------
async function enregistrer(client, articles) {
  const urls = articles.map((a) => a.url_originale);
  await client.query("begin");
  try {
    // Articles déjà connus : on note seulement qu'ils sont toujours dans le flux.
    const connus = await client.query(
      "update public.contenus set vu_le = now() where url_originale = any($1::text[]) returning url_originale",
      [urls],
    );
    const dejaConnus = new Set(connus.rows.map((r) => r.url_originale));
    const nouveaux = articles.filter((a) => !dejaConnus.has(a.url_originale));
    let inseres = 0;
    if (nouveaux.length) {
      // « on conflict do nothing » couvre aussi le doublon (domaine, identifiant du flux).
      const res = await client.query(
        `insert into public.contenus (media_nom, url_originale, titre, identifiant_externe, date_publication, lot_import, vu_le)
         select m, u, t, i, d, l, now()
           from unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::timestamptz[], $6::text[]) as x(m, u, t, i, d, l)
         on conflict do nothing
         returning id`,
        [
          nouveaux.map((a) => a.media_nom), nouveaux.map((a) => a.url_originale), nouveaux.map((a) => a.titre),
          nouveaux.map((a) => a.identifiant_externe), nouveaux.map((a) => a.date_publication), nouveaux.map((a) => a.lot_import),
        ],
      );
      inseres = res.rowCount;
    }
    await client.query("commit");
    return { nouveaux: inseres, deja_connus: dejaConnus.size, doublons: nouveaux.length - inseres };
  } catch (e) {
    await client.query("rollback");
    throw e;
  }
}

function configSsl() {
  const mode = process.env.DEMELO_DB_SSL;
  if (mode === "desactive") return false;
  if (process.env.DEMELO_DB_CA) return { ca: process.env.DEMELO_DB_CA, rejectUnauthorized: true };
  if (mode === "sans-verification") {
    console.warn("⚠ TLS sans vérification du certificat (dépannage uniquement) : ajouter DEMELO_DB_CA.");
    return { rejectUnauthorized: false };
  }
  return { rejectUnauthorized: true };
}

// ---------------------------------------------------------------------
// Programme principal
// ---------------------------------------------------------------------
async function principal() {
  const debut = new Date();
  const lot = "rss-" + debut.toLocaleDateString("sv-SE", { timeZone: "Europe/Paris" }); // ex. rss-2026-11-02
  const fichierFlux = process.env.DEMELO_FLUX_FICHIER ?? join(ICI, "flux.json");
  const { flux } = JSON.parse(await readFile(fichierFlux, "utf8"));

  let client = null;
  if (!ESSAI) {
    if (!process.env.DEMELO_DATABASE_URL) throw new Error("DEMELO_DATABASE_URL manquant.");
    client = new pg.Client({ connectionString: process.env.DEMELO_DATABASE_URL, ssl: configSsl() });
    await client.connect();
  }
  try {
    await collecter(client, flux, lot, debut);
  } finally {
    await client?.end();
  }
}

async function collecter(client, flux, lot, debut) {
  if (client) {
    const { rows } = await client.query("select current_user as role");
    if (rows[0].role !== "demelo_pipeline") {
      throw new Error(`Rôle « ${rows[0].role} » refusé : la collecte doit utiliser le rôle demelo_pipeline (moindre privilège).`);
    }
  }

  const rapport = { debut: debut.toISOString(), lot, mode: ESSAI ? "essai" : "collecte", flux: [] };
  for (const f of flux) {
    const ligne = { media: f.media, url: f.url };
    try {
      const res = await fetch(f.url, {
        headers: { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/atom+xml, application/xml, text/xml" },
        signal: AbortSignal.timeout(20_000),
        redirect: "follow",
      });
      ligne.http = res.status;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const items = lireFlux(await res.text());
      const { articles, ignores, plafond } = preparerArticles(items, f, lot);
      Object.assign(ligne, { statut: "ok", lus: items.length, retenus: articles.length, ignores, plafond });
      if (client && articles.length) Object.assign(ligne, await enregistrer(client, articles));
    } catch (e) {
      Object.assign(ligne, { statut: "erreur", erreur: String(e.message ?? e).slice(0, 300) });
    }
    rapport.flux.push(ligne);
  }

  if (client) {
    const { rows } = await client.query(
      "select count(*)::int as total, max(vu_le) as derniere_collecte from public.contenus",
    );
    Object.assign(rapport, { total_articles_reels: rows[0].total, derniere_collecte: rows[0].derniere_collecte });
  }
  rapport.fin = new Date().toISOString();
  rapport.total_nouveaux = rapport.flux.reduce((n, l) => n + (l.nouveaux ?? 0), 0);
  rapport.flux_en_erreur = rapport.flux.filter((l) => l.statut === "erreur").length;

  await writeFile(join(process.cwd(), "rapport-collecte.json"), JSON.stringify(rapport, null, 2));
  const resume = [
    `## Collecte Démêlo — ${rapport.lot} (${rapport.mode})`,
    "",
    "| Média | Statut | Lus | Retenus | Nouveaux | Déjà connus | Erreur |",
    "|---|---|---|---|---|---|---|",
    ...rapport.flux.map((l) =>
      `| ${l.media} | ${l.statut === "ok" ? "✅" : "❌"} | ${l.lus ?? "-"} | ${l.retenus ?? "-"} | ${l.nouveaux ?? "-"} | ${l.deja_connus ?? "-"} | ${l.erreur ?? (l.plafond ? `plafond de ${MAX_PAR_FLUX} atteint` : "")} |`),
    "",
    `**Nouveaux articles : ${rapport.total_nouveaux}** — flux en erreur : ${rapport.flux_en_erreur}/${rapport.flux.length}` +
      (rapport.total_articles_reels !== undefined ? ` — articles réels en base : ${rapport.total_articles_reels}` : ""),
  ].join("\n");
  console.log(resume);
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, resume + "\n");

  // Échec du job seulement si aucun flux n'a pu être lu.
  if (rapport.flux_en_erreur === rapport.flux.length) process.exitCode = 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  principal().catch((e) => {
    console.error("Collecte interrompue :", e.message ?? e);
    process.exitCode = 1;
  });
}
