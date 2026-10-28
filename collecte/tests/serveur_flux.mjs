// Petit serveur HTTP local qui sert les flux de test (vraies requêtes HTTP pour le collecteur).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DOSSIER = join(dirname(fileURLToPath(import.meta.url)), "flux");
const port = Number(process.argv[2] ?? 8765);
createServer(async (req, res) => {
  try {
    const nom = req.url.replace(/^\//, "").replace(/[^a-z0-9_.-]/gi, "");
    const xml = await readFile(join(DOSSIER, nom));
    res.writeHead(200, { "Content-Type": "application/rss+xml; charset=utf-8" }).end(xml);
  } catch {
    res.writeHead(404).end("introuvable");
  }
}).listen(port, "127.0.0.1", () => console.log(`serveur de flux sur ${port}`));
