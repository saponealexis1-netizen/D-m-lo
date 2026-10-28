import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'

// Pas d'inscription publique : les comptes de l'équipe sont créés dans Supabase Auth.
export default function Connexion({ session }: { session: Session | null }) {
  const [email, setEmail] = useState('')
  const [mdp, setMdp] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [envoi, setEnvoi] = useState(false)

  if (session) return <Navigate to="/equipe" replace />

  async function connecter(e: React.FormEvent) {
    e.preventDefault()
    setEnvoi(true)
    const { error } = await supabase.auth.signInWithPassword({ email, password: mdp })
    setErreur(error ? 'Identifiants incorrects.' : null)
    setEnvoi(false)
  }

  return (
    <section className="formulaire">
      <h1>Espace équipe</h1>
      <form onSubmit={connecter}>
        <label>E-mail<input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} /></label>
        <label>Mot de passe<input type="password" autoComplete="current-password" required value={mdp} onChange={(e) => setMdp(e.target.value)} /></label>
        {erreur && <p className="alerte">{erreur}</p>}
        <button type="submit" disabled={envoi}>{envoi ? 'Connexion…' : 'Se connecter'}</button>
      </form>
    </section>
  )
}
