import { useCallback, useEffect, useState } from 'react'
import { Navigate } from 'react-router-dom'
import { messageErreur, supabase } from '../lib/supabase'
import { dateHeure, RELATIONS, VERDICTS } from '../lib/libelles'
import type { Verdict } from '../lib/types'

interface Chiffres { [cle: string]: number | null }

interface AffirmationRevue {
  id: number
  texte_affirmation: string
  verdict: Verdict | null
  explication: string | null
  motif_sensibilite: string | null
  motif_abstention: string | null
  version: number
  analyse_le: string | null
  contenus: { titre: string; url_originale: string; media_nom: string } | null
  preuves: { id: number; url_finale: string | null; url_preuve: string; titre_document: string | null; type_relation: keyof typeof RELATIONS; nature: string | null; statut_preuve: string; version_analyse: number }[]
}

const DECISIONS = [
  { statut: 'analyse_disponible', libelle: 'Publier' },
  { statut: 'verification_insuffisante', libelle: 'Publier comme abstention' },
  { statut: 'retire', libelle: 'Écarter' },
] as const

async function compter(table: string, filtre?: (q: any) => any): Promise<number | null> {
  let q = supabase.from(table).select('id', { count: 'exact', head: true })
  if (filtre) q = filtre(q)
  const { count, error } = await q
  return error ? null : count
}

export default function Equipe({ estAdmin }: { estAdmin: boolean }) {
  const [chiffres, setChiffres] = useState<Chiffres>({})
  const [file, setFile] = useState<AffirmationRevue[]>([])
  const [erreur, setErreur] = useState<string | null>(null)
  const [motifs, setMotifs] = useState<Record<number, string>>({})

  const charger = useCallback(async () => {
    const [articles, fictifs, nonTraites, publiees, abstentions, enRevue] = await Promise.all([
      compter('contenus'),
      compter('contenus', (q) => q.eq('est_test', true)),
      compter('contenus', (q) => q.eq('statut_traitement', 'non_traite')),
      compter('affirmations', (q) => q.eq('statut_analyse', 'analyse_disponible')),
      compter('affirmations', (q) => q.eq('statut_analyse', 'verification_insuffisante')),
      compter('affirmations', (q) => q.eq('statut_analyse', 'revue_requise')),
    ])
    setChiffres({ articles, fictifs, nonTraites, publiees, abstentions, enRevue })

    const { data, error } = await supabase
      .from('affirmations')
      .select('id, texte_affirmation, verdict, explication, motif_sensibilite, motif_abstention, version, analyse_le, contenus(titre, url_originale, media_nom), preuves(id, url_finale, url_preuve, titre_document, type_relation, nature, statut_preuve, version_analyse)')
      .eq('statut_analyse', 'revue_requise')
      .order('analyse_le')
    setErreur(messageErreur(error))
    setFile((data as unknown as AffirmationRevue[]) ?? [])
  }, [])

  useEffect(() => { if (estAdmin) charger() }, [estAdmin, charger])

  if (!estAdmin) return <Navigate to="/connexion" replace />

  async function decider(id: number, statut: string) {
    const motif = (motifs[id] ?? '').trim()
    if (!motif) { setErreur('Un motif est obligatoire pour toute décision.'); return }
    // Le trigger prive.controler_affirmation vérifie la transition, les preuves et archive le motif.
    const { error } = await supabase.from('affirmations').update({ statut_analyse: statut, revue_motif: motif }).eq('id', id)
    setErreur(error ? error.message : null)
    if (!error) charger()
  }

  return (
    <section>
      <h1>Espace équipe</h1>
      <ul className="chiffres">
        <li><strong>{chiffres.articles ?? '—'}</strong> articles en base</li>
        <li><strong>{chiffres.fictifs ?? '—'}</strong> dont fictifs (jamais publics)</li>
        <li><strong>{chiffres.nonTraites ?? '—'}</strong> articles non vérifiés</li>
        <li><strong>{chiffres.publiees ?? '—'}</strong> analyses publiées</li>
        <li><strong>{chiffres.abstentions ?? '—'}</strong> abstentions</li>
        <li><strong>{chiffres.enRevue ?? '—'}</strong> en attente de revue</li>
      </ul>

      <h2>Cas sensibles à relire</h2>
      {erreur && <p className="alerte">{erreur}</p>}
      {file.length === 0 && !erreur && <p>Aucune analyse en attente de revue.</p>}
      {file.map((a) => (
        <div key={a.id} className="analyse">
          <p className="meta"><span>{a.contenus?.media_nom}</span><span>{a.contenus?.titre}</span><span>{dateHeure(a.analyse_le)}</span></p>
          <blockquote>« {a.texte_affirmation} »</blockquote>
          <p>Verdict proposé : <strong>{a.verdict ? VERDICTS[a.verdict] : 'aucun'}</strong></p>
          {a.motif_sensibilite && <p><strong>Pourquoi sensible :</strong> {a.motif_sensibilite}</p>}
          {a.explication && <p>{a.explication}</p>}
          {a.motif_abstention && <p><strong>Abstention :</strong> {a.motif_abstention}</p>}
          <ul className="preuves">
            {a.preuves.filter((p) => p.version_analyse === a.version).map((p) => (
              <li key={p.id}>
                <span className={`relation relation-${p.type_relation}`}>{RELATIONS[p.type_relation]}</span>{' '}
                <a href={p.url_finale ?? p.url_preuve} target="_blank" rel="noopener noreferrer">{p.titre_document ?? p.url_preuve}</a>
                <span className="meta"><span>{p.nature ?? '—'}</span><span>{p.statut_preuve}</span></span>
              </li>
            ))}
          </ul>
          <label>Motif de la décision
            <input value={motifs[a.id] ?? ''} onChange={(e) => setMotifs({ ...motifs, [a.id]: e.target.value })} />
          </label>
          <div className="actions">
            {DECISIONS.map((d) => <button key={d.statut} onClick={() => decider(a.id, d.statut)}>{d.libelle}</button>)}
          </div>
        </div>
      ))}
    </section>
  )
}
