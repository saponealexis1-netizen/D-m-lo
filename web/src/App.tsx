import { NavLink, Route, Routes } from 'react-router-dom'
import { configErreur, supabase } from './lib/supabase'
import { useSession } from './lib/session'
import MiseAJour from './MiseAJour'
import Fil from './pages/Fil'
import Article from './pages/Article'
import Sources from './pages/Sources'
import Methode from './pages/Methode'
import Connexion from './pages/Connexion'
import Equipe from './pages/Equipe'

export default function App() {
  const { session, estAdmin, pret } = useSession()

  return (
    <>
      <div className="tricolore" aria-hidden="true"><span /><span /><span /></div>
      <header className="entete">
        <div className="conteneur entete-ligne">
          <NavLink to="/" className="logo" aria-label="Démêlo, accueil">
            <span className="logo-marque" aria-hidden="true"><span /><span /><span /></span>
            <span className="logo-texte">
              Démêlo
              <small>Démêle l'info. Fais-toi ton avis.</small>
            </span>
          </NavLink>
          <nav>
            <NavLink to="/" end>Articles</NavLink>
            <NavLink to="/sources">Sources</NavLink>
            <NavLink to="/methode">Méthode</NavLink>
            {estAdmin && <NavLink to="/equipe">Équipe</NavLink>}
            {session
              ? <button className="lien" onClick={() => supabase.auth.signOut()}>Déconnexion</button>
              : <NavLink to="/connexion">Connexion</NavLink>}
          </nav>
        </div>
      </header>

      <main className="conteneur">
        {configErreur ? (
          <p className="alerte">{configErreur}</p>
        ) : (
          <>
            <MiseAJour />
            <Routes>
              <Route path="/" element={<Fil />} />
              <Route path="/article/:id" element={<Article />} />
              <Route path="/sources" element={<Sources />} />
              <Route path="/methode" element={<Methode />} />
              <Route path="/connexion" element={<Connexion session={session} />} />
              <Route path="/equipe" element={pret ? <Equipe estAdmin={estAdmin} /> : null} />
              <Route path="*" element={<p>Page introuvable.</p>} />
            </Routes>
          </>
        )}
      </main>

      <footer className="pied">
        <div className="conteneur pied-grille">
          <div>
            <p className="pied-logo">Démêlo</p>
            <p>Liberté de s'informer · Égalité devant les faits · Fraternité du débat</p>
          </div>
          <p>
            Projet étudiant, sans affiliation politique. Les analyses sont produites par IA à partir de sources officielles,
            avec abstention lorsque les preuves sont insuffisantes. Les articles restent la propriété de leurs médias.
          </p>
        </div>
      </footer>
    </>
  )
}
