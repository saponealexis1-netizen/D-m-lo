import { useEffect, useState } from 'react'
import { supabase } from './lib/supabase'
import { dateHeure } from './lib/libelles'

// « Dernière mise à jour » : dernier passage de la collecte hebdomadaire (vu_le le plus récent
// parmi les articles réels visibles, filtrés par la RLS).
export default function MiseAJour() {
  const [vuLe, setVuLe] = useState<string | null | undefined>(undefined)

  useEffect(() => {
    supabase
      .from('contenus')
      .select('vu_le')
      .order('vu_le', { ascending: false })
      .limit(1)
      .then(({ data, error }) => setVuLe(error ? null : (data?.[0]?.vu_le ?? null)))
  }, [])

  if (vuLe === undefined) return null
  return (
    <p className="maj">
      {vuLe ? <>Dernière mise à jour des articles : <strong>{dateHeure(vuLe)}</strong></> : 'Aucune collecte publiée pour le moment.'}
      <span> · Actualisation chaque lundi à 9 h</span>
    </p>
  )
}
