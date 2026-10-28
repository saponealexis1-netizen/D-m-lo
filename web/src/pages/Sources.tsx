import { useEffect, useState } from 'react'
import { messageErreur, supabase } from '../lib/supabase'
import { TYPES_SOURCE } from '../lib/libelles'
import type { Source } from '../lib/types'

export default function Sources() {
  const [sources, setSources] = useState<Source[]>([])
  const [erreur, setErreur] = useState<string | null>(null)

  useEffect(() => {
    supabase
      .from('sources')
      .select('id, nom, type_source, url_base, reutilisation, licence_info')
      .eq('active', true)
      .order('nom')
      .then(({ data, error }) => { setErreur(messageErreur(error)); setSources((data as Source[]) ?? []) })
  }, [])

  return (
    <section>
      <h1>Les sources de preuve</h1>
      <p className="intro">
        Une analyse ne s'appuie que sur ces organismes. Chaque preuve est retéléchargée et contrôlée : elle doit provenir
        du site officiel de l'organisme cité.
      </p>
      {erreur && <p className="alerte">{erreur}</p>}
      <ul className="grille">
        {sources.map((s) => (
          <li key={s.id} className="carte">
            <h2><a href={s.url_base} target="_blank" rel="noopener noreferrer">{s.nom}</a></h2>
            <div className="meta">
              <span className="etiquette">{TYPES_SOURCE[s.type_source] ?? s.type_source}</span>
              <span>{s.reutilisation === 'ouverte' ? 'Licence ouverte' : 'Lien seulement'}</span>
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}
