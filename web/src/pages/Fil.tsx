import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { messageErreur, supabase } from '../lib/supabase'
import { date, STATUTS, THEMES } from '../lib/libelles'
import type { ArticleFeed, StatutVerification, Theme } from '../lib/types'

const PAR_PAGE = 20

export default function Fil() {
  const [params, setParams] = useSearchParams()
  const theme = params.get('theme') as Theme | null
  const statut = params.get('statut') as StatutVerification | null
  const q = params.get('q') ?? ''
  const page = Math.max(1, Number(params.get('page')) || 1)

  const [articles, setArticles] = useState<ArticleFeed[]>([])
  const [total, setTotal] = useState(0)
  const [erreur, setErreur] = useState<string | null>(null)
  const [charge, setCharge] = useState(true)
  const [recherche, setRecherche] = useState(q)

  useEffect(() => {
    let annule = false
    setCharge(true)
    let requete = supabase
      .from('v_feed_verifie')
      .select('*', { count: 'exact' })
      .order('date_publication', { ascending: false, nullsFirst: false })
      .order('id', { ascending: false })
      .range((page - 1) * PAR_PAGE, page * PAR_PAGE - 1)
    if (theme) requete = requete.eq('theme', theme)
    if (statut) requete = requete.eq('statut_verification', statut)
    if (q) requete = requete.ilike('titre', `%${q.replace(/[%_\\]/g, '\\$&')}%`)

    requete.then(({ data, count, error }) => {
      if (annule) return
      setErreur(messageErreur(error))
      setArticles((data as ArticleFeed[]) ?? [])
      setTotal(count ?? 0)
      setCharge(false)
    })
    return () => { annule = true }
  }, [theme, statut, q, page])

  function changer(cle: string, valeur: string) {
    const p = new URLSearchParams(params)
    if (valeur) p.set(cle, valeur)
    else p.delete(cle)
    p.delete('page')
    setParams(p)
  }

  const pages = Math.max(1, Math.ceil(total / PAR_PAGE))

  return (
    <section>
      <h1>Les articles politiques de la semaine, démêlés</h1>
      <p className="intro">
        Articles collectés chaque semaine auprès des médias. Quand une affirmation a été vérifiée à partir des sources
        officielles, l'analyse est disponible sur la fiche de l'article.
      </p>

      <form className="filtres" onSubmit={(e) => { e.preventDefault(); changer('q', recherche.trim()) }}>
        <input type="search" placeholder="Rechercher un titre…" value={recherche} onChange={(e) => setRecherche(e.target.value)} aria-label="Rechercher un titre" />
        <select value={theme ?? ''} onChange={(e) => changer('theme', e.target.value)} aria-label="Thème">
          <option value="">Tous les thèmes</option>
          {Object.entries(THEMES).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
        <select value={statut ?? ''} onChange={(e) => changer('statut', e.target.value)} aria-label="Statut de vérification">
          <option value="">Tous les statuts</option>
          {Object.entries(STATUTS).map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
      </form>

      {erreur && <p className="alerte">{erreur}</p>}
      {!erreur && !charge && articles.length === 0 && <p>Aucun article ne correspond.</p>}

      <ul className="liste">
        {articles.map((a) => (
          <li key={a.id} className="carte">
            <div className="meta">
              <span>{a.media_nom}</span>
              <span>{date(a.date_publication)}</span>
              {a.theme && <span className="etiquette">{THEMES[a.theme]}</span>}
            </div>
            <h2><Link to={`/article/${a.id}`}>{a.titre}</Link></h2>
            <span className={`statut statut-${a.statut_verification}`}>
              {STATUTS[a.statut_verification]}
              {a.nb_analyses_publiees > 0 && ` · ${a.nb_analyses_publiees} affirmation${a.nb_analyses_publiees > 1 ? 's' : ''}`}
            </span>
          </li>
        ))}
      </ul>

      {pages > 1 && (
        <nav className="pagination" aria-label="Pagination">
          <button disabled={page <= 1} onClick={() => { const p = new URLSearchParams(params); p.set('page', String(page - 1)); setParams(p) }}>← Précédent</button>
          <span>Page {page} / {pages} · {total} articles</span>
          <button disabled={page >= pages} onClick={() => { const p = new URLSearchParams(params); p.set('page', String(page + 1)); setParams(p) }}>Suivant →</button>
        </nav>
      )}
    </section>
  )
}
