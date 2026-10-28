// maj-sources — met à jour chaque semaine les sources fiables et les candidats.
//
// Appelée par pg_cron via public.appeler_edge_function('maj-sources').
//   1. Pour chaque organisme actif ayant un flux_url : lit son flux RSS/Atom
//      officiel (pas de scraping), ajoute les nouveaux documents publiés sur
//      son propre site, avec leur embedding mistral-embed.
//      Contenu sous licence ('lien_seulement') : titre et lien uniquement.
//   2. Calcule les embeddings manquants (sources ajoutées à la main).
//   3. Met à jour la table candidats depuis le CSV data.gouv.fr
//      « Candidatures à l'élection présidentielle 2027 — statuts sourcés ».
//
// Déploiement : « Verify JWT » désactivé, l'appel est protégé par la clé interne.
// Secrets : CLE_INTERNE, MISTRAL_API_KEY, CANDIDATS_CSV_URL (URL stable de la
// ressource CSV sur data.gouv.fr). Ajouter ?attendre=1 pour obtenir le rapport.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const USER_AGENT = "Demelo/1.0 (fact-checking presidentielle 2027)";
const EXTRAIT_MAX = 1500;
const LOT_EMBEDDINGS = 16;

Deno.serve(async (req) => {
  if (!cleInterneValide(req)) return json({ erreur: "Non autorisé" }, 401);

  if (new URL(req.url).searchParams.get("attendre") === "1") {
    return json(await mettreAJour());
  }
  EdgeRuntime.waitUntil(mettreAJour().then((r) => console.log(JSON.stringify(r))).catch(console.error));
  return json({ info: "Mise à jour lancée" }, 202);
});

async function mettreAJour() {
  const organismes = await majOrganismes();
  const embeddings_completes = await completerEmbeddings();
  const candidats = await majCandidats();
  return { organismes, embeddings_completes, candidats };
}

// ---------------------------------------------------------------------
// 1. Sources des organismes
// ---------------------------------------------------------------------
async function majOrganismes() {
  const max = await parametre("sources_max_par_organisme_maj");
  const { data: organismes, error } = await supabase
    .from("organismes")
    .select("id, nom, site_url, reutilisation, flux_url")
    .eq("actif", true)
    .not("flux_url", "is", null);
  if (error) throw error;

  const rapport = [];
  // Un organisme après l'autre : reste sous la limite de débit de Mistral.
  for (const org of organismes) {
    try {
      const res = await fetch(org.flux_url, {
        headers: { "User-Agent": USER_AGENT },
        signal: AbortSignal.timeout(20_000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const items = lireFlux(await res.text())
        .filter((it) => it.titre && it.url && memeSite(it.url, org.site_url));

      const { data: existantes, error: e1 } = await supabase
        .from("sources")
        .select("url")
        .in("url", items.map((it) => it.url!));
      if (e1) throw e1;
      const connues = new Set(existantes.map((s) => s.url));

      const nouvelles = items
        .filter((it) => !connues.has(it.url!))
        .slice(0, max)
        .map((it) => ({
          organisme_id: org.id,
          titre: it.titre!.slice(0, 500),
          url: it.url!,
          // Le trigger 6.2 refuse tout extrait pour un contenu sous licence.
          extrait: org.reutilisation === "ouverte" ? it.description?.slice(0, EXTRAIT_MAX) || null : null,
          publie_le: dateValide(it.date),
        }));

      const vecteurs = await embedParLots(nouvelles.map((s) => `${s.titre}\n${s.extrait ?? ""}`.trim()));
      if (nouvelles.length) {
        const { error: e2 } = await supabase
          .from("sources")
          .upsert(nouvelles.map((s, i) => ({ ...s, embedding: vecteurs[i] })), { onConflict: "url", ignoreDuplicates: true });
        if (e2) throw e2;
      }
      rapport.push({ organisme: org.nom, lus: items.length, ajoutes: nouvelles.length });
    } catch (e) {
      rapport.push({ organisme: org.nom, erreur: String(e) });
    }
  }
  return rapport;
}

// ---------------------------------------------------------------------
// 2. Embeddings manquants
// ---------------------------------------------------------------------
async function completerEmbeddings(): Promise<number> {
  const { data: sources, error } = await supabase
    .from("sources")
    .select("id, titre, extrait")
    .is("embedding", null)
    .limit(64);
  if (error) throw error;

  const vecteurs = await embedParLots(sources.map((s) => `${s.titre}\n${s.extrait ?? ""}`.trim()));
  for (const [i, s] of sources.entries()) {
    const { error: e } = await supabase.from("sources").update({ embedding: vecteurs[i] }).eq("id", s.id);
    if (e) throw e;
  }
  return sources.length;
}

// ---------------------------------------------------------------------
// 3. Candidats (data.gouv.fr)
// ---------------------------------------------------------------------
async function majCandidats() {
  const url = Deno.env.get("CANDIDATS_CSV_URL");
  if (!url) return { info: "CANDIDATS_CSV_URL non défini : candidats non mis à jour" };

  try {
    const res = await fetch(url, { headers: { "User-Agent": USER_AGENT }, signal: AbortSignal.timeout(20_000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const lignes = lireCsv(await res.text());
    if (lignes.length < 2) throw new Error("CSV vide");

    // Repère les colonnes par leur nom, quel que soit l'ordre du fichier.
    const entetes = lignes[0].map((h) => sansAccents(h).toLowerCase().trim());
    const col = (...noms: string[]) => entetes.findIndex((h) => noms.includes(h));
    const iNom = col("nom", "candidat", "nom_candidat", "nom complet", "nom_complet");
    const iPrenom = col("prenom", "prenom_candidat");
    const iParti = col("parti", "formation", "formation politique", "formation_politique", "etiquette", "nuance");
    const iStatut = col("statut", "statut_candidature", "statut candidature");
    const iSource = col("source", "source_url", "url_source", "lien_source", "lien", "url");
    if (iNom < 0) throw new Error(`colonne « nom » introuvable (colonnes : ${lignes[0].join(", ")})`);

    const valeur = (l: string[], i: number) => (i >= 0 ? l[i]?.trim() || null : null);
    const candidats = new Map<string, { nom: string; parti: string | null; statut_candidature: string | null; source_url: string | null }>();
    for (const l of lignes.slice(1)) {
      const nom = [valeur(l, iPrenom), valeur(l, iNom)].filter(Boolean).join(" ").trim();
      if (!nom) continue;
      const source = valeur(l, iSource);
      candidats.set(nom, {
        nom,
        parti: valeur(l, iParti),
        statut_candidature: valeur(l, iStatut),
        source_url: source && /^https?:\/\//i.test(source) ? source : null,
      });
    }

    const { error } = await supabase.from("candidats").upsert([...candidats.values()], { onConflict: "nom" });
    if (error) throw error;
    return { mis_a_jour: candidats.size };
  } catch (e) {
    return { erreur: String(e) };
  }
}

function lireCsv(texte: string): string[][] {
  const premiere = texte.slice(0, texte.indexOf("\n") + 1 || undefined);
  const sep = (premiere.match(/;/g)?.length ?? 0) > (premiere.match(/,/g)?.length ?? 0) ? ";" : ",";
  const lignes: string[][] = [];
  let ligne: string[] = [];
  let champ = "";
  let guillemets = false;
  for (let i = 0; i < texte.length; i++) {
    const c = texte[i];
    if (guillemets) {
      if (c === '"' && texte[i + 1] === '"') { champ += '"'; i++; }
      else if (c === '"') guillemets = false;
      else champ += c;
    } else if (c === '"') guillemets = true;
    else if (c === sep) { ligne.push(champ); champ = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && texte[i + 1] === "\n") i++;
      ligne.push(champ); champ = "";
      if (ligne.some((v) => v !== "")) lignes.push(ligne);
      ligne = [];
    } else champ += c;
  }
  ligne.push(champ);
  if (ligne.some((v) => v !== "")) lignes.push(ligne);
  if (lignes[0]?.[0]) lignes[0][0] = lignes[0][0].replace(/^﻿/, "");
  return lignes;
}

function sansAccents(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "");
}

// ---------------------------------------------------------------------
// Lecture RSS / Atom, sans dépendance.
// ---------------------------------------------------------------------
type Item = { titre: string | null; url: string | null; date: string | null; description: string | null };

function lireFlux(xml: string): Item[] {
  const blocs = xml.match(/<item\b[\s\S]*?<\/item>/gi) ?? xml.match(/<entry\b[\s\S]*?<\/entry>/gi) ?? [];
  return blocs.map((b) => ({
    titre: texte(balise(b, "title")),
    url: lien(b),
    date: balise(b, "pubDate") ?? balise(b, "published") ?? balise(b, "updated") ?? balise(b, "dc:date"),
    description: texte(balise(b, "description") ?? balise(b, "summary") ?? balise(b, "content")),
  }));
}

function balise(bloc: string, nom: string): string | null {
  const m = bloc.match(new RegExp(`<${nom}\\b[^>]*>([\\s\\S]*?)</${nom}>`, "i"));
  return m ? m[1] : null;
}

function lien(bloc: string): string | null {
  const l = texte(balise(bloc, "link"));
  if (l) return l;
  const m = bloc.match(/<link\b[^>]*href=["']([^"']+)["']/i);
  return m ? decoder(m[1]) : null;
}

function texte(s: string | null): string | null {
  if (!s) return null;
  // Deux passes : le HTML des descriptions est souvent échappé (&lt;p&gt;).
  const sansCdata = s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
  const t = decoder(decoder(sansCdata.replace(/<[^>]+>/g, " ")).replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
  return t || null;
}

const ENTITES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘",
  laquo: "«", raquo: "»", hellip: "…", eacute: "é", egrave: "è", ecirc: "ê", agrave: "à",
  acirc: "â", ccedil: "ç", ocirc: "ô", ucirc: "û", icirc: "î", euml: "ë", iuml: "ï",
};

function decoder(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (tout, e: string) => {
    if (e[0] === "#") {
      const code = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : tout;
    }
    return ENTITES[e.toLowerCase()] ?? tout;
  });
}

// Le document doit être publié sur le site de l'organisme de la liste blanche.
function memeSite(url: string, site: string): boolean {
  try {
    const u = new URL(url);
    const hote = (h: string) => h.replace(/^www\./, "");
    const s = hote(new URL(site).hostname);
    return /^https?:$/.test(u.protocol) && (hote(u.hostname) === s || u.hostname.endsWith("." + s));
  } catch {
    return false;
  }
}

function dateValide(s: string | null): string | null {
  if (!s) return null;
  const d = new Date(s.trim());
  return isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
}

// ---------------------------------------------------------------------
// Mistral
// ---------------------------------------------------------------------
async function mistral(chemin: string, corps: unknown, essais = 4) {
  for (let i = 0;; i++) {
    const res = await fetch(`https://api.mistral.ai/v1/${chemin}`, {
      method: "POST",
      headers: { Authorization: `Bearer ${Deno.env.get("MISTRAL_API_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify(corps),
      signal: AbortSignal.timeout(60_000),
    });
    if (res.ok) return await res.json();
    if ((res.status === 429 || res.status >= 500) && i < essais - 1) {
      await new Promise((r) => setTimeout(r, 1500 * 2 ** i));
      continue;
    }
    throw new Error(`Mistral ${res.status} : ${(await res.text()).slice(0, 300)}`);
  }
}

async function embedParLots(textes: string[]): Promise<number[][]> {
  const vecteurs: number[][] = [];
  for (let i = 0; i < textes.length; i += LOT_EMBEDDINGS) {
    const r = await mistral("embeddings", { model: "mistral-embed", input: textes.slice(i, i + LOT_EMBEDDINGS) });
    vecteurs.push(...r.data.map((d: { embedding: number[] }) => d.embedding));
  }
  return vecteurs;
}

// ---------------------------------------------------------------------
async function parametre(cle: string): Promise<number> {
  const { data, error } = await supabase.from("parametres").select("valeur").eq("cle", cle).single();
  if (error) throw error;
  return data.valeur;
}

function cleInterneValide(req: Request): boolean {
  const attendu = Deno.env.get("CLE_INTERNE") ?? "";
  const recu = req.headers.get("x-cle-interne") ?? "";
  if (attendu.length < 32 || recu.length !== attendu.length) return false;
  let diff = 0;
  for (let i = 0; i < attendu.length; i++) diff |= attendu.charCodeAt(i) ^ recu.charCodeAt(i);
  return diff === 0;
}

function json(corps: unknown, statut = 200): Response {
  return new Response(JSON.stringify(corps), {
    status: statut,
    headers: { "Content-Type": "application/json" },
  });
}
