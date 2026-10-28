import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { messageErreur, supabase } from '../lib/supabase'
import { date, dateHeure, RELATIONS, STATUTS, THEMES, VERDICTS } from '../lib/libelles'
import type { AnalysePublique, ArticleFeed } from '../lib/types'

export default function Article() {
  const { id } = useParams()
  const [article, setArticle] = useState<ArticleFeed | null>(null)
  const [analyses, setAnalyses] = useState<AnalysePublique[]>([])
  const [erreur, setErreur] = useState<string | null>(null)
  const [charge, setCharge] = useState(true)

  useEffect(() => {
    const n = Number(id)
    if (!Number.isInteger(n)) { setErreur('Article introuvable.'); setCharge(false); return }
    Promise.all([
      supabase.from('v_feed_verifie').select('*').eq('id', n).maybeSingle(),
      supabase.from('v_analyses_publiques').select('*').eq('contenu_id', n).order('id'),
    ]).then(([a, l]) => {
      setErreur(messageErreur(a.error ?? l.error) ?? (a.data ? null : 'Article introuvable.'))
      setArticle(a.data as ArticleFeed | null)
      setAnalyses((l.data as AnalysePublique[]) ?? [])
      setCharge(false)
    })
  }, [id])

  if (charge) return <p>Chargement…</p>
  if (erreur || !article) return <><p className="alerte">{erreur}</p><Link to="/">← Retour aux articles</Link></>

  return (
    <article>
      <Link to="/">← Retour aux articles</Link>
      <div className="meta">
        <span>{article.media_nom}</span>
        <span>{date(article.date_publication)}</span>
        {article.theme && <span className="etiquette">{THEMES[article.theme]}</span>}
      </div>
      <h1>{article.titre}</h1>
      <p><a href={article.url_originale} target="_blank" rel="noopener noreferrer">Lire l'article sur le site du média ↗</a></p>
      <span className={`statut statut-${article.statut_verification}`}>{STATUTS[article.statut_verification]}</span>

      {analyses.length === 0 && (
        <p className="intro">Cet article n'a pas encore été vérifié. Les vérifications sont lancées par l'équipe, affirmation par affirmation.</p>
      )}

      {analyses.map((an) => (
        <section key={an.id} className="analyse">
          <p className="mention">{an.mention}{an.revue_par_equipe && ' · relue par l’équipe'}</p>
          <blockquote>« {an.texte_affirmation} »</blockquote>
          {an.contexte && <p className="contexte">{an.contexte}</p>}

          {an.statut_analyse === 'analyse_disponible' && an.verdict ? (
            <p className={`verdict verdict-${an.verdict}`}>{VERDICTS[an.verdict]}</p>
          ) : (
            <p className="verdict verdict-abstention">Vérification insuffisante</p>
          )}

          {an.explication && <p>{an.explication}</p>}
          {an.motif_abstention && <p><strong>Pourquoi pas de verdict :</strong> {an.motif_abstention}</p>}
          {an.limites && <p className="limites"><strong>Limites :</strong> {an.limites}</p>}

          {an.preuves.length > 0 && (
            <>
              <h3>Preuves</h3>
              <ul className="preuves">
                {an.preuves.map((p) => (
                  <li key={p.url}>
                    <span className={`relation relation-${p.relation}`}>{RELATIONS[p.relation]}</span>{' '}
                    <a href={p.url} target="_blank" rel="noopener noreferrer">{p.titre ?? p.url}</a>
                    <div className="meta">
                      <span>{p.organisme}</span>
                      <span>Source {p.nature}</span>
                      {p.date_document && <span>Document du {date(p.date_document)}</span>}
                      <span>Consulté le {date(p.consulte_le)}</span>
                    </div>
                    {p.extrait && <p className="extrait">« {p.extrait} »</p>}
                  </li>
                ))}
              </ul>
            </>
          )}
          <p className="technique">
            Analyse du {dateHeure(an.analyse_le)} · version {an.version}
            {an.modele_ia && ` · ${an.modele_ia}`}{an.version_prompt && ` · consignes ${an.version_prompt}`}
          </p>
        </section>
      ))}
    </article>
  )
}
