import { useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from './supabase'

// Le rôle vient de app_metadata (modifiable seulement côté serveur). L'interface s'en sert
// pour afficher l'espace équipe ; c'est la RLS qui décide réellement des droits.
export function useSession() {
  const [session, setSession] = useState<Session | null>(null)
  const [pret, setPret] = useState(false)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setPret(true)
    })
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  const estAdmin = session?.user.app_metadata?.role_equipe === 'admin'
  return { session, estAdmin, pret }
}
