// Libellés d'interface des énumérations de la base (pas des données).
import type { StatutVerification, Theme, Verdict } from './types'

export const THEMES: Record<Theme, string> = {
  economie: 'Économie',
  ecologie: 'Écologie',
  institutions: 'Institutions',
  societe: 'Société',
  international: 'International',
  autre: 'Autre',
}

export const STATUTS: Record<StatutVerification, string> = {
  analyse_disponible: 'Analyse disponible',
  verification_insuffisante: 'Vérification insuffisante',
  non_verifie: 'Non vérifié',
}

export const VERDICTS: Record<Verdict, string> = {
  vrai: 'Vrai',
  faux: 'Faux',
  trompeur: 'Trompeur',
  non_verifiable: 'Non vérifiable',
}

export const RELATIONS = { confirme: 'Confirme', contredit: 'Contredit', contextualise: 'Contextualise' } as const

export const TYPES_SOURCE: Record<string, string> = {
  media: 'Média',
  institution: 'Institution',
  statistique: 'Statistique publique',
  juridique: 'Juridique',
  fact_checking: 'Fact-checking',
}

const fmtDate = new Intl.DateTimeFormat('fr-FR', { dateStyle: 'long', timeZone: 'Europe/Paris' })
const fmtDateHeure = new Intl.DateTimeFormat('fr-FR', { dateStyle: 'long', timeStyle: 'short', timeZone: 'Europe/Paris' })

export const date = (d: string | null) => (d ? fmtDate.format(new Date(d)) : '—')
export const dateHeure = (d: string | null) => (d ? fmtDateHeure.format(new Date(d)) : '—')
