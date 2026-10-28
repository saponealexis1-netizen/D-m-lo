// importer-rss — importe chaque jour les articles des flux RSS des médias.
//
// Appelée par pg_cron via public.appeler_edge_function('importer-rss').
// Les articles arrivent avec le statut 'importe' : rien n'est analysé tant
// qu'un éditeur ne les a pas choisis (statut 'en_attente').
// Droit voisin : on ne stocke que l'URL, le titre et la date, jamais le texte
// ni le chapô du média.
//
// Déploiement : « Verify JWT » désactivé, l'appel est protégé par la clé interne.
// Secrets : CLE_INTERNE. Ajouter ?attendre=1 pour obtenir le rapport (test manuel).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const USER_AGENT = "Demelo/1.0 (fact-checking presidentielle 2027)";

Deno.serve(async (req) => {
  if (!cleInterneValide(req)) return json({ erreur: "Non autorisé" }, 401);

  if (new URL(req.url).searchParams.get("attendre") === "1") {
    return json(await importer());
  }
  EdgeRuntime.waitUntil(importer().then((r) => console.log(JSON.stringify(r))).catch(console.error));
  return json({ info: "Import lancé" }, 202);
});

async function importer() {
  const max = await parametre("articles_max_par_media_import");
  const { data: medias, error } = await supabase
    .from("medias")
    .select("id, nom, site_url, flux_rss_url")
    .not("flux_rss_url", "is", null);
  if (error) throw error;

  const rapport = await Promise.all(medias.map(async (media) => {
    try {
      const res = await fetch(media.flux_rss_url, {
        headers: { "User-Agent": USER_AGENT },
        signal: AbortSignal.timeout(20_000),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const items = lireFlux(await res.text());

      // Même plafond pour tous les médias (règle de neutralité).
      const lignes = items
        .filter((it) => it.titre && it.url && memeSite(it.url, media.site_url))
        .slice(0, max)
        .map((it) => ({
          media_id: media.id,
          url: it.url,
          titre: it.titre!.slice(0, 500),
          publie_le: dateValide(it.date),
          statut: "importe",
        }));

      if (lignes.length === 0) return { media: media.nom, lus: items.length, ajoutes: 0 };
      const { data, error } = await supabase
        .from("articles")
        .upsert(lignes, { onConflict: "url", ignoreDuplicates: true })
        .select("id");
      if (error) throw error;
      return { media: media.nom, lus: items.length, ajoutes: data.length };
    } catch (e) {
      return { media: media.nom, erreur: String(e) };
    }
  }));

  const { count } = await supabase.from("articles").select("id", { count: "exact", head: true });
  return { medias: rapport, total_articles: count };
}

// ---------------------------------------------------------------------
// Lecture RSS / Atom, sans dépendance (rapide, reste sous la limite CPU).
// ---------------------------------------------------------------------
type Item = { titre: string | null; url: string | null; date: string | null };

function lireFlux(xml: string): Item[] {
  const blocs = xml.match(/<item\b[\s\S]*?<\/item>/gi) ?? xml.match(/<entry\b[\s\S]*?<\/entry>/gi) ?? [];
  return blocs.map((b) => ({
    titre: texte(balise(b, "title")),
    url: lien(b),
    date: balise(b, "pubDate") ?? balise(b, "published") ?? balise(b, "updated") ?? balise(b, "dc:date"),
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
  const t = decoder(s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, " "))
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

// L'article doit être sur le site du média (pas un lien externe glissé dans le flux).
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
  return isNaN(d.getTime()) ? null : d.toISOString();
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
