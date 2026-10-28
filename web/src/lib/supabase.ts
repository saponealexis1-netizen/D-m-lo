import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const cle = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined

// Garde-fou : le front ne doit embarquer qu'une clé publique. Une clé secrète ou service_role
// contournerait la RLS et serait lisible par n'importe quel visiteur.
function cleSecrete(k: string): boolean {
  if (k.startsWith('sb_secret_')) return true
  const morceaux = k.split('.')
  if (morceaux.length === 3) {
    try {
      const charge = JSON.parse(atob(morceaux[1].replace(/-/g, '+').replace(/_/g, '/')))
      return charge.role === 'service_role'
    } catch {
      return false
    }
  }
  return false
}

export const configErreur: string | null = !url || !cle
  ? 'Configuration manquante : renseignez VITE_SUPABASE_URL et VITE_SUPABASE_PUBLISHABLE_KEY (voir web/.env.example).'
  : cleSecrete(cle)
    ? 'Clé refusée : le site ne doit utiliser que la clé publishable, jamais une clé secrète ou service_role.'
    : null

export const supabase = createClient(
  configErreur ? 'https://invalide.invalid' : url!,
  configErreur ? 'invalide' : cle!,
)

// Message lisible pour les erreurs PostgREST les plus probables pendant la configuration.
export function messageErreur(e: { code?: string; message: string } | null): string | null {
  if (!e) return null
  if (e.code === '42501') return 'Accès refusé par la base : les droits de lecture (RLS et GRANT) ne sont pas encore configurés.'
  if (e.code === '42P01' || e.code === 'PGRST205') return 'Objet introuvable : la migration v2_05 n’est pas encore appliquée.'
  return e.message
}
