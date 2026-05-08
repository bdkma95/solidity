// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
//
//  Smart Contract TOOLBOX — v1.0.0
//  Bibliotheque de calculs financiers institutionnels
//  Contrat auxiliaire du Smart Contract FondTokenise
//
//  Conformite  : AMF / CSSF / AIFMD / MiFID II / EMIR / MMF Regulation EU 2017/1131
//  Convention  : ACT/365 (Euro Money Market)
//  Precision   : 18 decimales (wei-compatible, standard ERC20)
// =============================================================================

// =============================================================================
// IMPORTS DES BIBLIOTHEQUES OPENZEPPELIN
// =============================================================================
// Justification du choix de chaque bibliotheque pour le Toolbox :
//
// AccessControl : Le Toolbox contient des parametres financiers critiques
//   (grille de frais, strategie d'allocation). Leur modification doit etre
//   restreinte aux seuls roles habilites. Un parametre de frais modifie sans
//   controle pourrait constituer une manipulation frauduleuse du fonds.
//
// Pausable : Circuit breaker en cas de bug de calcul detecte ou d'instruction
//   reglementaire. Permet de geler les mises a jour des parametres sans
//   impacter le contrat Fund (qui peut continuer a fonctionner en lecture).
//
// ReentrancyGuard : Meme si le Toolbox ne detient pas de fonds directement,
//   les fonctions d'administration (mise a jour frais, strategie) doivent etre
//   protegees contre les appels recursifs malveillants qui pourraient corrompre
//   l'etat interne entre deux transactions du meme bloc.
//
// Math (mulDiv) : Fonction cle pour la finance on-chain. mulDiv(a, b, c) calcule
//   a*b/c avec precision maximale sans overflow intermediaire. INDISPENSABLE
//   car en virgule fixe 18 dec, les produits intermediaires a*b depassent
//   facilement uint256 avant la division finale.
//
// SafeCast : Convertit uint256 <-> int256 sans risque de troncature silencieuse.
//   Critique pour les calculs d'ajustements de portefeuille (valeurs signees).

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

// =============================================================================
// INTERFACE ITOOLBOX
// =============================================================================
// Cette interface est la specification formelle du contrat entre FondTokenise
// et Toolbox. Elle DOIT rester synchronisee avec celle declaree dans FondTokenise.sol.
// Toute modification doit etre versionee, documentee, et auditee avant deploiement.
//
// Pourquoi declarer l'interface dans le meme fichier ?
//   - Permet au compilateur de verifier que Toolbox respecte bien son contrat
//   - Facilite la generation d'ABI pour les integrateurs off-chain
//   - Reduit le risque de desynchronisation entre les deux contrats

interface IToolbox {
    function calculerDepreciationLineaire(
        uint256 valeurNominale,
        uint256 tauxAnnuel,
        uint256 dureeJours,
        uint256 joursEcoules
    ) external pure returns (uint256 valeurActuelle);

    function calculerFrais(
        uint256 montant,
        uint8 typeOperation
    ) external view returns (uint256 frais);

    function calculerAjustementsPortefeuille(
        uint256 valeurTotalePortefeuille,
        uint256[] calldata allocationsActuelles,
        uint256[] calldata allocationsCibles
    ) external pure returns (int256[] memory ajustements);

    function validerConformite(
        address investisseur,
        uint256 montant,
        uint8 typeOperation
    ) external view returns (bool estValide);
}

// =============================================================================
// SMART CONTRACT TOOLBOX
// =============================================================================
// Role dans l'architecture a 4 contrats :
//
//   FondTokenise (contrat central)
//       |
//       |-- appelle --> Toolbox (ce contrat)
//       |-- emet vers -> TokenizedAsset
//       |-- coordonne -> TokenizedAssetHolding
//
// Ce contrat centralise :
//   MODULE 1 : Calcul de depreciation lineaire des instruments de taux (NEU CP)
//   MODULE 2 : Structure et calcul des frais (entree, sortie, gestion, performance)
//   MODULE 3 : Strategie d'investissement et reequilibrage du portefeuille
//   MODULE 4 : Validation de conformite reglementaire (limites, concentration, lock-up)
//   MODULE 5 : Calculs actuariels avances (interets composes, taux de rendement, duration)
//   MODULE 6 : Calculs de valorisation NAV avances (NAV nette, parts a emettre/racheter)
//   MODULE 7 : Administration et parametrage du Toolbox
//
// Avantages de l'externalisation dans un Toolbox distinct :
//   SEPARATION DES RESPONSABILITES : Fund = cycle de vie des ordres ;
//     Toolbox = logique financiere et reglementaire. Auditabilite independante.
//   UPGRADABILITE CONTROLEE : nouvelle grille de frais = nouveau Toolbox deploye
//     + appel a FondTokenise.mettreAJourToolbox(). Les fonds ne bougent pas.
//   REUTILISABILITE : TokenizedAsset et TokenizedAssetHolding utilisent les memes
//     fonctions de calcul (depreciation, taux, duration) sans dupliquer le code.
//   GAS EFFICIENCY : Les fonctions pure/view ne consomment pas de gas hors transaction.

contract Toolbox is IToolbox, AccessControl, Pausable, ReentrancyGuard {

    // =========================================================================
    // UTILISATION DES BIBLIOTHEQUES
    // =========================================================================
    // On declare l'usage de Math et SafeCast pour toutes les variables uint256/int256.
    // Cela permet d'appeler directement a.mulDiv(b, c) ou a.toInt256().
    using Math for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;

    // =========================================================================
    // DEFINITION DES ROLES (RBAC)
    // =========================================================================
    // Principe des quatre yeux (two-man rule) applique :
    // La modification d'un parametre financier critique doit etre autorisee
    // par un role distinct du role d'execution des ordres.

    /// @dev Gestionnaire de portefeuille : modifie la strategie d'allocation
    bytes32 public constant ROLE_GESTIONNAIRE = keccak256("GESTIONNAIRE");

    /// @dev Administrateur des frais : modifie la grille tarifaire
    /// Separe du Gestionnaire : un gestionnaire ne doit pas pouvoir fixer ses propres frais.
    bytes32 public constant ROLE_ADMIN_FRAIS = keccak256("ADMIN_FRAIS");

    /// @dev Compliance Officer : gere les investisseurs qualifies et limites reglementaires
    bytes32 public constant ROLE_COMPLIANCE = keccak256("COMPLIANCE");

    /// @dev Administrateur principal du Toolbox
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    /// @dev Contrat Fund autorise : seul FondTokenise peut appeler les fonctions stateful
    /// Protege contre l'utilisation non autorisee du Toolbox par des contrats tiers.
    bytes32 public constant ROLE_FOND_AUTORISE = keccak256("FOND_AUTORISE");

    // =========================================================================
    // CONSTANTES FINANCIERES FONDAMENTALES
    // =========================================================================
    // On utilise des constantes (gravees dans le bytecode) plutot que des variables
    // pour les parametres qui ne doivent JAMAIS changer apres deploiement.
    // Avantage gas : les constantes ne consomment pas de SLOAD (pas de lecture storage).

    /// @notice Precision en virgule fixe : 18 decimales (1 EUR = 1e18 unites)
    /// Standard ERC20 et compatible avec les calculs de prix en wei.
    uint256 public constant PRECISION = 1e18;

    /// @notice Base en points de base (1 bp = 0.01%, 10 000 bp = 100%)
    /// Evite l'utilisation de nombres decimaux (non supportes nativement en Solidity).
    /// Tout taux est exprime en bp : 350 bp = 3.50%.
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice Jours par an — Convention ACT/365 (Euro Money Market)
    /// ACT/365 est la convention standard pour les instruments de taux en EUR :
    /// NEU CP (ex-billets de tresorerie), OAT, BTF, et autres instruments francais.
    /// Alternative : ACT/360 pour certains depots bancaires. On choisit ACT/365.
    uint256 public constant JOURS_PAR_AN = 365;

    /// @notice Secondes par an (ACT/365, sans annee bissextile)
    /// Utilise pour les calculs prorata temporis des frais de gestion.
    uint256 public constant SECONDES_PAR_AN = 365 days;

    /// @notice Montant minimum absolu de souscription institutionnelle
    /// 100 000 EUR : seuil reglementaire investisseur qualifie (Art. 423-27 AMF)
    /// et investisseur averti (Art. L533-16 CMF). Standard marche ASPIM.
    uint256 public constant SOUSCRIPTION_MINIMUM = 100_000 * PRECISION;

    /// @notice Concentration maximale par emetteur en bp
    /// 20% max : regle de diversification inspiree de l'Article 22 UCITS,
    /// adaptee aux fonds alternatifs. Limite le risque de contrepartie.
    uint256 public constant CONCENTRATION_MAX_EMETTEUR_BP = 2_000;

    /// @notice Ratio de liquidite minimum du portefeuille en bp
    /// 10% minimum : exigence prudentielle pour honorer les rachats quotidiens.
    /// Conforme au Reglement MMF EU 2017/1131 (fonds monetaires a valeur liquidative variable).
    uint256 public constant RATIO_LIQUIDITE_MIN_BP = 1_000;

    /// @notice Periode de lock-up minimum : 90 jours (standard AIFMD Art. 23)
    uint256 public constant PERIODE_LOCK_UP = 90 days;

    /// @notice Nombre maximum d'actifs dans le portefeuille
    /// Plafond a 50 : evite les boucles trop longues qui depasseraient la gas limit.
    /// Un portefeuille institutionnel MMF n'excede generalement pas 30 lignes.
    uint256 public constant MAX_ACTIFS_PORTEFEUILLE = 50;

    // =========================================================================
    // STRUCTURES DE DONNEES
    // =========================================================================

    // -------------------------------------------------------------------------
    // STRUCTURE DE FRAIS
    // -------------------------------------------------------------------------
    // Architecture de frais a 3 couches, standard hedge fund / fonds reserves :
    //
    //   COUCHE 1 - Frais de transaction (preleves sur chaque ordre)
    //     Frais d'entree (souscription) et frais de sortie (rachat).
    //     Exprimes en bp du montant brut.
    //
    //   COUCHE 2 - Frais courants annuels (provisionnes prorata a chaque cycle NAV)
    //     Management fee + frais depositaire + frais admin.
    //     Reduisent l'ANT a chaque cycle, donc la NAV par part.
    //
    //   COUCHE 3 - Frais de performance (High Water Mark)
    //     Preleves uniquement si NAV > HWM + hurdle rate.
    //     Evite la double facturation des memes gains.
    //     Cristallises annuellement ou a chaque rachat.

    /// @notice Structure complete des frais du fonds
    /// Tous les taux sont en points de base (bp).
    struct StructureFrais {
        uint256 fraisSouscriptionEntrantBp;  // Frais d'entree (ex: 50 bp = 0.50%)
        uint256 fraisRachatSortantBp;        // Frais de sortie (ex: 25 bp = 0.25%)
        uint256 fraisGestionAnnuelsBp;       // Management fee annuel (ex: 100 bp = 1.00%/an)
        uint256 fraisPerformanceBp;          // Part de la surperf (ex: 2000 bp = 20%)
        uint256 hurleRate;                   // Rendement min avant frais perf (ex: 300 bp = 3%/an)
        uint256 fraisDepositaireAnnuelsBp;   // Frais depositaire annuels (ex: 5 bp = 0.05%/an)
        uint256 fraisAdminAnnuelsBp;         // Frais administratifs annuels (ex: 10 bp = 0.10%/an)
        uint256 fraisRachatAnticieBp;        // Penalite rachat avant lock-up (ex: 200 bp = 2%)
        uint256 derniereMiseAJour;           // Timestamp de la derniere mise a jour
    }

    // -------------------------------------------------------------------------
    // STRATEGIE D'INVESTISSEMENT
    // -------------------------------------------------------------------------
    // La strategie definit les allocations cibles par classe d'actifs et les
    // parametres de risque du portefeuille.
    // Elle est definie par le gestionnaire et validee par le comite d'investissement.

    /// @notice Parametres de la strategie d'investissement
    struct StrategieInvestissement {
        uint256 allocationBilletsTresorerieBp;  // NEU CP / Commercial Paper (< 1 an)
        uint256 allocationObligationsBp;         // Obligations souveraines / corp IG
        uint256 allocationActionsBp;             // Actions (0 pour un MMF pur)
        uint256 allocationLiquiditesBp;          // Liquidites (plancher de securite)

        // Tolerance de deviation avant reequilibrage :
        // Si l'allocation reelle d'un actif s'ecarte de plus de toleranceDeviationBp
        // de sa cible, le remplacement est declenche.
        // Ex: 100 bp = reequilibrage si ecart > 1%
        uint256 toleranceDeviationBp;

        // Duration maximale du portefeuille en jours.
        // Limite l'exposition au risque de taux.
        // Standard MMF court terme ESMA : 60j (WAM) / 120j (WAL)
        // On utilise 90j comme valeur prudente.
        uint256 durationMaxJours;

        // Rating minimum des contreparties (encode : 1=AAA, 2=AA+, 3=AA, 4=AA-, 5=A+, 6=A, 7=A-)
        // Conforme aux exigences ESMA pour les MMF (Reglement 2017/1131 Art. 19)
        uint8 ratingMinimumContrepartie;

        uint256 derniereMiseAJour;
    }

    // -------------------------------------------------------------------------
    // HIGH WATER MARK
    // -------------------------------------------------------------------------
    // Mecanisme standard de protection des investisseurs :
    // Les frais de performance ne sont dus que si la NAV par part depasse
    // son plus haut historique. Evite de facturer les memes gains deux fois.
    // Exemple : NAV monte a 1050, puis retombe a 980, puis remonte a 1030.
    // Frais de perf uniquement preleves sur la hausse de 980 vers 1050 (1ere fois),
    // PAS sur la hausse de 980 vers 1030 (le HWM est toujours a 1050).

    /// @notice Registre du High Water Mark pour les frais de performance
    struct HighWaterMark {
        uint256 valeurHauteur;  // Plus haut historique de NAV par part (EUR, 18 dec)
        uint256 horodatage;     // Timestamp d'atteinte du plus haut
        uint256 cycleNAV;       // Numero du cycle NAV ayant etabli le plus haut
    }

    // -------------------------------------------------------------------------
    // BILLET DE TRESORERIE (NEU CP)
    // -------------------------------------------------------------------------
    // Parametres complets d'un billet de tresorerie pour suivi de valorisation.
    // Les NEU CP (Negotiable European Commercial Paper, anciennement billets de
    // tresorerie) sont des instruments de taux court terme emis par des entreprises
    // ou etablissements de credit, generallement a discount (sous le pair).

    /// @notice Parametres d'un billet de tresorerie pour le calcul de depreciation
    struct ParametresBilletTresorerie {
        bytes32 identifiant;       // ISIN (ex: keccak256("FR0000000000"))
        uint256 valeurNominale;    // Valeur a maturite en EUR (18 dec)
        uint256 prixAcquisition;   // Prix d'achat en EUR (18 dec, <= nominal pour un discount)
        uint256 tauxRendementBp;   // Taux de rendement actuariel annualise (bp)
        uint256 dateEmission;      // Timestamp Unix d'emission
        uint256 dateMaturite;      // Timestamp Unix de maturite
        uint256 dureeJours;        // Duree totale en jours (calcule a l'enregistrement)
        bool estActif;             // True si l'instrument est encore en portefeuille
    }

    /// @notice Resultat detaille d'une valorisation de billet
    struct ResultatValorisation {
        uint256 valeurActuelle;         // Valeur actuelle de l'instrument (EUR, 18 dec)
        uint256 interetsCourus;         // Interets courus depuis l'emission (EUR, 18 dec)
        uint256 joursEcoules;           // Jours ecoules depuis l'emission
        uint256 joursRestants;          // Jours restants jusqu'a maturite
        uint256 rendementJournalier;    // Rendement journalier en unites PRECISION
        bool estEchu;                   // True si la maturite est depassee
    }

    // =========================================================================
    // VARIABLES D'ETAT
    // =========================================================================
    // Toutes les variables d'etat sont private avec getters publics dediés.
    // Principe de moindre exposition des donnees internes (least privilege).

    /// @notice Structure de frais actuellement en vigueur
    StructureFrais private _frais;

    /// @notice Strategie d'investissement en vigueur
    StrategieInvestissement private _strategie;

    /// @notice Registre du High Water Mark
    HighWaterMark private _highWaterMark;

    /// @notice Registre des billets de tresorerie suivis : ISIN => parametres
    mapping(bytes32 => ParametresBilletTresorerie) private _billetsTresorerie;

    /// @notice Liste des identifiants de billets (pour iteration et audit)
    bytes32[] private _listeIdentifiantsBillets;

    /// @notice Registre des investisseurs qualifies (valides par ROLE_COMPLIANCE)
    /// Note : le whitelisting KYC principal est dans FondTokenise.
    /// Ici on stocke les criteres financiers complementaires (plafonds, lock-up).
    mapping(address => bool) private _investisseursQualifies;

    /// @notice Montants investis cumules par investisseur (pour les plafonds de concentration)
    mapping(address => uint256) private _montantsInvestisParInvestisseur;

    /// @notice Date de premiere souscription par investisseur (pour le calcul du lock-up)
    mapping(address => uint256) private _datePremiereEntree;

    /// @notice Plafond de souscription individuel par defaut (EUR, 18 dec)
    /// Protege contre la concentration excessive d'un seul investisseur.
    uint256 private _plafondSouscriptionIndividuelEUR;

    /// @notice Version du Toolbox (pour traçabilite des mises a jour)
    string public version;

    // =========================================================================
    // EVENEMENTS (EVENTS)
    // =========================================================================
    // Tous les evenements sont indexes pour permettre des requetes efficaces.
    // Ils constituent la trace immuable de toutes les modifications de parametres.

    /// @notice Emis lors d'une mise a jour de la structure de frais
    event FraisMisAJour(
        uint256 fraisSouscriptionBp,
        uint256 fraisRachatBp,
        uint256 fraisGestionBp,
        uint256 fraisPerformanceBp,
        uint256 horodatage,
        address indexed responsable
    );

    /// @notice Emis lors d'une mise a jour de la strategie d'investissement
    event StrategieMiseAJour(
        uint256 allocationBilletsBp,
        uint256 allocationObligationsBp,
        uint256 toleranceDeviationBp,
        uint256 durationMaxJours,
        uint256 horodatage,
        address indexed gestionnaire
    );

    /// @notice Emis lors de l'enregistrement d'un nouveau billet de tresorerie
    event BilletTresorerieEnregistre(
        bytes32 indexed identifiant,
        uint256 valeurNominale,
        uint256 tauxRendementBp,
        uint256 dureeJours,
        uint256 horodatage
    );

    /// @notice Emis lors de la mise a jour du High Water Mark
    event HighWaterMarkMisAJour(
        uint256 ancienneValeur,
        uint256 nouvelleValeur,
        uint256 cycleNAV,
        uint256 horodatage
    );

    /// @notice Emis lors d'une alerte de conformite (non-bloquante, pour monitoring)
    event AlerteConformite(
        address indexed investisseur,
        string motif,
        uint256 montant,
        uint256 horodatage
    );

    /// @notice Emis lors de l'enregistrement d'un investisseur qualifie dans le Toolbox
    event InvestisseurQualifieEnregistre(
        address indexed investisseur,
        uint256 plafondIndividuelEUR,
        uint256 horodatage
    );

    /// @notice Emis lors d'une mise a jour du plafond individuel de souscription
    event PlafondMisAJour(
        uint256 ancienPlafond,
        uint256 nouveauPlafond,
        uint256 horodatage
    );

    // =========================================================================
    // MODIFICATEURS
    // =========================================================================

    /// @dev Restreint les appels stateful au seul contrat Fund autorise.
    /// Evite qu'un contrat tiers puisse manipuler les parametres du HWM ou les
    /// montants investis via des appels directs non autorises au Toolbox.
    modifier seulementFondAutorise() {
        require(
            hasRole(ROLE_FOND_AUTORISE, msg.sender),
            "TOOLBOX: Appelant non autorise - Seul le contrat Fund peut appeler"
        );
        _;
    }

    /// @dev Verifie que la somme des allocations cibles est exactement 100%
    /// On tolere un ecart de +/-1 bp pour absorber les arrondis eventuels.
    modifier allocationsTotalisent100Pourcent(
        uint256 billets,
        uint256 obligations,
        uint256 actions,
        uint256 liquidites
    ) {
        uint256 total = billets + obligations + actions + liquidites;
        require(
            total >= BASE_POINTS - 1 && total <= BASE_POINTS + 1,
            "TOOLBOX: Allocations cibles ne totalisent pas 100% (+/- 1bp tolere)"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTEUR
    // =========================================================================

    /// @notice Deploie le Toolbox et initialise les parametres financiers par defaut
    /// @param adresseAdmin Adresse recevant tous les roles initialement
    /// @param versionContrat Version du contrat (ex: "1.0.0")
    ///
    /// @dev Les valeurs par defaut correspondent a un fonds monetaire institutionnel
    /// standard, conforme au Reglement MMF EU 2017/1131 et aux pratiques AFG/ASPIM.
    constructor(
        address adresseAdmin,
        string memory versionContrat
    ) {
        require(adresseAdmin != address(0), "TOOLBOX: Adresse admin invalide");
        require(bytes(versionContrat).length > 0, "TOOLBOX: Version vide");

        version = versionContrat;

        // Attribution des roles fondateurs a l'administrateur deploiement
        // En production : ces roles seront distribues a des adresses distinctes
        // (principle of least privilege) apres le deploiement initial.
        _grantRole(DEFAULT_ADMIN_ROLE, adresseAdmin);
        _grantRole(ROLE_ADMIN, adresseAdmin);
        _grantRole(ROLE_GESTIONNAIRE, adresseAdmin);
        _grantRole(ROLE_ADMIN_FRAIS, adresseAdmin);
        _grantRole(ROLE_COMPLIANCE, adresseAdmin);

        // -----------------------------------------------------------------------
        // Parametres de frais par defaut — Fonds monetaire institutionnel
        // Source : AFG (Association Francaise de la Gestion financiere) 2024
        // -----------------------------------------------------------------------
        _frais = StructureFrais({
            fraisSouscriptionEntrantBp: 0,      // 0 bp : pas de frais d'entree (pratique standard
                                                 // pour les fonds reserves institutionnels)
            fraisRachatSortantBp:       0,      // 0 bp : pas de frais de sortie standard
            fraisGestionAnnuelsBp:      50,     // 0.50%/an : fourchette basse institutionnel
                                                 // (0.10-0.50% pour un MMF, 1-2% pour un FIA)
            fraisPerformanceBp:         2_000,  // 20% de la surperformance : standard "2/20"
                                                 // (2% gestion + 20% perf) du hedge fund classique
            hurleRate:                  300,    // 3%/an : hurdle rate base sur l'Euribor 3M moyen
                                                 // Ajustable selon les conditions de marche
            fraisDepositaireAnnuelsBp:  5,      // 0.05%/an : standard pour grands fonds (> 500M EUR)
                                                 // BNP Securities Services, Caceis, SGSS
            fraisAdminAnnuelsBp:        10,     // 0.10%/an : frais administrateur de fonds
                                                 // (valorisateur, agent de transfert, auditeur)
            fraisRachatAnticieBp:       200,    // 2% : penalite rachat avant fin de lock-up
                                                 // Protege les porteurs restants contre la dilution
            derniereMiseAJour:          block.timestamp
        });

        // -----------------------------------------------------------------------
        // Strategie d'investissement par defaut — MMF court terme
        // Conforme au Reglement EU 2017/1131 sur les fonds monetaires
        // -----------------------------------------------------------------------
        _strategie = StrategieInvestissement({
            allocationBilletsTresorerieBp:  6_000,  // 60% NEU CP : principal instrument MMF francais
                                                      // Emis par entreprises et collectivites locales
            allocationObligationsBp:         2_000,  // 20% OAT/BTAN/obligations IG courte duree
                                                      // Maturite residuelle < 2 ans (risque de taux limite)
            allocationActionsBp:             0,       // 0% actions : incompatible avec un MMF pur
                                                      // (Art. 9 Reglement MMF : actifs eligibles seulement)
            allocationLiquiditesBp:          2_000,  // 20% liquidites : au-dessus du minimum
                                                      // reglementaire (10%) pour gerer les rachats
            toleranceDeviationBp:            100,    // 1% : seuil de declenchement du reequilibrage
                                                      // Compromis entre stabilite et precision d'allocation
            durationMaxJours:                90,     // 90 jours WAM (Weighted Average Maturity)
                                                      // Conforme Art. 24 Reglement MMF (WAM <= 60j,
                                                      // on est conservateur a 90j pour un FIA similaire)
            ratingMinimumContrepartie:       3,      // AA minimum (code 3 dans notre nomenclature)
                                                      // Conforme ESMA MMF : pas d'exposition
                                                      // sous investment grade
            derniereMiseAJour:               block.timestamp
        });

        // HWM initialise a zero : premier cycle NAV etablira le HWM initial
        _highWaterMark = HighWaterMark({
            valeurHauteur: 0,
            horodatage:    block.timestamp,
            cycleNAV:      0
        });

        // Plafond individuel de souscription par defaut : 10 millions EUR
        // Evite qu'un seul investisseur represente plus de X% du fonds
        // (a ajuster selon la taille cible du fonds)
        _plafondSouscriptionIndividuelEUR = 10_000_000 * PRECISION;
    }

    // =========================================================================
    // MODULE 1 : CALCUL DE DEPRECIATION LINEAIRE — BILLETS DE TRESORERIE
    // =========================================================================
    // Les NEU CP sont emis "en dessous du pair" (au discount).
    // Exemple : un billet de valeur nominale 1 000 000 EUR, taux 3.50%/an, 90 jours
    //   -> Prix d'emission = 1 000 000 / (1 + 3.50% × 90/365) = 991 400 EUR (approx)
    //   -> La valeur du billet croit lineairement de 991 400 EUR vers 1 000 000 EUR
    //      sur 90 jours.
    //
    // Methode choisie : AMORTISSEMENT LINEAIRE (Straight-Line Amortization)
    //   Formule : V(t) = PrixEmission + (VN - PrixEmission) × (t / T)
    //   Ou : t = jours ecoules, T = duree totale, VN = valeur nominale
    //
    // Pourquoi lineaire plutot qu'actuariel (taux compose) ?
    //   1. La methode actuarielle necessite exp() / pow() non disponibles en Solidity
    //      sans bibliotheques externes (risque de securite supplementaire).
    //   2. Pour les maturites courtes (< 1 an, typique NEU CP), l'ecart entre les
    //      deux methodes est inferieur a 0.01 bp (negligeable).
    //   3. La methode lineaire est acceptee par les regulateurs pour les MMF
    //      a valeur liquidative stable ou quasi-stable (CNAV/LVNAV).
    //   4. Conformite IFRS 9 : les instruments HtM peuvent etre valorises au
    //      cout amorti lineaire si l'ecart avec la valeur actuarielle est non materiel.

    /// @notice Calcule la valeur actuelle d'un billet de tresorerie (NEU CP) par amortissement lineaire
    /// @param valeurNominale Valeur nominale (remboursement a maturite) en EUR — 18 decimales
    /// @param tauxAnnuel Taux de rendement annuel en points de base (ex: 350 = 3.50%/an)
    /// @param dureeJours Duree totale de l'instrument en jours calendaires
    /// @param joursEcoules Nombre de jours ecoules depuis la date d'emission
    /// @return valeurActuelle Valeur actuelle de l'instrument en EUR — 18 decimales
    ///
    /// @dev Invariant garanti : valeurActuelle >= prixEmission ET <= valeurNominale
    ///      Si joursEcoules >= dureeJours : retourne valeurNominale (maturite atteinte)
    function calculerDepreciationLineaire(
        uint256 valeurNominale,
        uint256 tauxAnnuel,
        uint256 dureeJours,
        uint256 joursEcoules
    ) external pure override returns (uint256 valeurActuelle) {
        // --- CHECKS ---
        require(valeurNominale > 0,                     "TOOLBOX: Valeur nominale nulle");
        require(dureeJours > 0,                         "TOOLBOX: Duree nulle");
        require(tauxAnnuel > 0,                         "TOOLBOX: Taux annuel nul");
        require(tauxAnnuel <= BASE_POINTS * 10,         "TOOLBOX: Taux annuel aberrant (> 100%)");
        // joursEcoules peut etre 0 (premier jour) ou > dureeJours (echu)

        // --- CAS : instrument arrive a maturite ou depasse ---
        // Retourne la valeur nominale : c'est le montant rembourse a l'echeance.
        if (joursEcoules >= dureeJours) {
            return valeurNominale;
        }

        // --- ETAPE 1 : Calcul du prix d'emission (prix au discount) ---
        // Formule simple (methode lineaire europeenne ACT/365) :
        //   PrixEmission = VN / (1 + taux_decimal × duree/365)
        //   PrixEmission = VN × 365 × BASE_POINTS / (365 × BASE_POINTS + taux × duree)
        //
        // On utilise Math.mulDiv(a, b, c) = a*b/c sans overflow intermediaire.
        // numerateur   = VN × (365 × 10000)
        // denominateur = (365 × 10000) + (taux_bp × duree_jours)
        //
        // Exemple : VN=1e24 (1M EUR × 1e18), taux=350bp, duree=90j
        //   num = 1e24 × 3650000 = 3.65e30 < 2^256 ? OUI (2^256 ≈ 1.15e77) -> OK
        //   den = 3650000 + (350 × 90) = 3650000 + 31500 = 3681500
        //   prixEmission = 3.65e30 / 3681500 ≈ 9.914e23 (991 400 EUR × 1e18)
        uint256 numerateurPrix = JOURS_PAR_AN * BASE_POINTS;
        uint256 denominateurPrix = (JOURS_PAR_AN * BASE_POINTS) + (tauxAnnuel * dureeJours);

        uint256 prixEmission = Math.mulDiv(valeurNominale, numerateurPrix, denominateurPrix);

        // --- ETAPE 2 : Calcul de la decote (discount) ---
        // La decote est la plus-value totale sur la duree de vie du billet.
        // Elle sera amortie lineairement au fil du temps.
        uint256 decote = valeurNominale - prixEmission;
        // prixEmission <= valeurNominale toujours (taux >= 0), donc pas de underflow

        // --- ETAPE 3 : Amortissement lineaire de la decote ---
        // Portion amortie(t) = decote × (joursEcoules / dureeJours)
        // En virgule fixe avec Math.mulDiv pour eviter l'overflow :
        // mulDiv(decote, joursEcoules, dureeJours) = decote × joursEcoules / dureeJours
        uint256 portionAmortie = Math.mulDiv(decote, joursEcoules, dureeJours);

        // --- ETAPE 4 : Valeur actuelle ---
        valeurActuelle = prixEmission + portionAmortie;

        // Invariant de securite (ne devrait jamais echouer mathematiquement,
        // mais on le verifie par assertion pour detecter tout bug de calcul)
        assert(valeurActuelle <= valeurNominale);
        assert(valeurActuelle >= prixEmission);

        return valeurActuelle;
    }

    /// @notice Calcule un resultat de valorisation detaille pour un billet enregistre
    /// @param identifiant ISIN du billet de tresorerie
    /// @return resultat Structure complete avec valeur actuelle, interets courus, etc.
    ///
    /// @dev Fonction view : peut etre appelee gratuitement en lecture seule.
    /// Utilisee par le valorisateur pour soumettre les prix au Fund.
    function calculerValorisationBillet(bytes32 identifiant)
        external
        view
        returns (ResultatValorisation memory resultat)
    {
        ParametresBilletTresorerie storage billet = _billetsTresorerie[identifiant];
        require(billet.estActif, "TOOLBOX: Billet de tresorerie inconnu ou inactif");

        uint256 maintenant = block.timestamp;

        // Calcul du nombre de jours ecoules depuis l'emission
        // On utilise la division entiere (1 day = 86400 secondes)
        uint256 secondesEcoulees = maintenant > billet.dateEmission
            ? maintenant - billet.dateEmission
            : 0;
        uint256 joursEcoules = secondesEcoulees / 1 days;

        bool estEchu = maintenant >= billet.dateMaturite;

        // Calcul de la valeur actuelle
        uint256 valActuelle;
        if (estEchu) {
            // A maturite : valeur = valeur nominale (remboursement par l'emetteur)
            valActuelle = billet.valeurNominale;
        } else {
            // Appel recursif a notre propre fonction de depreciation
            valActuelle = this.calculerDepreciationLineaire(
                billet.valeurNominale,
                billet.tauxRendementBp,
                billet.dureeJours,
                joursEcoules
            );
        }

        // Interets courus = valeur actuelle - prix d'acquisition
        // Mesure le gain non realise sur la position
        uint256 interetsCourus = valActuelle > billet.prixAcquisition
            ? valActuelle - billet.prixAcquisition
            : 0;

        // Rendement journalier en unites PRECISION
        // = (taux annuel en bp / BASE_POINTS) / JOURS_PAR_AN
        // = taux × PRECISION / (BASE_POINTS × JOURS_PAR_AN)
        uint256 rendementJournalier = Math.mulDiv(
            billet.tauxRendementBp * PRECISION,
            1,
            BASE_POINTS * JOURS_PAR_AN
        );

        uint256 joursRestants = estEchu
            ? 0
            : (billet.dateMaturite - maintenant) / 1 days;

        resultat = ResultatValorisation({
            valeurActuelle:      valActuelle,
            interetsCourus:      interetsCourus,
            joursEcoules:        joursEcoules,
            joursRestants:       joursRestants,
            rendementJournalier: rendementJournalier,
            estEchu:             estEchu
        });
    }

    // =========================================================================
    // MODULE 2 : CALCUL DES FRAIS
    // =========================================================================

    /// @notice Calcule les frais de transaction pour une souscription ou un rachat
    /// @param montant Montant brut de l'operation en EUR (18 decimales)
    /// @param typeOperation 0 = souscription, 1 = rachat
    /// @return frais Montant total des frais a prelever en EUR (18 decimales)
    ///
    /// @dev Fonction view : lecture seule de la structure de frais.
    /// Utilise Math.mulDiv pour la precision sur les grands montants :
    ///   frais = montant × tauxBp / BASE_POINTS
    ///   mulDiv evite que (montant × tauxBp) ne depasse uint256 avant la division.
    function calculerFrais(
        uint256 montant,
        uint8 typeOperation
    ) external view override returns (uint256 frais) {
        require(montant > 0,           "TOOLBOX: Montant nul pour calcul de frais");
        require(typeOperation <= 1,    "TOOLBOX: Type d'operation invalide (0=souscription, 1=rachat)");

        if (typeOperation == 0) {
            // --- SOUSCRIPTION : frais d'entree ---
            // Frais = montant × fraisSouscriptionEntrantBp / 10 000
            frais = Math.mulDiv(montant, _frais.fraisSouscriptionEntrantBp, BASE_POINTS);
        } else {
            // --- RACHAT STANDARD : frais de sortie ---
            frais = Math.mulDiv(montant, _frais.fraisRachatSortantBp, BASE_POINTS);
        }

        return frais;
    }

    /// @notice Calcule les frais de rachat avec distinction standard / anticipe
    /// @param montant Montant du rachat en EUR
    /// @param investisseur Adresse de l'investisseur (pour verifier le lock-up)
    /// @return frais Frais totaux (standard ou majores si rachat anticipe)
    /// @return estAnticipe True si le rachat est avant la fin du lock-up
    function calculerFraisRachatComplets(
        uint256 montant,
        address investisseur
    ) external view returns (uint256 frais, bool estAnticipe) {
        require(montant > 0, "TOOLBOX: Montant nul");
        require(investisseur != address(0), "TOOLBOX: Adresse invalide");

        uint256 dateEntree = _datePremiereEntree[investisseur];
        estAnticipe = (dateEntree > 0 && block.timestamp < dateEntree + PERIODE_LOCK_UP);

        if (estAnticipe) {
            // Rachat anticipe : penalite additionnelle sur la totalite du montant
            frais = Math.mulDiv(montant, _frais.fraisRachatAnticieBp, BASE_POINTS);
        } else {
            // Rachat standard : frais de sortie normaux
            frais = Math.mulDiv(montant, _frais.fraisRachatSortantBp, BASE_POINTS);
        }
    }

    /// @notice Calcule les frais de gestion courants prorata temporis pour un cycle NAV
    /// @param actifNetTotal Actif net total du fonds en EUR (18 decimales)
    /// @param dureeSecondesCycle Duree du cycle NAV en secondes
    /// @return fraisGestion Frais de gestion prorata en EUR
    /// @return fraisDepositaire Frais depositaire prorata en EUR
    /// @return fraisAdmin Frais administratifs prorata en EUR
    ///
    /// @dev Formule prorata : frais = ANT × (taux_annuel / 10000) × (duree / secondes_par_an)
    ///   On decompose en deux mulDiv imbriques pour eviter l'overflow :
    ///   Etape 1 : fraisAnnuels = mulDiv(ANT, taux_bp, BASE_POINTS)
    ///   Etape 2 : fraisProrata = mulDiv(fraisAnnuels, dureeSecondes, SECONDES_PAR_AN)
    function calculerFraisCourantsProrata(
        uint256 actifNetTotal,
        uint256 dureeSecondesCycle
    )
        external
        view
        returns (
            uint256 fraisGestion,
            uint256 fraisDepositaire,
            uint256 fraisAdmin
        )
    {
        require(actifNetTotal > 0,           "TOOLBOX: ANT nul");
        require(dureeSecondesCycle > 0,      "TOOLBOX: Duree de cycle nulle");
        require(dureeSecondesCycle <= 7 days, "TOOLBOX: Duree de cycle excessive (> 7 jours)");

        // Frais de gestion = ANT × tauxGestion/10000 × duree/365j
        fraisGestion = Math.mulDiv(
            Math.mulDiv(actifNetTotal, _frais.fraisGestionAnnuelsBp, BASE_POINTS),
            dureeSecondesCycle,
            SECONDES_PAR_AN
        );

        // Frais depositaire = ANT × tauxDepositaire/10000 × duree/365j
        fraisDepositaire = Math.mulDiv(
            Math.mulDiv(actifNetTotal, _frais.fraisDepositaireAnnuelsBp, BASE_POINTS),
            dureeSecondesCycle,
            SECONDES_PAR_AN
        );

        // Frais administratifs = ANT × tauxAdmin/10000 × duree/365j
        fraisAdmin = Math.mulDiv(
            Math.mulDiv(actifNetTotal, _frais.fraisAdminAnnuelsBp, BASE_POINTS),
            dureeSecondesCycle,
            SECONDES_PAR_AN
        );
    }

    /// @notice Calcule les frais de performance selon le mecanisme High Water Mark
    /// @param navParPartActuelle NAV par part actuelle en EUR (18 decimales)
    /// @param nombrePartsTotales Nombre de parts en circulation
    /// @return fraisPerformance Frais de performance en EUR (0 si en-dessous du HWM ou hurdle)
    ///
    /// @dev Algorithme HWM + hurdle rate :
    ///   1. Si NAV <= HWM : aucun frais de perf (on n'est pas au-dessus du plus haut)
    ///   2. Calcul du hurdle depuis le dernier HWM : hurdleParPart = HWM × taux × temps
    ///   3. Si NAV <= HWM + hurdle : aucun frais (la hausse est insuffisante)
    ///   4. Sinon : fraisPerf = (NAV - HWM - hurdle) × nombreParts × tauxPerf / BASE_POINTS
    function calculerFraisPerformance(
        uint256 navParPartActuelle,
        uint256 nombrePartsTotales
    ) external view returns (uint256 fraisPerformance) {
        // Aucun calcul si aucune part en circulation
        if (nombrePartsTotales == 0) return 0;

        // Si NAV actuelle <= HWM : pas de frais de performance
        if (navParPartActuelle <= _highWaterMark.valeurHauteur) return 0;

        // Calcul du hurdle rate accumule depuis l'etablissement du dernier HWM
        // hurdleParPart = HWM × (hurleRate/10000) × (temps_ecoule / secondes_par_an)
        uint256 tempsDepuisHWM = block.timestamp > _highWaterMark.horodatage
            ? block.timestamp - _highWaterMark.horodatage
            : 0;

        uint256 hurdleParPart = Math.mulDiv(
            Math.mulDiv(_highWaterMark.valeurHauteur, _frais.hurleRate, BASE_POINTS),
            tempsDepuisHWM,
            SECONDES_PAR_AN
        );

        // Seuil minimum de performance : HWM + hurdle accumule
        uint256 navMinimumRequis = _highWaterMark.valeurHauteur + hurdleParPart;

        // Si la NAV n'atteint pas le minimum requis : pas de frais
        if (navParPartActuelle <= navMinimumRequis) return 0;

        // Surperformance par part = NAV actuelle - (HWM + hurdle)
        uint256 surperformanceParPart = navParPartActuelle - navMinimumRequis;

        // Frais de perf = surperf × nbParts × tauxPerf / BASE_POINTS
        // Decompose en deux mulDiv pour eviter l'overflow :
        // Etape 1 : valeurSurperformanceTotale = (surperf × nbParts) / PRECISION
        //   (division par PRECISION car surperf et nbParts sont en 18 dec)
        // Etape 2 : fraisPerf = valeurSurperfTotale × tauxBp / BASE_POINTS
        uint256 valeurSurperfTotale = Math.mulDiv(
            surperformanceParPart,
            nombrePartsTotales,
            PRECISION
        );

        fraisPerformance = Math.mulDiv(valeurSurperfTotale, _frais.fraisPerformanceBp, BASE_POINTS);

        return fraisPerformance;
    }

    /// @notice Met a jour le High Water Mark si la NAV actuelle etablit un nouveau plus haut
    /// @param navParPartActuelle NAV par part actuelle
    /// @param cycleNAV Numero du cycle NAV courant
    /// @dev Seul le contrat Fund autorise peut appeler cette fonction (pattern seulementFondAutorise)
    function mettreAJourHighWaterMark(
        uint256 navParPartActuelle,
        uint256 cycleNAV
    ) external seulementFondAutorise {
        if (navParPartActuelle > _highWaterMark.valeurHauteur) {
            uint256 ancienneValeur = _highWaterMark.valeurHauteur;

            _highWaterMark = HighWaterMark({
                valeurHauteur: navParPartActuelle,
                horodatage:    block.timestamp,
                cycleNAV:      cycleNAV
            });

            emit HighWaterMarkMisAJour(
                ancienneValeur,
                navParPartActuelle,
                cycleNAV,
                block.timestamp
            );
        }
    }

    // =========================================================================
    // MODULE 3 : STRATEGIE D'INVESTISSEMENT ET REEQUILIBRAGE DU PORTEFEUILLE
    // =========================================================================

    /// @notice Calcule les ajustements de portefeuille necessaires pour atteindre les cibles
    /// @param valeurTotalePortefeuille Valeur totale actuelle en EUR (18 decimales)
    /// @param allocationsActuelles Valeurs actuelles par actif en EUR (tableau, 18 dec)
    /// @param allocationsCibles Allocations cibles par actif en bp (tableau)
    /// @return ajustements Ajustements a effectuer en EUR (signes : + = achat, - = vente)
    ///
    /// @dev Algorithme de reequilibrage proportionnel :
    ///   Pour chaque actif i :
    ///     valeurCible(i) = valeurTotale × allocationCible(i) / BASE_POINTS
    ///     ajustement(i) = valeurCible(i) - valeurActuelle(i)
    ///   Propriete : sum(ajustements) ≈ 0 (budget equilibre, ecart max = arrondi)
    ///   Les ajustements positifs = ordres d'achat a transmettre au depositaire
    ///   Les ajustements negatifs = ordres de vente a transmettre au depositaire
    ///
    /// @dev La fonction est pure (pas d'acces au storage) : elle peut etre appelee
    ///   de n'importe quel contexte, y compris par TokenizedAsset et Holding.
    function calculerAjustementsPortefeuille(
        uint256 valeurTotalePortefeuille,
        uint256[] calldata allocationsActuelles,
        uint256[] calldata allocationsCibles
    ) external pure override returns (int256[] memory ajustements) {
        // --- CHECKS ---
        require(valeurTotalePortefeuille > 0, "TOOLBOX: Valeur totale portefeuille nulle");
        require(
            allocationsActuelles.length == allocationsCibles.length,
            "TOOLBOX: Tableaux d'allocations de tailles differentes"
        );
        require(
            allocationsActuelles.length > 0,
            "TOOLBOX: Portefeuille vide"
        );
        require(
            allocationsActuelles.length <= MAX_ACTIFS_PORTEFEUILLE,
            "TOOLBOX: Nombre d'actifs depasse le maximum autorise (50)"
        );

        uint256 nombreActifs = allocationsActuelles.length;
        ajustements = new int256[](nombreActifs);

        // Verification que les allocations cibles totalisent bien 100% (+/- 1 bp)
        uint256 totalCibles = 0;
        for (uint256 i = 0; i < nombreActifs; i++) {
            totalCibles += allocationsCibles[i];
        }
        require(
            totalCibles >= BASE_POINTS - 1 && totalCibles <= BASE_POINTS + 1,
            "TOOLBOX: Allocations cibles ne totalisent pas 100% (+/- 1bp tolere)"
        );

        // --- CALCUL DES AJUSTEMENTS ---
        for (uint256 i = 0; i < nombreActifs; i++) {
            // Valeur cible = valeur totale portefeuille × allocation cible (bp) / 10 000
            // On utilise mulDiv pour eviter l'overflow sur les grands portefeuilles
            uint256 valeurCible = Math.mulDiv(
                valeurTotalePortefeuille,
                allocationsCibles[i],
                BASE_POINTS
            );

            // Ajustement = cible - actuelle (signe : positif = achat, negatif = vente)
            // SafeCast.toInt256() leve une exception si la valeur depasse type(int256).max
            // Protection contre les portefeuilles de taille aberrante
            int256 cibleSignee   = valeurCible.toInt256();
            int256 actuelleSignee = allocationsActuelles[i].toInt256();
            ajustements[i] = cibleSignee - actuelleSignee;
        }

        return ajustements;
    }

    /// @notice Verifie si le reequilibrage est necessaire selon la tolerance configuree
    /// @param allocationsActuelles Valeurs actuelles par actif en EUR
    /// @param allocationsCibles Allocations cibles en bp
    /// @param valeurTotale Valeur totale du portefeuille en EUR
    /// @return necessaire True si au moins un actif depasse le seuil de tolerance
    /// @return indexActifHorsTolerance Index du premier actif hors tolerance (-1 si aucun)
    function verifierNecessiteReequilibrage(
        uint256[] calldata allocationsActuelles,
        uint256[] calldata allocationsCibles,
        uint256 valeurTotale
    ) external view returns (bool necessaire, int256 indexActifHorsTolerance) {
        require(allocationsActuelles.length == allocationsCibles.length, "TOOLBOX: Tableaux de tailles differentes");
        require(valeurTotale > 0, "TOOLBOX: Valeur totale nulle");

        indexActifHorsTolerance = -1; // -1 = aucun actif hors tolerance

        for (uint256 i = 0; i < allocationsActuelles.length; i++) {
            // Allocation actuelle en bp = (valeurActuelle / valeurTotale) × 10 000
            uint256 allocationActuelleBp = Math.mulDiv(
                allocationsActuelles[i],
                BASE_POINTS,
                valeurTotale
            );

            // Deviation absolue en bp entre allocation actuelle et cible
            uint256 deviation;
            if (allocationActuelleBp > allocationsCibles[i]) {
                deviation = allocationActuelleBp - allocationsCibles[i];
            } else {
                deviation = allocationsCibles[i] - allocationActuelleBp;
            }

            // Si la deviation depasse la tolerance : reequilibrage necessaire
            if (deviation > _strategie.toleranceDeviationBp) {
                return (true, i.toInt256());
            }
        }

        return (false, -1);
    }

    // =========================================================================
    // MODULE 4 : VALIDATION DE CONFORMITE REGLEMENTAIRE
    // =========================================================================

    /// @notice Valide la conformite d'une operation aux regles du fonds
    /// @param investisseur Adresse de l'investisseur
    /// @param montant Montant en EUR (souscription) ou nombre de parts (rachat)
    /// @param typeOperation 0 = souscription, 1 = rachat
    /// @return estValide True si toutes les regles sont respectees
    ///
    /// @dev Regles verifiees :
    ///   SOUSCRIPTION :
    ///     [1] Montant >= SOUSCRIPTION_MINIMUM (100 000 EUR)
    ///     [2] Montant cumule + montant <= plafond individuel (10M EUR par defaut)
    ///   RACHAT :
    ///     [1] Montant > 0
    ///     [2] Si avant lock-up : alerte non-bloquante, penalite sera appliquee
    ///
    ///   Note : le whitelisting KYC/AML est gere dans FondTokenise (ROLE_COMPLIANCE).
    ///   Le Toolbox valide les criteres financiers et reglementaires complementaires.
    function validerConformite(
        address investisseur,
        uint256 montant,
        uint8 typeOperation
    ) external view override returns (bool estValide) {
        // Validations communes de base
        if (investisseur == address(0)) return false;
        if (montant == 0) return false;
        if (typeOperation > 1) return false;

        if (typeOperation == 0) {
            // --- SOUSCRIPTION ---

            // Regle [1] : Montant minimum institutionnel
            if (montant < SOUSCRIPTION_MINIMUM) {
                // Note : on ne peut pas emettre d'event depuis une fonction view.
                // Le monitoring off-chain detecte le rejet via le retour false.
                return false;
            }

            // Regle [2] : Plafond de concentration individuelle
            // Verification que le cumul ne depasse pas le plafond configure
            uint256 montantCumule = _montantsInvestisParInvestisseur[investisseur] + montant;
            if (montantCumule > _plafondSouscriptionIndividuelEUR) {
                return false;
            }

        } else {
            // --- RACHAT ---

            // Regle [1] : Rachat avant lock-up autorise mais avec penalite (non-bloquant)
            // Les frais majores seront calcules par calculerFraisRachatComplets()
            // On ne bloque pas le rachat anticipe : l'investisseur a le droit de sortir
            // mais il paie une penalite pour proteger les autres porteurs.

            // Regle [2] : Verification basique du montant
            if (montant == 0) return false;
        }

        return true;
    }

    // =========================================================================
    // MODULE 5 : CALCULS ACTUARIELS AVANCES
    // =========================================================================
    // Ces fonctions sont pure ou view et peuvent etre appelees par n'importe quel
    // contrat (FondTokenise, TokenizedAsset, TokenizedAssetHolding) sans restriction.

    /// @notice Calcule les interets simples (convention ACT/365, europeenne)
    /// @param principal Montant initial en EUR (18 decimales)
    /// @param tauxAnnuelBp Taux d'interet annuel en bp (ex: 350 = 3.50%)
    /// @param nombreJours Duree de placement en jours calendaires
    /// @return montantFinal Montant apres interets (18 decimales)
    /// @return interets Interets generes (18 decimales)
    ///
    /// @dev Convention ACT/365 : interets = principal × taux × jours / 365
    ///   Methode simple (pas de capitalisation) : appropriee pour les instruments
    ///   court terme (< 1 an). Pour les interets composes, voir calculerInteretsComposes.
    ///   L'ecart simple vs compose pour 1 an a 3.5% est de ~0.06% (negligeable en MMF).
    function calculerInteretsSimples(
        uint256 principal,
        uint256 tauxAnnuelBp,
        uint256 nombreJours
    ) external pure returns (uint256 montantFinal, uint256 interets) {
        require(principal > 0,          "TOOLBOX: Principal nul");
        require(tauxAnnuelBp > 0,       "TOOLBOX: Taux nul");
        require(nombreJours > 0,        "TOOLBOX: Duree nulle");
        require(tauxAnnuelBp <= BASE_POINTS, "TOOLBOX: Taux superieur a 100%");

        // Interets = Principal × (tauxBp / BASE_POINTS) × (jours / JOURS_PAR_AN)
        // = mulDiv(principal × tauxBp, jours, BASE_POINTS × JOURS_PAR_AN)
        // On decompose en deux mulDiv pour plus de lisibilite :
        interets = Math.mulDiv(
            Math.mulDiv(principal, tauxAnnuelBp, BASE_POINTS),
            nombreJours,
            JOURS_PAR_AN
        );

        montantFinal = principal + interets;
    }

    /// @notice Calcule les interets avec capitalisation annuelle (methode ICMA)
    /// @param principal Montant initial en EUR (18 decimales)
    /// @param tauxAnnuelBp Taux d'interet annuel en bp
    /// @param nombreJours Duree de placement en jours
    /// @return montantFinal Montant apres capitalisation (18 decimales)
    /// @return interets Interets cumules generes (18 decimales)
    ///
    /// @dev Approximation de Taylor au 2eme ordre de (1+r)^(t/365) :
    ///   (1+r)^t ≈ 1 + r*t + r²*t*(t-1)/2
    ///   Pour r < 10% et t < 2 ans, l'erreur est inferieure a 0.01%.
    ///   Methode recommandee par l'ICMA (International Capital Market Association).
    function calculerInteretsComposes(
        uint256 principal,
        uint256 tauxAnnuelBp,
        uint256 nombreJours
    ) external pure returns (uint256 montantFinal, uint256 interets) {
        require(principal > 0, "TOOLBOX: Principal nul");
        require(tauxAnnuelBp > 0, "TOOLBOX: Taux nul");
        require(nombreJours > 0, "TOOLBOX: Duree nulle");
        require(tauxAnnuelBp <= BASE_POINTS, "TOOLBOX: Taux superieur a 100%");

        // Terme 1 (lineaire) : r × t / 365 (equivalent interets simples)
        uint256 terme1 = Math.mulDiv(
            Math.mulDiv(principal, tauxAnnuelBp, BASE_POINTS),
            nombreJours,
            JOURS_PAR_AN
        );

        // Terme 2 (quadratique) : r² × t × (t-1) / (2 × 365²)
        // Correction de capitalisation : represente le gain sur le gain
        // Significatif pour t > 180j ou r > 5%
        uint256 terme2 = 0;
        if (nombreJours > 1) {
            // r² × t(t-1) / (2 × 365²)
            // On calcule en plusieurs etapes pour eviter l'overflow
            uint256 r2 = Math.mulDiv(tauxAnnuelBp, tauxAnnuelBp, BASE_POINTS * BASE_POINTS);
            terme2 = Math.mulDiv(
                Math.mulDiv(principal * r2, nombreJours * (nombreJours - 1), PRECISION),
                PRECISION,
                2 * JOURS_PAR_AN * JOURS_PAR_AN
            );
        }

        interets     = terme1 + terme2;
        montantFinal = principal + interets;
    }

    /// @notice Calcule le taux de rendement actuariel annualise (yield) d'un instrument
    /// @param prixAchat Prix d'achat en EUR (18 decimales)
    /// @param valeurRemboursement Valeur de remboursement (nominal) en EUR (18 decimales)
    /// @param dureeJours Duree de detention en jours
    /// @return tauxRendementBp Taux de rendement annualise en points de base
    ///
    /// @dev Formule de taux de rendement simple annualise (ACT/365) :
    ///   taux (bp) = (VR - PA) / PA × 365 / duree × 10 000
    ///   Retourne 0 si VR <= PA (rendement nul ou negatif — cas taux negatifs de marche)
    function calculerTauxRendement(
        uint256 prixAchat,
        uint256 valeurRemboursement,
        uint256 dureeJours
    ) external pure returns (uint256 tauxRendementBp) {
        require(prixAchat > 0, "TOOLBOX: Prix d'achat nul");
        require(dureeJours > 0, "TOOLBOX: Duree nulle");

        // Rendement negatif ou nul : on retourne 0
        // (incompatible avec uint, a signaler au gestionnaire)
        if (valeurRemboursement <= prixAchat) return 0;

        uint256 gain = valeurRemboursement - prixAchat;

        // taux (bp) = gain/prixAchat × (365/duree) × 10000
        // = mulDiv(gain × 365 × 10000, 1, prixAchat × duree)
        // Formule robuste avec mulDiv pour eviter overflow :
        tauxRendementBp = Math.mulDiv(
            gain * JOURS_PAR_AN * BASE_POINTS,
            PRECISION,
            prixAchat * dureeJours
        ) / PRECISION;
        // Division finale par PRECISION pour annuler l'amplification
        // On ne peut pas simplifier PRECISION hors car gain*365*10000 pourrait overflow

        // Formulation alternative plus simple (acceptable si prixAchat >= PRECISION) :
        // tauxRendementBp = (gain * JOURS_PAR_AN * BASE_POINTS) / (prixAchat / PRECISION * dureeJours);
    }

    /// @notice Calcule la duration de Macaulay ponderee d'un portefeuille d'instruments bullet
    /// @param valeurs Valeurs actuelles de chaque instrument (EUR, 18 dec)
    /// @param maturitesJours Maturites restantes de chaque instrument en jours
    /// @return durationPondereeJours Duration ponderee du portefeuille en jours
    ///
    /// @dev Duration de Macaulay pour instruments zero-coupon (bullet) :
    ///   duration(i) = maturite(i) (car tout le cash-flow est a maturite)
    ///   Duration ponderee = sum(valeur(i) × maturite(i)) / sum(valeur(i))
    ///
    ///   Pertinence : la duration mesure la sensibilite de la valeur du portefeuille
    ///   a une variation des taux d'interet (+1% taux = -duration% valeur).
    ///   Un portefeuille MMF avec duration 90j a une sensibilite de 0.25%/1%taux.
    function calculerDurationPortefeuille(
        uint256[] calldata valeurs,
        uint256[] calldata maturitesJours
    ) external pure returns (uint256 durationPondereeJours) {
        require(valeurs.length == maturitesJours.length, "TOOLBOX: Tableaux de tailles differentes");
        require(valeurs.length > 0, "TOOLBOX: Portefeuille vide");
        require(valeurs.length <= MAX_ACTIFS_PORTEFEUILLE, "TOOLBOX: Trop d'actifs");

        uint256 sommeValeurs = 0;
        uint256 sommeValeursXMaturites = 0;

        for (uint256 i = 0; i < valeurs.length; i++) {
            sommeValeurs += valeurs[i];
            // mulDiv(valeur, maturite, 1) = valeur × maturite (sans division)
            // On utilise mulDiv pour la coherence et la protection overflow
            sommeValeursXMaturites += Math.mulDiv(valeurs[i], maturitesJours[i], 1);
        }

        if (sommeValeurs == 0) return 0;

        // Duration = sum(valeur × maturite) / sum(valeur)
        durationPondereeJours = sommeValeursXMaturites / sommeValeurs;
    }

    /// @notice Verifie que la duration du portefeuille respecte la limite de la strategie
    /// @param valeurs Valeurs actuelles des instruments
    /// @param maturitesJours Maturites restantes
    /// @return respecteLimite True si duration <= limite strategique
    /// @return durationActuelle Duration calculee en jours
    function verifierDurationPortefeuille(
        uint256[] calldata valeurs,
        uint256[] calldata maturitesJours
    ) external view returns (bool respecteLimite, uint256 durationActuelle) {
        durationActuelle = this.calculerDurationPortefeuille(valeurs, maturitesJours);
        respecteLimite = durationActuelle <= _strategie.durationMaxJours;
    }

    // =========================================================================
    // MODULE 6 : CALCULS DE VALORISATION NAV AVANCES
    // =========================================================================

    /// @notice Calcule la NAV nette par part apres deduction des frais courants prorata
    /// @param actifNetBrut Actif net brut avant frais (EUR, 18 dec)
    /// @param nombreParts Nombre de parts en circulation
    /// @param dureeSecondesCycle Duree du cycle NAV (secondes)
    /// @return navNette NAV par part nette en EUR (18 decimales)
    /// @return totalFraisPrelevesCycle Frais totaux deduits pour ce cycle en EUR
    function calculerNAVNette(
        uint256 actifNetBrut,
        uint256 nombreParts,
        uint256 dureeSecondesCycle
    ) external view returns (uint256 navNette, uint256 totalFraisPrelevesCycle) {
        require(actifNetBrut > 0, "TOOLBOX: Actif net brut nul");
        require(nombreParts > 0,  "TOOLBOX: Nombre de parts nul");
        require(dureeSecondesCycle > 0, "TOOLBOX: Duree cycle nulle");

        // Calcul des frais courants prorata du cycle
        (
            uint256 fraisGestion,
            uint256 fraisDepositaire,
            uint256 fraisAdmin
        ) = this.calculerFraisCourantsProrata(actifNetBrut, dureeSecondesCycle);

        totalFraisPrelevesCycle = fraisGestion + fraisDepositaire + fraisAdmin;

        // Actif net apres deduction des frais courants
        uint256 actifNetApres = actifNetBrut > totalFraisPrelevesCycle
            ? actifNetBrut - totalFraisPrelevesCycle
            : 0;

        // NAV par part = actif net / nombre de parts (avec precision 18 dec)
        navNette = Math.mulDiv(actifNetApres, PRECISION, nombreParts);
    }

    /// @notice Calcule le nombre de parts a emettre pour un montant de souscription
    /// @param montantSouscriptionEUR Montant net apres frais en EUR (18 dec)
    /// @param navParPart NAV par part du cycle courant en EUR (18 dec)
    /// @return nombreParts Nombre de parts a emettre (18 dec, arrondi vers le bas)
    ///
    /// @dev Arrondi vers le bas (floor) : protection en faveur du fonds.
    ///   Le residuel (montant non couvert par la derniere part) reste en liquidite.
    ///   Exemple : 150 001 EUR souscription, NAV = 1 000 EUR
    ///     -> parts = 150 001 / 1 000 = 150.001 -> 150 parts emises
    ///     -> residuel = 1 EUR reste en liquidites du fonds
    function calculerPartsAEmettre(
        uint256 montantSouscriptionEUR,
        uint256 navParPart
    ) external pure returns (uint256 nombreParts) {
        require(montantSouscriptionEUR > 0, "TOOLBOX: Montant de souscription nul");
        require(navParPart > 0,             "TOOLBOX: NAV par part nulle");

        // parts = (montant × PRECISION) / navParPart
        // La multiplication par PRECISION compense la division pour garder 18 dec
        nombreParts = Math.mulDiv(montantSouscriptionEUR, PRECISION, navParPart);
    }

    /// @notice Calcule le montant EUR brut a verser pour le rachat de parts
    /// @param nombreParts Nombre de parts a racheter (18 dec)
    /// @param navParPart NAV par part du cycle courant (18 dec)
    /// @return montantBrutEUR Montant brut avant deduction des frais de rachat (18 dec)
    function calculerMontantRachat(
        uint256 nombreParts,
        uint256 navParPart
    ) external pure returns (uint256 montantBrutEUR) {
        require(nombreParts > 0,  "TOOLBOX: Nombre de parts nul");
        require(navParPart > 0,   "TOOLBOX: NAV par part nulle");

        // montant = (nombreParts × navParPart) / PRECISION
        // Division par PRECISION car les deux operandes sont en 18 dec
        montantBrutEUR = Math.mulDiv(nombreParts, navParPart, PRECISION);
    }

    // =========================================================================
    // MODULE 7 : ADMINISTRATION DU TOOLBOX
    // =========================================================================

    /// @notice Enregistre un billet de tresorerie pour suivi de valorisation par amortissement
    /// @param identifiant ISIN ou identifiant interne (bytes32)
    /// @param valeurNominale Valeur nominale en EUR (18 dec)
    /// @param prixAcquisition Prix d'achat en EUR (18 dec, <= valeurNominale)
    /// @param tauxRendementBp Taux de rendement annuel en bp
    /// @param dateEmission Timestamp Unix de la date d'emission
    /// @param dateMaturite Timestamp Unix de la date de maturite
    ///
    /// @dev Pattern CEI applique : toutes les verifications avant les modifications d'etat.
    function enregistrerBilletTresorerie(
        bytes32 identifiant,
        uint256 valeurNominale,
        uint256 prixAcquisition,
        uint256 tauxRendementBp,
        uint256 dateEmission,
        uint256 dateMaturite
    )
        external
        onlyRole(ROLE_GESTIONNAIRE)
        whenNotPaused
        nonReentrant
    {
        // --- CHECKS ---
        require(identifiant != bytes32(0),                    "TOOLBOX: Identifiant nul");
        require(valeurNominale > 0,                           "TOOLBOX: Valeur nominale nulle");
        require(prixAcquisition > 0,                          "TOOLBOX: Prix d'acquisition nul");
        require(prixAcquisition <= valeurNominale,            "TOOLBOX: Prix > nominal (impossible pour un billet discount)");
        require(tauxRendementBp > 0,                          "TOOLBOX: Taux de rendement nul");
        require(tauxRendementBp < BASE_POINTS,                "TOOLBOX: Taux de rendement aberrant (>= 100%)");
        require(dateEmission < dateMaturite,                  "TOOLBOX: Emission posterieure a la maturite");
        require(dateMaturite > block.timestamp,               "TOOLBOX: Billet deja echu au moment de l'enregistrement");
        require(!_billetsTresorerie[identifiant].estActif,    "TOOLBOX: Billet deja enregistre - Utilisez une mise a jour");

        uint256 dureeJours = (dateMaturite - dateEmission) / 1 days;
        require(dureeJours > 0,   "TOOLBOX: Duree inferieure a 1 jour");
        require(dureeJours <= 365, "TOOLBOX: Duree > 365 jours - Hors spectre NEU CP (maturite max 1 an)");

        // --- EFFECTS ---
        _billetsTresorerie[identifiant] = ParametresBilletTresorerie({
            identifiant:      identifiant,
            valeurNominale:   valeurNominale,
            prixAcquisition:  prixAcquisition,
            tauxRendementBp:  tauxRendementBp,
            dateEmission:     dateEmission,
            dateMaturite:     dateMaturite,
            dureeJours:       dureeJours,
            estActif:         true
        });

        _listeIdentifiantsBillets.push(identifiant);

        emit BilletTresorerieEnregistre(
            identifiant,
            valeurNominale,
            tauxRendementBp,
            dureeJours,
            block.timestamp
        );
        // Pas d'INTERACTIONS : aucun appel externe dans cette fonction
    }

    /// @notice Met a jour la structure de frais en vigueur
    /// @dev Plafonds de securite codes en dur pour prevenir les configurations frauduleuses.
    ///   Ces plafonds sont inspires des limites AMF pour les fonds de droits francais.
    function mettreAJourFrais(
        uint256 fraisSouscriptionBp,
        uint256 fraisRachatBp,
        uint256 fraisGestionAnnuelsBp,
        uint256 fraisPerformanceBp,
        uint256 hurleRate,
        uint256 fraisDepositaireBp,
        uint256 fraisAdminBp,
        uint256 fraisRachatAnticieBp
    )
        external
        onlyRole(ROLE_ADMIN_FRAIS)
        whenNotPaused
        nonReentrant
    {
        // --- CHECKS : plafonds de securite anti-fraude ---
        // Ces plafonds sont des gardes-fous hard-codes qui ne peuvent pas etre
        // modifies apres deploiement (ils sont dans le bytecode, pas en storage).
        require(fraisSouscriptionBp  <= 500,    "TOOLBOX: Frais entree > 5% - Refuse par mesure de securite");
        require(fraisRachatBp        <= 500,    "TOOLBOX: Frais sortie > 5% - Refuse");
        require(fraisGestionAnnuelsBp <= 500,   "TOOLBOX: Frais gestion > 5%/an - Refuse");
        require(fraisPerformanceBp   <= 3_000,  "TOOLBOX: Frais perf > 30% - Refuse");
        require(hurleRate            <= 2_000,  "TOOLBOX: Hurdle rate > 20%/an - Refuse");
        require(fraisDepositaireBp   <= 100,    "TOOLBOX: Frais depositaire > 1%/an - Refuse");
        require(fraisAdminBp         <= 200,    "TOOLBOX: Frais admin > 2%/an - Refuse");
        require(fraisRachatAnticieBp <= 500,    "TOOLBOX: Penalite rachat anticipe > 5% - Refuse");

        // --- EFFECTS ---
        _frais = StructureFrais({
            fraisSouscriptionEntrantBp: fraisSouscriptionBp,
            fraisRachatSortantBp:       fraisRachatBp,
            fraisGestionAnnuelsBp:      fraisGestionAnnuelsBp,
            fraisPerformanceBp:         fraisPerformanceBp,
            hurleRate:                  hurleRate,
            fraisDepositaireAnnuelsBp:  fraisDepositaireBp,
            fraisAdminAnnuelsBp:        fraisAdminBp,
            fraisRachatAnticieBp:       fraisRachatAnticieBp,
            derniereMiseAJour:          block.timestamp
        });

        emit FraisMisAJour(
            fraisSouscriptionBp,
            fraisRachatBp,
            fraisGestionAnnuelsBp,
            fraisPerformanceBp,
            block.timestamp,
            msg.sender
        );
        // Pas d'INTERACTIONS : aucun appel externe
    }

    /// @notice Met a jour la strategie d'investissement
    /// @dev Les allocations doivent totaliser exactement 10 000 bp (via le modifier).
    ///   Un minimum de 10% de liquidites est impose pour proteger la liquidite du fonds.
    function mettreAJourStrategie(
        uint256 allocationBilletsBp,
        uint256 allocationObligationsBp,
        uint256 allocationActionsBp,
        uint256 allocationLiquiditesBp,
        uint256 toleranceDeviationBp,
        uint256 durationMaxJours,
        uint8   ratingMinimum
    )
        external
        onlyRole(ROLE_GESTIONNAIRE)
        whenNotPaused
        nonReentrant
        allocationsTotalisent100Pourcent(
            allocationBilletsBp,
            allocationObligationsBp,
            allocationActionsBp,
            allocationLiquiditesBp
        )
    {
        // --- CHECKS ---
        require(toleranceDeviationBp >= 10,
            "TOOLBOX: Tolerance deviation < 0.1bp - Trop restrictif (gas excessif)");
        require(toleranceDeviationBp <= 1_000,
            "TOOLBOX: Tolerance deviation > 10% - Trop permissif (risque de derive)");
        require(durationMaxJours >= 1,
            "TOOLBOX: Duration max < 1 jour - Impossible");
        require(durationMaxJours <= 730,
            "TOOLBOX: Duration max > 2 ans - Incompatible avec un profil MMF/FIA court terme");
        require(ratingMinimum >= 1 && ratingMinimum <= 7,
            "TOOLBOX: Code rating invalide (1=AAA ... 7=BBB-)");
        require(allocationLiquiditesBp >= RATIO_LIQUIDITE_MIN_BP,
            "TOOLBOX: Allocation liquidites < 10% - Risque de liquidite inacceptable (AMF)");

        // --- EFFECTS ---
        _strategie = StrategieInvestissement({
            allocationBilletsTresorerieBp:  allocationBilletsBp,
            allocationObligationsBp:         allocationObligationsBp,
            allocationActionsBp:             allocationActionsBp,
            allocationLiquiditesBp:          allocationLiquiditesBp,
            toleranceDeviationBp:            toleranceDeviationBp,
            durationMaxJours:                durationMaxJours,
            ratingMinimumContrepartie:       ratingMinimum,
            derniereMiseAJour:               block.timestamp
        });

        emit StrategieMiseAJour(
            allocationBilletsBp,
            allocationObligationsBp,
            toleranceDeviationBp,
            durationMaxJours,
            block.timestamp,
            msg.sender
        );
        // Pas d'INTERACTIONS
    }

    /// @notice Enregistre un investisseur qualifie dans le Toolbox (complement KYC Fund)
    /// @param investisseur Adresse de l'investisseur
    /// @param plafondIndividuelEUR Plafond d'investissement individuel (EUR, 18 dec)
    /// @param datePremiereEntree Timestamp de la premiere souscription (pour lock-up)
    ///
    /// @dev Doit etre appele en synchronisation avec le whitelisting dans FondTokenise.
    ///   Permet au Toolbox de calculer correctement les plafonds et le lock-up.
    function enregistrerInvestisseurQualifie(
        address investisseur,
        uint256 plafondIndividuelEUR,
        uint256 datePremiereEntree
    )
        external
        onlyRole(ROLE_COMPLIANCE)
    {
        // --- CHECKS ---
        require(investisseur != address(0),                "TOOLBOX: Adresse investisseur invalide");
        require(plafondIndividuelEUR >= SOUSCRIPTION_MINIMUM,
            "TOOLBOX: Plafond individuel inferieur au minimum de souscription");

        // --- EFFECTS ---
        _investisseursQualifies[investisseur] = true;

        // Enregistrement de la date de premiere entree pour le calcul du lock-up
        // On ne remplace la date que si elle n'est pas deja definie (premiere souscription)
        if (datePremiereEntree > 0 && _datePremiereEntree[investisseur] == 0) {
            _datePremiereEntree[investisseur] = datePremiereEntree;
        }

        emit InvestisseurQualifieEnregistre(
            investisseur,
            plafondIndividuelEUR,
            block.timestamp
        );
    }

    /// @notice Met a jour le montant cumule investi par un investisseur (synchronise par le Fund)
    /// @param investisseur Adresse de l'investisseur
    /// @param montantAdditionnelEUR Montant additionnel souscrit (EUR, 18 dec)
    /// @dev Seul le contrat Fund autorise peut appeler cette fonction
    function mettreAJourMontantInvesti(
        address investisseur,
        uint256 montantAdditionnelEUR
    ) external seulementFondAutorise {
        require(investisseur != address(0), "TOOLBOX: Adresse invalide");
        _montantsInvestisParInvestisseur[investisseur] += montantAdditionnelEUR;
    }

    /// @notice Met a jour le plafond de souscription individuel global
    /// @param nouveauPlafondEUR Nouveau plafond en EUR (18 dec)
    function mettreAJourPlafondSouscription(
        uint256 nouveauPlafondEUR
    ) external onlyRole(ROLE_COMPLIANCE) {
        require(nouveauPlafondEUR >= SOUSCRIPTION_MINIMUM,
            "TOOLBOX: Plafond inferieur au minimum de souscription institutionnel");

        uint256 ancienPlafond = _plafondSouscriptionIndividuelEUR;
        _plafondSouscriptionIndividuelEUR = nouveauPlafondEUR;

        emit PlafondMisAJour(ancienPlafond, nouveauPlafondEUR, block.timestamp);
    }

    /// @notice Pause d'urgence du Toolbox (circuit breaker reglementaire)
    function pauserToolbox() external onlyRole(ROLE_ADMIN) {
        _pause();
    }

    /// @notice Reprise apres pause (necessite ROLE_ADMIN)
    function reprendreToolbox() external onlyRole(ROLE_ADMIN) {
        _unpause();
    }

    // =========================================================================
    // FONCTIONS DE LECTURE (VIEW) — TRANSPARENCE ET AUDITABILITE
    // =========================================================================
    // Toutes ces fonctions sont view (gratuites en lecture seule).
    // Elles permettent aux auditeurs, valorisateurs et systemes off-chain
    // d'acceder aux parametres en vigueur sans frais de gas.

    /// @notice Retourne la structure de frais en vigueur
    function lireStructureFrais() external view returns (StructureFrais memory) {
        return _frais;
    }

    /// @notice Retourne la strategie d'investissement en vigueur
    function lireStrategie() external view returns (StrategieInvestissement memory) {
        return _strategie;
    }

    /// @notice Retourne le High Water Mark actuel
    function lireHighWaterMark() external view returns (HighWaterMark memory) {
        return _highWaterMark;
    }

    /// @notice Retourne les parametres d'un billet de tresorerie
    function lireBilletTresorerie(bytes32 identifiant)
        external
        view
        returns (ParametresBilletTresorerie memory)
    {
        return _billetsTresorerie[identifiant];
    }

    /// @notice Retourne la liste de tous les identifiants de billets enregistres
    function lireListeBillets() external view returns (bytes32[] memory) {
        return _listeIdentifiantsBillets;
    }

    /// @notice Retourne la tolerance de deviation de portefeuille (bp)
    function lireToleranceDeviation() external view returns (uint256) {
        return _strategie.toleranceDeviationBp;
    }

    /// @notice Retourne la duration maximale autorisee par la strategie (jours)
    function lireDurationMaxAutorisee() external view returns (uint256) {
        return _strategie.durationMaxJours;
    }

    /// @notice Retourne le total des frais courants annuels en bp (sans frais de perf)
    /// @dev Utile pour le calcul du TER (Total Expense Ratio) du fonds
    function lireTotalFraisCourantsAnnuelsBp() external view returns (uint256) {
        return _frais.fraisGestionAnnuelsBp
             + _frais.fraisDepositaireAnnuelsBp
             + _frais.fraisAdminAnnuelsBp;
    }

    /// @notice Retourne le plafond de souscription individuel (EUR, 18 dec)
    function lirePlafondSouscriptionIndividuel() external view returns (uint256) {
        return _plafondSouscriptionIndividuelEUR;
    }

    /// @notice Retourne true si l'investisseur est marque comme qualifie dans le Toolbox
    function estInvestisseurQualifie(address investisseur) external view returns (bool) {
        return _investisseursQualifies[investisseur];
    }

    /// @notice Retourne le montant cumule investi par un investisseur
    function lireMontantInvesti(address investisseur) external view returns (uint256) {
        return _montantsInvestisParInvestisseur[investisseur];
    }

    /// @notice Retourne la date de premiere entree d'un investisseur (pour lock-up)
    function lireDatePremiereEntree(address investisseur) external view returns (uint256) {
        return _datePremiereEntree[investisseur];
    }

    /// @notice Calcule si la periode de lock-up est ecoulee pour un investisseur
    /// @return estLockupEcoule True si l'investisseur peut racheter sans penalite
    /// @return secondesRestantes Secondes restantes avant fin du lock-up (0 si ecoule)
    function verifierLockup(address investisseur)
        external
        view
        returns (bool estLockupEcoule, uint256 secondesRestantes)
    {
        uint256 dateEntree = _datePremiereEntree[investisseur];
        if (dateEntree == 0) {
            // Jamais souscrit : lock-up non applicable
            return (true, 0);
        }

        uint256 finLockup = dateEntree + PERIODE_LOCK_UP;
        if (block.timestamp >= finLockup) {
            return (true, 0);
        } else {
            return (false, finLockup - block.timestamp);
        }
    }
}
