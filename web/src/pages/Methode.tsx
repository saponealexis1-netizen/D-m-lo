export default function Methode() {
  return (
    <section className="texte">
      <h1>Comment Démêlo vérifie</h1>
      <ol className="etapes">
        <li><strong>Collecte.</strong> Chaque lundi, les nouveaux articles politiques sont récupérés depuis les flux RSS des médias. Seuls le titre, le lien et la date sont conservés.</li>
        <li><strong>Choix des affirmations.</strong> L'équipe choisit les articles à vérifier ; Claude en extrait les affirmations factuelles. Les opinions et les promesses ne reçoivent pas de verdict.</li>
        <li><strong>Recherche des preuves.</strong> Claude cherche uniquement sur les sites des organismes listés dans la page Sources.</li>
        <li><strong>Contrôle des documents.</strong> Notre code retélécharge chaque document et vérifie qu'il vient bien du site officiel et que le passage cité s'y trouve.</li>
        <li><strong>Verdict ou abstention.</strong> Un verdict n'est publié que si les règles sont remplies (par exemple, « faux » exige une source primaire qui contredit). Sinon, Démêlo s'abstient et explique pourquoi.</li>
        <li><strong>Cas sensibles.</strong> Les affirmations sensibles sont relues par un membre de l'équipe avant publication.</li>
      </ol>
      <p className="encadre">Ces règles sont inscrites dans la base de données elle-même : une analyse qui ne les respecte pas est refusée, quel que soit l'outil qui tente de la publier.</p>
    </section>
  )
}
