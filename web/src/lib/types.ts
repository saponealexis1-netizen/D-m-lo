export type Theme = 'economie' | 'ecologie' | 'institutions' | 'societe' | 'international' | 'autre'
export type StatutVerification = 'analyse_disponible' | 'verification_insuffisante' | 'non_verifie'
export type Verdict = 'vrai' | 'faux' | 'trompeur' | 'non_verifiable'

export interface ArticleFeed {
  id: number
  titre: string
  url_originale: string
  media_nom: string
  domaine_origine: string
  theme: Theme | null
  resume: string | null
  date_publication: string | null
  nb_analyses_publiees: number
  nb_abstentions: number
  statut_verification: StatutVerification
  derniere_analyse_le: string | null
}

export interface PreuvePublique {
  url: string
  titre: string | null
  organisme: string
  date_document: string | null
  version_document: string | null
  relation: 'confirme' | 'contredit' | 'contextualise'
  nature: 'primaire' | 'secondaire'
  extrait: string | null
  consulte_le: string
}

export interface AnalysePublique {
  id: number
  texte_affirmation: string
  contexte: string | null
  date_affirmation: string | null
  theme: Theme | null
  statut_analyse: 'analyse_disponible' | 'verification_insuffisante'
  verdict: Verdict | null
  explication: string | null
  limites: string | null
  motif_abstention: string | null
  analyse_le: string | null
  modele_ia: string | null
  version_prompt: string | null
  version: number
  published_at: string | null
  revue_par_equipe: boolean
  mention: string
  contenu_id: number
  contenu_titre: string
  contenu_url: string
  media_nom: string
  preuves: PreuvePublique[]
}

export interface Source {
  id: number
  nom: string
  type_source: string
  url_base: string
  reutilisation: 'ouverte' | 'lien_seulement'
  licence_info: string | null
}
