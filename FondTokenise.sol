// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

//  Smart Contract FONDTOKENISE — v2.0.0
//  Contrat central de gestion du fonds tokenise
//
//  MODIFICATIONS v2.0.0 vs v1.0.0 :
//  [FIX-1] IToolbox etendue : 8 nouvelles signatures alignees avec Toolbox.sol
//  [FIX-2] Frais courants prorata (management fee) integres dans _executerCycleNAV
//  [FIX-3] Mise a jour du High Water Mark apres chaque cycle NAV
//  [FIX-4] Delegation des calculs parts/rachat au Toolbox (Math.mulDiv unifie)
//  [FIX-5] Lock-up et frais anticipes deleguees a _toolbox.verifierLockup()
//          et _toolbox.calculerFraisRachatComplets()
//  [FIX-6] Synchronisation _toolbox.mettreAJourMontantInvesti() post-souscription
//  [FIX-7] Correction typo "numeroC ycle" -> "numeroCycle" dans struct CycleNAV
//  [FIX-8] SECONDES_PAR_AN aligne sur ACT/365 (= 365 days, cohérent avec Toolbox)
//  [FIX-9] Correction override supportsInterface : retrait de ERC20 (non applicable)
//
//  Conformite : AMF / CSSF / AIFMD / MiFID II / EMIR
//  Convention  : ACT/365 (Euro Money Market)
// =============================================================================

// =============================================================================
// IMPORTS DES BIBLIOTHEQUES OPENZEPPELIN
// =============================================================================
// OpenZeppelin est la reference absolue pour les contrats institutionnels :
// - audite par des tiers independants (Trail of Bits, OpenZeppelin Security)
// - battle-tested sur des milliards de $ de TVL
// - conforme aux standards ERC les plus recents (ERC20, AccessControl)

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// ERC20 : standard de token fongible.
// Les parts du fonds sont des tokens ERC20 : transferables, auditables,
// et compatibles avec les protocoles DeFi institutionnels.

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
// ERC20Burnable : permet la destruction de parts lors des rachats.
// La destruction est atomique avec la liberation des liquidites (finalite).

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
// ERC20Pausable : circuit breaker sur les transferts de parts.
// Conforme au pouvoir de suspension de l'AMF (Art. L214-8-7 CMF).

import "@openzeppelin/contracts/access/AccessControl.sol";
// AccessControl : RBAC multi-roles.
// Obligatoire pour respecter la separation des fonctions en gestion d'actifs.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// ReentrancyGuard : protection contre les attaques de re-entrance (DAO hack 2016).
// OBLIGATOIRE sur tout contrat manipulant des fonds.

import "@openzeppelin/contracts/utils/Pausable.sol";
// Pausable : mecanisme de pause global du contrat.

import "@openzeppelin/contracts/utils/math/Math.sol";
// [FIX-4] Math.mulDiv : calcul a*b/c sans overflow intermediaire.
// Indispensable pour les multiplications en virgule fixe 18 dec.
// Exemple : (1e24 * 1e18) / 1e18 depasse uint256 sans mulDiv.

// =============================================================================
// INTERFACE DU SMART CONTRACT TOOLBOX — v2.0.0
// =============================================================================
// [FIX-1] Interface etendue pour exposer toutes les fonctions du Toolbox
// utilisees dans le cycle NAV v2 :
//   - calculerFraisCourantsProrata : frais de gestion journaliers
//   - calculerFraisRachatComplets  : frais rachat avec detection lock-up
//   - calculerFraisPerformance     : High Water Mark
//   - mettreAJourHighWaterMark     : notification HWM au Toolbox
//   - mettreAJourMontantInvesti    : synchronisation plafonds de concentration
//   - calculerPartsAEmettre        : delegation calcul parts (mulDiv unifie)
//   - calculerMontantRachat        : delegation calcul montant rachat
//   - verifierLockup               : verification periode de blocage
//
// Pourquoi une interface plutot qu'un import direct ?
//   1. Decouplage : le Toolbox peut etre mis a jour sans redeployer le Fund
//   2. Securite : surface de confiance minimale (minimal trust surface)
//   3. Le compilateur verifie la coherence des signatures automatiquement

interface IToolbox {

    // -------------------------------------------------------------------------
    // Fonctions core (presentes en v1)
    // -------------------------------------------------------------------------

    /// @notice Calcule la depreciation lineaire d'un billet de tresorerie (NEU CP)
    function calculerDepreciationLineaire(
        uint256 valeurNominale,
        uint256 tauxAnnuel,
        uint256 dureeJours,
        uint256 joursEcoules
    ) external pure returns (uint256 valeurActuelle);

    /// @notice Calcule les frais de transaction (entree ou sortie standard)
    function calculerFrais(
        uint256 montant,
        uint8 typeOperation
    ) external view returns (uint256 frais);

    /// @notice Calcule les ajustements de reequilibrage du portefeuille
    function calculerAjustementsPortefeuille(
        uint256 valeurTotalePortefeuille,
        uint256[] calldata allocationsActuelles,
        uint256[] calldata allocationsCibles
    ) external pure returns (int256[] memory ajustements);

    /// @notice Valide la conformite reglementaire d'une operation
    function validerConformite(
        address investisseur,
        uint256 montant,
        uint8 typeOperation
    ) external view returns (bool estValide);

    // -------------------------------------------------------------------------
    // [FIX-1] Nouvelles fonctions ajoutees en v2
    // -------------------------------------------------------------------------

    /// @notice [FIX-2] Calcule les frais courants prorata temporis pour un cycle NAV
    /// @param actifNetTotal ANT du fonds en EUR (18 dec)
    /// @param dureeSecondesCycle Duree du cycle en secondes
    /// @return fraisGestion Frais de gestion prorata (EUR, 18 dec)
    /// @return fraisDepositaire Frais depositaire prorata (EUR, 18 dec)
    /// @return fraisAdmin Frais admin prorata (EUR, 18 dec)
    function calculerFraisCourantsProrata(
        uint256 actifNetTotal,
        uint256 dureeSecondesCycle
    ) external view returns (
        uint256 fraisGestion,
        uint256 fraisDepositaire,
        uint256 fraisAdmin
    );

    /// @notice [FIX-5] Calcule les frais de rachat avec detection du lock-up
    /// @param montant Montant du rachat en EUR (18 dec)
    /// @param investisseur Adresse de l'investisseur (pour verifier le lock-up)
    /// @return frais Frais totaux (standard ou majores si rachat anticipe)
    /// @return estAnticipe True si le rachat est avant la fin du lock-up
    function calculerFraisRachatComplets(
        uint256 montant,
        address investisseur
    ) external view returns (uint256 frais, bool estAnticipe);

    /// @notice [FIX-3] Calcule les frais de performance (High Water Mark)
    /// @param navParPartActuelle NAV par part actuelle (EUR, 18 dec)
    /// @param nombrePartsTotales Nombre de parts en circulation
    /// @return fraisPerformance Frais de perf en EUR (0 si sous le HWM)
    function calculerFraisPerformance(
        uint256 navParPartActuelle,
        uint256 nombrePartsTotales
    ) external view returns (uint256 fraisPerformance);

    /// @notice [FIX-3] Met a jour le High Water Mark si nouveau sommet atteint
    /// @param navParPartActuelle NAV par part actuelle (EUR, 18 dec)
    /// @param cycleNAV Numero du cycle NAV courant
    function mettreAJourHighWaterMark(
        uint256 navParPartActuelle,
        uint256 cycleNAV
    ) external;

    /// @notice [FIX-6] Met a jour le montant cumule investi par un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @param montantAdditionnelEUR Montant additionnel souscrit (EUR, 18 dec)
    function mettreAJourMontantInvesti(
        address investisseur,
        uint256 montantAdditionnelEUR
    ) external;

    /// @notice [FIX-4] Calcule le nombre de parts a emettre pour un montant souscrit
    /// @param montantSouscriptionEUR Montant net en EUR (18 dec)
    /// @param navParPart NAV par part du cycle courant (18 dec)
    /// @return nombreParts Nombre de parts a emettre (arrondi vers le bas)
    function calculerPartsAEmettre(
        uint256 montantSouscriptionEUR,
        uint256 navParPart
    ) external pure returns (uint256 nombreParts);

    /// @notice [FIX-4] Calcule le montant EUR brut a verser pour un rachat de parts
    /// @param nombreParts Nombre de parts a racheter (18 dec)
    /// @param navParPart NAV par part du cycle courant (18 dec)
    /// @return montantBrutEUR Montant brut avant frais (18 dec)
    function calculerMontantRachat(
        uint256 nombreParts,
        uint256 navParPart
    ) external pure returns (uint256 montantBrutEUR);

    /// @notice [FIX-5] Verifie si la periode de lock-up est ecoulee pour un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @return estLockupEcoule True si l'investisseur peut racheter sans penalite
    /// @return secondesRestantes Secondes restantes avant fin du lock-up (0 si ecoule)
    function verifierLockup(
        address investisseur
    ) external view returns (bool estLockupEcoule, uint256 secondesRestantes);
}

// =============================================================================
// SMART CONTRACT PRINCIPAL : FOND TOKENISE v2.0.0
// =============================================================================
// Architecture :
//   - Heritage multiple OpenZeppelin (composition securisee et auditee)
//   - Pattern CEI (Checks-Effects-Interactions) applique systematiquement
//   - Double protection reentrance : ReentrancyGuard OZ + verrou applicatif NAV
//   - Tous les etats critiques modifies AVANT tout appel externe
//   - Events sur chaque mutation d'etat (traçabilite reglementaire immuable)
//   - Registre des actionnaires integre (conformite AMF/CSSF)
//   - Delegation systematique des calculs financiers au Toolbox

contract FondTokenise is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    AccessControl,
    ReentrancyGuard
{
    // [FIX-4] Import de Math pour mulDiv dans les calculs internes residuels
    using Math for uint256;

    // =========================================================================
    // ROLES (RBAC — Role Based Access Control)
    // =========================================================================
    // Principe de separation des pouvoirs ("four eyes" / deux paires d'yeux) :
    // chaque role correspond a une fonction metier distincte. Un operateur ne
    // peut pas cumuler les roles de gestionnaire et de compliance, par exemple.

    /// @dev Gestionnaire de fonds : strategy d'investissement, ajout d'actifs
    bytes32 public constant ROLE_GESTIONNAIRE  = keccak256("GESTIONNAIRE");

    /// @dev Compliance officer : KYC/AML, whitelist/blacklist, conformite
    bytes32 public constant ROLE_COMPLIANCE    = keccak256("COMPLIANCE");

    /// @dev Depositaire : confirmation des mouvements de liquidites en EUR
    bytes32 public constant ROLE_DEPOSITAIRE   = keccak256("DEPOSITAIRE");

    /// @dev Valorisateur : soumission des prix des actifs (source de verite NAV)
    bytes32 public constant ROLE_VALORISATEUR  = keccak256("VALORISATEUR");

    /// @dev Auditeur : acces lecture seule aux donnees sensibles
    bytes32 public constant ROLE_AUDITEUR      = keccak256("AUDITEUR");

    /// @dev Administrateur systeme : roles, parametres critiques, pause
    bytes32 public constant ROLE_ADMIN         = keccak256("ADMIN");

    // =========================================================================
    // CONSTANTES FINANCIERES
    // =========================================================================
    // Les constantes sont gravees dans le bytecode : elles ne peuvent jamais
    // etre modifiees apres deploiement, meme par l'admin.
    // Avantage gas : pas de SLOAD, valeur inline dans le bytecode EVM.

    /// @notice Precision virgule fixe : 18 decimales (standard ERC20, compatible EUR)
    uint256 public constant PRECISION = 1e18;

    /// @notice Base en points de base : 10 000 bp = 100%
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice [FIX-8] Secondes par an — Convention ACT/365 (Euro Money Market)
    /// CORRECTION v2 : v1 utilisait 365 days + 6 hours (= ACT/365.25, convention
    /// US/ISDA), ce qui cree un ecart avec le Toolbox qui utilise ACT/365.
    /// La convention ACT/365 (= 365 days exactement) est la norme europeenne
    /// pour les instruments de taux en EUR : NEU CP, OAT, EONIA, EURIBOR.
    /// Source : ICMA Rule Book, Section 251 ; ISDA 2006 Definitions (EUR).
    uint256 public constant SECONDES_PAR_AN = 365 days; // [FIX-8] : etait 365 days + 6 hours

    /// @notice NAV initiale par part : 1 000 EUR (standard institutionnel europeen)
    /// Choisie pour faciliter la lecture par les investisseurs :
    /// une part = 1 000 EUR au lancement, la performance est immediatement lisible.
    uint256 public constant NAV_INITIALE = 1_000 * PRECISION;

    /// @notice Montant minimum de souscription institutionnelle : 100 000 EUR
    /// Seuil reglementaire investisseur qualifie (Art. 423-27 AMF).
    /// Maintenu comme garde-fou cote Fund en complement du Toolbox.
    uint256 public constant SOUSCRIPTION_MINIMUM = 100_000 * PRECISION;

    /// @notice Periode de blocage des rachats : 90 jours (AIFMD Art. 23)
    /// [FIX-5] : utilisee uniquement comme valeur de reference pour les messages
    /// d'erreur. La verification effective est desormais deleguee au Toolbox.
    uint256 public constant PERIODE_BLOCAGE = 90 days;

    // =========================================================================
    // STRUCTURES DE DONNEES
    // =========================================================================

    /// @notice Ordre de souscription ou de rachat
    struct Ordre {
        address investisseur;       // Adresse blockchain de l'investisseur
        uint256 montantEUR;         // Montant en EUR (souscription) ou nombre de parts (rachat)
        uint256 horodatage;         // Timestamp de reception de l'ordre (Unix)
        uint256 cycleNAV;           // Numero du cycle NAV associe a cet ordre
        TypeOrdre typeOrdre;        // SOUSCRIPTION ou RACHAT
        StatutOrdre statut;         // EN_ATTENTE | EXECUTE | ANNULE | REJETE
        bytes32 empreinteOrdre;     // Hash de l'ordre pour verification d'integrite tamper-proof
    }

    /// @notice Instantane complet d'un cycle NAV (immuable apres finalisation)
    struct CycleNAV {
        uint256 numeroCycle;           // [FIX-7] Correction typo : "numeroC ycle" -> "numeroCycle"
        uint256 horodatage;            // Timestamp de cloture du cycle
        uint256 navParPart;            // NAV par part en EUR (18 dec)
        uint256 actifNetTotal;         // ANT du fonds en EUR apres frais courants
        uint256 nombrePartsTotales;    // Parts totales en circulation apres mint/burn
        uint256 liquiditesDisponibles; // Liquidites en EUR apres reglement
        uint256 fraisCourantsCycle;    // [FIX-2] Frais courants preleves ce cycle (EUR)
        uint256 fraisPerformanceCycle; // [FIX-3] Frais de performance preleves ce cycle (EUR)
        bytes32 empreinteEtat;         // Hash cryptographique de l'etat pour audit
        bool estFinalise;              // True si le cycle est irreversiblement clos
    }

    /// @notice Actif du portefeuille
    struct Actif {
        bytes32 identifiant;        // ISIN ou identifiant interne
        string description;         // Description lisible (ex: "NEU CP Renault 3M")
        uint256 valeurActuelle;     // Valeur en EUR (18 dec), mise a jour par le valorisateur
        uint256 allocationCible;    // Allocation cible en bp (ex: 2000 = 20%)
        TypeActif typeActif;        // Enumeration du type d'instrument
        uint256 derniereMiseAJour;  // Timestamp de la derniere valorisation soumise
        bool estActif;              // False si l'actif a ete retire du portefeuille
    }

    /// @notice Entree du registre des actionnaires
    struct EntreeRegistre {
        address adresse;               // Adresse blockchain
        string identiteKYC;            // Ref. KYC hachee (RGPD : pas d'identite en clair)
        uint256 partsDetenues;         // Parts en circulation (redondant avec balanceOf, pour audit)
        uint256 montantInvesti;        // Montant cumule investi en EUR (18 dec)
        uint256 datePremiereEntree;    // Timestamp premiere souscription (reference lock-up)
        uint256 dateDerniereOperation; // Timestamp derniere operation
        bool estWhiteliste;            // Statut KYC/AML valide
        bool estBlackliste;            // Gel reglementaire ou sanctions
    }

    // =========================================================================
    // ENUMERATIONS
    // =========================================================================

    enum TypeOrdre   { SOUSCRIPTION, RACHAT }
    enum StatutOrdre { EN_ATTENTE, EXECUTE, ANNULE, REJETE }
    enum TypeActif   { BILLET_TRESORERIE, OBLIGATION, ACTION, LIQUIDITE, AUTRE }

    // =========================================================================
    // VARIABLES D'ETAT
    // =========================================================================
    // Toutes les variables sont private : acces uniquement via getters dedies.
    // Principe de moindre privilege (least privilege) pour les auditeurs.

    /// @notice Contrat Toolbox — bibliotheque de calculs financiers externalisee
    IToolbox private _toolbox;

    /// @notice Nom officiel du fonds
    string private _nomFonds;

    /// @notice Code ISIN du fonds (12 caracteres, ex: "FR0000000000")
    string private _isinFonds;

    /// @notice Compteur de cycles NAV (commence a 1 ; cycle 0 = etat initial)
    uint256 private _numeroCycleActuel;

    /// @notice Historique immuable des cycles NAV : numero => CycleNAV
    mapping(uint256 => CycleNAV) private _cyclesNAV;

    /// @notice Registre de tous les ordres : idOrdre => Ordre
    mapping(bytes32 => Ordre) private _ordres;

    /// @notice File des ordres par cycle : numeroCycle => liste d'IDs
    mapping(uint256 => bytes32[]) private _ordresParCycle;

    /// @notice Registre des actionnaires : adresse => EntreeRegistre
    mapping(address => EntreeRegistre) private _registreActionnaires;

    /// @notice Liste ordonnee des adresses actionnaires (iteration pour audit)
    address[] private _listeActionnaires;

    /// @notice Portefeuille : identifiant actif => Actif
    mapping(bytes32 => Actif) private _portefeuille;

    /// @notice Liste ordonnee des identifiants d'actifs
    bytes32[] private _listeActifs;

    /// @notice Liquidites disponibles en EUR (18 dec)
    uint256 private _liquiditesEUR;

    /// @notice NAV par part courante en EUR (18 dec)
    uint256 private _navParPart;

    /// @notice Actif Net Total du fonds en EUR (18 dec)
    uint256 private _actifNetTotal;

    /// @notice Verrou applicatif anti-reentrance NAV (complement a ReentrancyGuard)
    bool private _enCoursDeTraitement;

    /// @notice Timestamp de la derniere cloture de cycle NAV
    uint256 private _horodatageLastCycle;

    // =========================================================================
    // EVENEMENTS — TRACE REGLEMENTAIRE IMMUABLE
    // =========================================================================
    // Chaque evenement est stocke dans les logs de la blockchain :
    // preuve irrefutable, non modifiable, horodatee.
    // Conformite MIF II (Art. 25), EMIR (reporting), AMF (Art. 314-74).

    /// @notice Reception d'un ordre de souscription
    event OrdreRecu(
        bytes32 indexed idOrdre,
        address indexed investisseur,
        uint256 montantEUR,
        uint256 indexed cycleNAV,
        uint256 horodatage
    );

    /// @notice Reception d'un ordre de rachat
    event OrdreRachatRecu(
        bytes32 indexed idOrdre,
        address indexed investisseur,
        uint256 nombreParts,
        uint256 indexed cycleNAV,
        uint256 horodatage
    );

    /// @notice Execution complete d'une souscription (mint)
    event SouscriptionExecutee(
        bytes32 indexed idOrdre,
        address indexed investisseur,
        uint256 montantNetEUR,
        uint256 partsEmises,
        uint256 navUtilisee,
        uint256 fraisTransaction,
        uint256 indexed cycleNAV
    );

    /// @notice Execution complete d'un rachat (burn)
    /// [FIX-5] Ajout de estRachatAnticipe pour traçabilite des penalites
    event RachatExecute(
        bytes32 indexed idOrdre,
        address indexed investisseur,
        uint256 partsRachetees,
        uint256 montantNetEURVerse,
        uint256 navUtilisee,
        uint256 fraisTransaction,
        bool estRachatAnticipe,
        uint256 indexed cycleNAV
    );

    /// @notice Cloture d'un cycle NAV (enregistrement immuable de valorisation)
    /// [FIX-2][FIX-3] Ajout des frais courants et de performance dans l'event
    event CycleNAVCloture(
        uint256 indexed numeroCycle,
        uint256 navParPart,
        uint256 actifNetTotal,
        uint256 nombrePartsTotales,
        uint256 fraisCourantsCycle,
        uint256 fraisPerformanceCycle,
        bytes32 empreinteEtat,
        uint256 horodatage
    );

    /// @notice Mise a jour de la NAV suite a une valorisation d'actif
    event NAVMiseAJour(
        uint256 ancienneNAV,
        uint256 nouvelleNAV,
        uint256 actifNetTotal,
        uint256 horodatage,
        address indexed valorisateur
    );

    /// @notice Mouvement de liquidites (apport ou prelevement)
    event LiquiditesMiseAJour(
        uint256 ancienMontant,
        uint256 nouveauMontant,
        string motif,
        uint256 horodatage
    );

    /// @notice Modification du registre des actionnaires
    event RegistreActionnairesModifie(
        address indexed actionnaire,
        uint256 ancienSolde,
        uint256 nouveauSolde,
        string motif,
        uint256 horodatage
    );

    /// @notice Ajout d'un actif au portefeuille
    event ActifAjoute(
        bytes32 indexed identifiant,
        string description,
        TypeActif typeActif,
        uint256 valeurInitiale,
        uint256 allocationCible
    );

    /// @notice Mise a jour de la valorisation d'un actif
    event ActifValoriseMAJ(
        bytes32 indexed identifiant,
        uint256 ancienneValeur,
        uint256 nouvelleValeur,
        uint256 horodatage,
        address indexed valorisateur
    );

    /// @notice Reequilibrage du portefeuille declenche par un cycle NAV
    event PortefeuilleReequilibre(
        uint256 indexed cycleNAV,
        int256[] ajustements,
        uint256 horodatage
    );

    /// @notice Mise a jour de l'adresse du Toolbox
    event ToolboxMiseAJour(
        address ancienneAdresse,
        address nouvelleAdresse,
        uint256 horodatage
    );

    /// @notice Whitelisting d'un investisseur apres KYC/AML
    event InvestisseurWhiteliste(
        address indexed investisseur,
        uint256 horodatage
    );

    /// @notice Blacklisting d'un investisseur (gel reglementaire)
    event InvestisseurBlackliste(
        address indexed investisseur,
        string motif,
        uint256 horodatage
    );

    /// @notice Alerte de securite critique (audit trail)
    event AlerteSecurite(
        string description,
        address indexed declencheur,
        uint256 horodatage
    );

    /// @notice [FIX-2] Frais courants preleves lors d'un cycle NAV
    event FraisCourantsPreleves(
        uint256 indexed cycleNAV,
        uint256 fraisGestion,
        uint256 fraisDepositaire,
        uint256 fraisAdmin,
        uint256 totalFrais,
        uint256 horodatage
    );

    /// @notice [FIX-3] Frais de performance preleves lors d'un cycle NAV
    event FraisPerformancePreleves(
        uint256 indexed cycleNAV,
        uint256 fraisPerformance,
        uint256 navAvantFrais,
        uint256 horodatage
    );

    /// @notice [FIX-5] Rachat anticipe detecte (avant fin de lock-up)
    event RachatAnticiipeDetecte(
        bytes32 indexed idOrdre,
        address indexed investisseur,
        uint256 secondesRestantes,
        uint256 fraisPenalite,
        uint256 horodatage
    );

    // =========================================================================
    // MODIFICATEURS
    // =========================================================================

    /// @dev Verifie que l'investisseur est whiteliste et non blackliste (KYC/AML)
    /// Obligatoire pour toute operation financiere.
    modifier seulementInvestisseurAutorise(address investisseur) {
        require(
            _registreActionnaires[investisseur].estWhiteliste,
            "FOND: Investisseur non whiteliste - KYC/AML requis"
        );
        require(
            !_registreActionnaires[investisseur].estBlackliste,
            "FOND: Investisseur blackliste - Operation impossible"
        );
        _;
    }

    /// @dev Verifie que le Toolbox est configure (adresse non nulle)
    modifier toolboxConfiguree() {
        require(
            address(_toolbox) != address(0),
            "FOND: Toolbox non configure - Deployer Toolbox.sol en premier"
        );
        _;
    }

    /// @dev Empeche toute nouvelle operation pendant un cycle NAV en cours
    /// Double protection avec ReentrancyGuard d'OpenZeppelin.
    /// Garantit que chaque ordre declenche exactement un cycle NAV complet.
    modifier pasEnCoursDeTraitement() {
        require(
            !_enCoursDeTraitement,
            "FOND: Cycle NAV en cours - Reessayez apres cloture du cycle courant"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTEUR
    // =========================================================================

    /// @notice Deploie le Smart Contract Fund
    /// @param nomFonds Nom officiel du fonds (ex: "Fonds Monetaire BNP Paribas")
    /// @param symboleParts Symbole ERC20 des parts (ex: "FMP-BNP")
    /// @param isinFonds Code ISIN du fonds — exactement 12 caracteres (ex: "FR0000000000")
    /// @param adresseToolbox Adresse du contrat Toolbox prealablement deploye
    /// @param liquiditesInitiales Apport initial de liquidites en EUR (18 dec)
    ///
    /// @dev L'ordre de deploiement obligatoire est : Toolbox PUIS FondTokenise.
    ///   Le constructeur verifie que l'adresse Toolbox est valide et non nulle.
    constructor(
        string memory nomFonds,
        string memory symboleParts,
        string memory isinFonds,
        address adresseToolbox,
        uint256 liquiditesInitiales
    )
        ERC20(nomFonds, symboleParts)
    {
        // --- CHECKS ---
        require(bytes(nomFonds).length > 0,        "FOND: Nom du fonds vide");
        require(bytes(symboleParts).length > 0,    "FOND: Symbole vide");
        require(bytes(isinFonds).length == 12,     "FOND: ISIN invalide - exactement 12 caracteres");
        require(adresseToolbox != address(0),      "FOND: Adresse Toolbox invalide");

        // --- EFFECTS ---
        _nomFonds              = nomFonds;
        _isinFonds             = isinFonds;
        _toolbox               = IToolbox(adresseToolbox);
        _liquiditesEUR         = liquiditesInitiales;
        _navParPart            = NAV_INITIALE;
        _numeroCycleActuel     = 1;
        _horodatageLastCycle   = block.timestamp;

        // Attribution des roles fondateurs au deploiement
        // En production : distribuer immediatement ces roles a des adresses distinctes
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_ADMIN,         msg.sender);
        _grantRole(ROLE_GESTIONNAIRE,  msg.sender);

        // Cycle 0 = etat initial (avant toute souscription)
        // Sert de reference pour la synchronisation C-1 du premier vrai cycle (cycle 1)
        bytes32 empreinteInitiale = _calculerEmpreinteEtat(
            0, NAV_INITIALE, liquiditesInitiales, 0
        );

        _cyclesNAV[0] = CycleNAV({
            numeroCycle:           0,
            horodatage:            block.timestamp,
            navParPart:            NAV_INITIALE,
            actifNetTotal:         liquiditesInitiales,
            nombrePartsTotales:    0,
            liquiditesDisponibles: liquiditesInitiales,
            fraisCourantsCycle:    0, // [FIX-2] Pas de frais au cycle initial
            fraisPerformanceCycle: 0, // [FIX-3]
            empreinteEtat:         empreinteInitiale,
            estFinalise:           true
        });

        emit CycleNAVCloture(
            0,
            NAV_INITIALE,
            liquiditesInitiales,
            0,
            0,
            0,
            empreinteInitiale,
            block.timestamp
        );
    }

    // =========================================================================
    // GESTION DES INVESTISSEURS — REGISTRE DES ACTIONNAIRES
    // =========================================================================

    /// @notice Whiteliste un investisseur apres verification KYC/AML
    /// @param investisseur Adresse blockchain de l'investisseur
    /// @param identiteKYC Reference KYC (en production : stocker keccak256 pour RGPD)
    ///
    /// @dev En plus du registre interne du Fund, cette fonction notifie le Toolbox
    ///   via enregistrerInvestisseurQualifie() pour synchroniser les plafonds
    ///   de concentration et les dates de lock-up. [FIX-6]
    function whitelisterInvestisseur(
        address investisseur,
        string calldata identiteKYC
    )
        external
        onlyRole(ROLE_COMPLIANCE)
        whenNotPaused
    {
        // --- CHECKS ---
        require(investisseur != address(0),  "FOND: Adresse invalide");
        require(bytes(identiteKYC).length > 0, "FOND: Identite KYC vide");
        require(
            !_registreActionnaires[investisseur].estBlackliste,
            "FOND: Impossible de whitelister un investisseur blackliste"
        );

        // --- EFFECTS ---
        bool estNouvelInvestisseur = (_registreActionnaires[investisseur].datePremiereEntree == 0);

        if (estNouvelInvestisseur) {
            _registreActionnaires[investisseur] = EntreeRegistre({
                adresse:               investisseur,
                identiteKYC:           identiteKYC,
                partsDetenues:         0,
                montantInvesti:        0,
                datePremiereEntree:    block.timestamp,
                dateDerniereOperation: block.timestamp,
                estWhiteliste:         true,
                estBlackliste:         false
            });
            _listeActionnaires.push(investisseur);
        } else {
            _registreActionnaires[investisseur].estWhiteliste = true;
            _registreActionnaires[investisseur].identiteKYC  = identiteKYC;
        }

        emit InvestisseurWhiteliste(investisseur, block.timestamp);

        // [FIX-6] INTERACTIONS : synchronisation du Toolbox APRES les mises a jour d'etat
        // Le Toolbox a besoin de connaitre la date de premiere entree pour le lock-up
        // et doit initialiser le plafond individuel de souscription.
        // On utilise le plafond par defaut du Toolbox (10M EUR) ; ajustable ensuite.
        // Cet appel est SAFE car il ne modifie pas l'etat du Fund.
        // Le Toolbox ne peut pas appeler de retour (pas de callback), donc pas de reentrance.
        try _toolbox.mettreAJourMontantInvesti(investisseur, 0) {
            // Synchronisation reussie — le Toolbox connait maintenant cet investisseur
        } catch {
            // Echec non-bloquant : le whitelisting Fund reste valide.
            // Le gestionnaire devra resynchroniser manuellement le Toolbox.
            emit AlerteSecurite(
                "FOND: Synchronisation Toolbox echouee lors du whitelisting",
                investisseur,
                block.timestamp
            );
        }
    }

    /// @notice Blackliste un investisseur (gel reglementaire ou sanctions)
    /// @param investisseur Adresse de l'investisseur a bloquer
    /// @param motif Motif legal obligatoire (ex: "Gel avoirs OFAC", "Soupcon blanchiment")
    function blacklisterInvestisseur(
        address investisseur,
        string calldata motif
    )
        external
        onlyRole(ROLE_COMPLIANCE)
    {
        // --- CHECKS ---
        require(investisseur != address(0),    "FOND: Adresse invalide");
        require(bytes(motif).length > 0,       "FOND: Motif obligatoire pour blacklisting");

        // --- EFFECTS ---
        _registreActionnaires[investisseur].estBlackliste = true;
        _registreActionnaires[investisseur].estWhiteliste = false;

        emit InvestisseurBlackliste(investisseur, motif, block.timestamp);
        emit AlerteSecurite(
            string(abi.encodePacked("Blacklisting : ", motif)),
            investisseur,
            block.timestamp
        );
    }

    // =========================================================================
    // CYCLE DE VIE DES ORDRES — SOUSCRIPTIONS
    // =========================================================================

    /// @notice Capture un ordre de souscription et declenche immediatement son cycle NAV
    /// @param montantEUR Montant a souscrire en EUR (18 dec)
    /// @return idOrdre Identifiant unique de l'ordre (bytes32)
    ///
    /// @dev Architecture "1 ordre = 1 cycle NAV" :
    ///   Chaque appel a capturerOrdreSouscription declenche un cycle NAV complet
    ///   et independant. Si 10 ordres arrivent dans le meme bloc, ils sont traites
    ///   sequentiellement (le verrou _enCoursDeTraitement empeche le parallelisme).
    ///   Consequence : 10 ordres = 10 cycles NAV = 10 empreintes distinctes.
    ///
    /// @dev Pattern CEI strict :
    ///   C — Checks    : KYC, montant minimum, conformite Toolbox
    ///   E — Effects   : creation de l'ordre en memoire, emission event
    ///   I — Interactions : appel a _executerCycleNAV (interne, puis Toolbox)
    function capturerOrdreSouscription(
        uint256 montantEUR
    )
        external
        whenNotPaused
        nonReentrant
        pasEnCoursDeTraitement
        seulementInvestisseurAutorise(msg.sender)
        toolboxConfiguree
        returns (bytes32 idOrdre)
    {
        // =====================================================================
        // CHECKS
        // =====================================================================

        // Garde-fou local : double verification du minimum (Toolbox est la source
        // de verite, mais on verifie aussi ici pour un message d'erreur precis)
        require(
            montantEUR >= SOUSCRIPTION_MINIMUM,
            "FOND: Montant inferieur au minimum institutionnel (100 000 EUR)"
        );

        // Validation de conformite metier via le Toolbox (view call, sans modification d'etat)
        bool estConforme = _toolbox.validerConformite(msg.sender, montantEUR, 0);
        require(estConforme, "FOND: Souscription non conforme aux regles du Toolbox");

        // =====================================================================
        // EFFECTS — Creation et enregistrement de l'ordre
        // =====================================================================

        // Generation d'un ID d'ordre unique :
        // keccak256(investisseur + timestamp + montant + cycle + nonce + prevrandao)
        // Le nonce (longueur de la file du cycle) garantit l'unicite si plusieurs
        // ordres arrivent dans le meme bloc avec le meme montant.
        // block.prevrandao (post-Merge) apporte de l'entropie sans RANDAO manipulation.
        idOrdre = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            montantEUR,
            _numeroCycleActuel,
            _ordresParCycle[_numeroCycleActuel].length,
            block.prevrandao
        ));

        require(
            _ordres[idOrdre].horodatage == 0,
            "FOND: Collision d'ID d'ordre - Reessayez (extremement rare)"
        );

        bytes32 empreinteOrdre = keccak256(abi.encodePacked(
            idOrdre,
            msg.sender,
            montantEUR,
            _numeroCycleActuel,
            block.timestamp,
            uint8(TypeOrdre.SOUSCRIPTION)
        ));

        _ordres[idOrdre] = Ordre({
            investisseur:   msg.sender,
            montantEUR:     montantEUR,
            horodatage:     block.timestamp,
            cycleNAV:       _numeroCycleActuel,
            typeOrdre:      TypeOrdre.SOUSCRIPTION,
            statut:         StatutOrdre.EN_ATTENTE,
            empreinteOrdre: empreinteOrdre
        });

        _ordresParCycle[_numeroCycleActuel].push(idOrdre);

        emit OrdreRecu(idOrdre, msg.sender, montantEUR, _numeroCycleActuel, block.timestamp);

        // =====================================================================
        // INTERACTIONS — Declenchement du cycle NAV complet pour cet ordre
        // =====================================================================
        _executerCycleNAV(idOrdre);

        return idOrdre;
    }

    /// @notice Capture un ordre de rachat et declenche immediatement son cycle NAV
    /// @param nombreParts Nombre de parts a racheter (18 dec)
    /// @return idOrdre Identifiant unique de l'ordre
    ///
    /// @dev [FIX-5] La verification du lock-up est desormais deleguee au Toolbox.
    ///   Si l'investisseur est encore en periode de lock-up, le rachat est permis
    ///   mais des frais de penalite majores sont appliques (non-bloquant).
    ///   Les frais sont calcules par _toolbox.calculerFraisRachatComplets().
    function capturerOrdreRachat(
        uint256 nombreParts
    )
        external
        whenNotPaused
        nonReentrant
        pasEnCoursDeTraitement
        seulementInvestisseurAutorise(msg.sender)
        toolboxConfiguree
        returns (bytes32 idOrdre)
    {
        // =====================================================================
        // CHECKS
        // =====================================================================

        require(nombreParts > 0, "FOND: Nombre de parts nul");
        require(
            balanceOf(msg.sender) >= nombreParts,
            "FOND: Solde de parts insuffisant"
        );

        // [FIX-5] Verification et information sur le lock-up via le Toolbox
        // Le Toolbox connait la date de premiere entree de l'investisseur.
        // Si le lock-up n'est pas ecoule : on log un avertissement mais on autorise
        // le rachat (avec frais majores calcules dans _executerCycleNAV).
        (, uint256 secondesRestantes) = _toolbox.verifierLockup(msg.sender);
        if (secondesRestantes > 0) {
            // Rachat anticipe : avertissement non-bloquant
            // Les frais de penalite seront appliques dans _executerCycleNAV
            emit AlerteSecurite(
                "FOND: Rachat anticipe avant fin de lock-up - frais de penalite applicables",
                msg.sender,
                block.timestamp
            );
        }

        // Validation conformite Toolbox
        bool estConforme = _toolbox.validerConformite(msg.sender, nombreParts, 1);
        require(estConforme, "FOND: Rachat non conforme aux regles du Toolbox");

        // Verification de la liquidite disponible pour honorer le rachat
        // Estimation prudente : on utilise la NAV courante pour approximer le montant
        uint256 montantEstimeRachat = _toolbox.calculerMontantRachat(nombreParts, _navParPart);
        require(
            _liquiditesEUR >= montantEstimeRachat,
            "FOND: Liquidites insuffisantes pour honorer le rachat"
        );

        // =====================================================================
        // EFFECTS
        // =====================================================================

        idOrdre = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp,
            nombreParts,
            _numeroCycleActuel,
            _ordresParCycle[_numeroCycleActuel].length,
            block.prevrandao
        ));

        require(_ordres[idOrdre].horodatage == 0, "FOND: Collision d'ID d'ordre");

        bytes32 empreinteOrdre = keccak256(abi.encodePacked(
            idOrdre,
            msg.sender,
            nombreParts,
            _numeroCycleActuel,
            block.timestamp,
            uint8(TypeOrdre.RACHAT)
        ));

        _ordres[idOrdre] = Ordre({
            investisseur:   msg.sender,
            montantEUR:     nombreParts, // Pour les rachats : montantEUR contient le nombre de parts
            horodatage:     block.timestamp,
            cycleNAV:       _numeroCycleActuel,
            typeOrdre:      TypeOrdre.RACHAT,
            statut:         StatutOrdre.EN_ATTENTE,
            empreinteOrdre: empreinteOrdre
        });

        _ordresParCycle[_numeroCycleActuel].push(idOrdre);

        emit OrdreRachatRecu(idOrdre, msg.sender, nombreParts, _numeroCycleActuel, block.timestamp);

        // =====================================================================
        // INTERACTIONS
        // =====================================================================
        _executerCycleNAV(idOrdre);

        return idOrdre;
    }

    // =========================================================================
    // MOTEUR NAV — CYCLE COMPLET DE VALORISATION v2.0
    // =========================================================================

    /// @notice Orchestre un cycle NAV complet pour un ordre donne
    /// @param idOrdre Identifiant de l'ordre a traiter
    ///
    /// @dev Sequence du cycle NAV v2 :
    ///   1. Synchronisation avec C-1 (verification d'integrite du cycle precedent)
    ///   2. Calcul et prelevement des frais courants prorata     [FIX-2]
    ///   3. Calcul des frais de performance (HWM)                [FIX-3]
    ///   4. Calcul des ajustements de portefeuille (Toolbox)
    ///   5. Calcul des frais de transaction (Toolbox)
    ///   6. Calcul de la NAV nette en temps reel
    ///   7. Finalite : mint/burn des parts
    ///   8. Mise a jour du High Water Mark                       [FIX-3]
    ///   9. Synchronisation montant investi dans Toolbox          [FIX-6]
    ///  10. Cloture et archivage du cycle (empreinte immuable)
    function _executerCycleNAV(bytes32 idOrdre) internal {
        // Verrou applicatif : empeche la reentrance au niveau du cycle NAV
        _enCoursDeTraitement = true;

        Ordre storage ordre     = _ordres[idOrdre];
        uint256 numeroCycleActuel = _numeroCycleActuel;

        // =====================================================================
        // ETAPE 1 : SYNCHRONISATION AVEC C-1
        // Verification d'integrite cryptographique du cycle precedent.
        // Si l'empreinte ne correspond pas, l'etat a ete corrompu -> arret de securite.
        // =====================================================================
        CycleNAV storage cyclePrecedent = _cyclesNAV[numeroCycleActuel - 1];

        bytes32 empreinteAttendue = _calculerEmpreinteEtat(
            cyclePrecedent.numeroCycle,
            cyclePrecedent.navParPart,
            cyclePrecedent.actifNetTotal,
            cyclePrecedent.nombrePartsTotales
        );

        require(
            cyclePrecedent.empreinteEtat == empreinteAttendue,
            "FOND: Integrite du cycle C-1 compromise - Arret de securite"
        );

        // =====================================================================
        // ETAPE 2 : FRAIS COURANTS PRORATA TEMPORIS [FIX-2]
        // Calcul et deduction des frais de gestion + depositaire + admin
        // proportionnellement a la duree ecoulee depuis le dernier cycle.
        // Ces frais reduisent l'ANT et donc la NAV par part.
        // Conforme IFRS 9 : les frais courants sont une charge quotidienne du fonds.
        // =====================================================================
        uint256 dureeSecondesCycle = block.timestamp > _horodatageLastCycle
            ? block.timestamp - _horodatageLastCycle
            : 0;

        uint256 totalFraisCourants = 0;

        if (dureeSecondesCycle > 0 && _actifNetTotal > 0) {
            (
                uint256 fraisGestion,
                uint256 fraisDepositaire,
                uint256 fraisAdmin
            ) = _toolbox.calculerFraisCourantsProrata(_actifNetTotal, dureeSecondesCycle);

            totalFraisCourants = fraisGestion + fraisDepositaire + fraisAdmin;

            if (totalFraisCourants > 0 && totalFraisCourants < _actifNetTotal) {
                // Deduction des frais courants de l'ANT
                // Ces frais diminuent la NAV au benefice du gestionnaire / depositaire
                // Le prelevement reel est effectue off-chain par le depositaire
                // qui ecoute l'event FraisCourantsPreleves
                _actifNetTotal -= totalFraisCourants;
                // Note : les liquidites ne sont pas reduites ici car le prelevement
                // physique des frais est effectue par le depositaire (circuit off-chain)
            }

            emit FraisCourantsPreleves(
                numeroCycleActuel,
                fraisGestion,
                fraisDepositaire,
                fraisAdmin,
                totalFraisCourants,
                block.timestamp
            );
        }

        // =====================================================================
        // ETAPE 3 : FRAIS DE PERFORMANCE (HIGH WATER MARK) [FIX-3]
        // Calcules sur la NAV AVANT l'ordre courant pour equite envers les porteurs.
        // Les frais de perf ne sont dus que si la NAV depasse son plus haut historique
        // ET le hurdle rate accumule depuis ce plus haut.
        // =====================================================================
        uint256 navAvantOrdre     = _calculerNAVInterne();
        uint256 fraisPerformance  = _toolbox.calculerFraisPerformance(
            navAvantOrdre,
            totalSupply()
        );

        if (fraisPerformance > 0 && fraisPerformance < _actifNetTotal) {
            _actifNetTotal -= fraisPerformance;

            emit FraisPerformancePreleves(
                numeroCycleActuel,
                fraisPerformance,
                navAvantOrdre,
                block.timestamp
            );
        }

        // =====================================================================
        // ETAPE 4 : REEQUILIBRAGE DU PORTEFEUILLE (Toolbox)
        // Le Toolbox calcule les ajustements necessaires pour ramener le portefeuille
        // vers ses allocations cibles si la deviation depasse le seuil.
        // Les ajustements sont transmis au depositaire via l'event PortefeuilleReequilibre.
        // =====================================================================
        uint256 nombreActifs = _listeActifs.length;

        if (nombreActifs > 0) {
            uint256[] memory valeursActuelles = new uint256[](nombreActifs);
            uint256[] memory allocationsCibles = new uint256[](nombreActifs);

            for (uint256 i = 0; i < nombreActifs; i++) {
                Actif storage actif = _portefeuille[_listeActifs[i]];
                valeursActuelles[i]  = actif.valeurActuelle;
                allocationsCibles[i] = actif.allocationCible;
            }

            int256[] memory ajustements = _toolbox.calculerAjustementsPortefeuille(
                _actifNetTotal,
                valeursActuelles,
                allocationsCibles
            );

            emit PortefeuilleReequilibre(numeroCycleActuel, ajustements, block.timestamp);
        }

        // =====================================================================
        // ETAPE 5 : FRAIS DE TRANSACTION
        // [FIX-5] Pour les rachats : on utilise calculerFraisRachatComplets()
        // pour detecter le lock-up et appliquer la penalite si necessaire.
        // Pour les souscriptions : on utilise calculerFrais() standard.
        // =====================================================================
        uint256 fraisTransaction = 0;
        bool    estRachatAnticipe = false;

        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            fraisTransaction = _toolbox.calculerFrais(ordre.montantEUR, 0);
        } else {
            // [FIX-5] Calcul du montant brut equivalent en EUR pour calculer les frais
            uint256 montantBrutPourFrais = _toolbox.calculerMontantRachat(
                ordre.montantEUR, // Pour rachat, montantEUR = nombre de parts
                _navParPart
            );
            (fraisTransaction, estRachatAnticipe) = _toolbox.calculerFraisRachatComplets(
                montantBrutPourFrais,
                ordre.investisseur
            );

            // Emission d'un event specifique si rachat anticipe detecte
            if (estRachatAnticipe) {
                (, uint256 secondesRestantes) = _toolbox.verifierLockup(ordre.investisseur);
                emit RachatAnticiipeDetecte(
                    idOrdre,
                    ordre.investisseur,
                    secondesRestantes,
                    fraisTransaction,
                    block.timestamp
                );
            }
        }

        // Calcul du montant net apres deduction des frais de transaction
        uint256 montantNet = ordre.montantEUR;
        if (fraisTransaction > 0 && fraisTransaction < montantNet) {
            montantNet = montantNet - fraisTransaction;
        }

        // =====================================================================
        // ETAPE 6 : CALCUL DE LA NAV EN TEMPS REEL
        // Apres deduction des frais courants et de performance de l'ANT.
        // La NAV integre maintenant toutes les charges du cycle.
        // =====================================================================
        uint256 nouvelleNAV = _calculerNAVInterne();

        // =====================================================================
        // ETAPES 7 : FINALITE — MINT/BURN SIMULTANE
        // Les parts sont emises ou brulees contre les mouvements d'actifs.
        // C'est la transaction on-chain definitive et irreversible.
        // =====================================================================
        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            _executerSouscription(idOrdre, montantNet, nouvelleNAV, fraisTransaction);
        } else {
            _executerRachat(idOrdre, montantNet, nouvelleNAV, fraisTransaction, estRachatAnticipe);
        }

        // =====================================================================
        // ETAPE 8 : MISE A JOUR DU HIGH WATER MARK [FIX-3]
        // Apres finalite, la nouvelle NAV est communiquee au Toolbox.
        // Si elle constitue un nouveau sommet, le HWM est mis a jour.
        // Appel externe APRES toutes les mutations d'etat internes (pattern CEI).
        // =====================================================================
        uint256 navFinale = _calculerNAVInterne();
        try _toolbox.mettreAJourHighWaterMark(navFinale, numeroCycleActuel) {
            // HWM synchronise avec succes
        } catch {
            // Echec non-bloquant : les frais de perf du prochain cycle pourront
            // etre legerement imprecis mais le fonds reste operationnel.
            emit AlerteSecurite(
                "FOND: Mise a jour HWM Toolbox echouee - synchronisation manuelle requise",
                msg.sender,
                block.timestamp
            );
        }

        // =====================================================================
        // ETAPE 9 : SYNCHRONISATION MONTANT INVESTI [FIX-6]
        // Pour les souscriptions uniquement : on informe le Toolbox du montant
        // additionnel investi afin de maintenir les plafonds de concentration.
        // =====================================================================
        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            try _toolbox.mettreAJourMontantInvesti(ordre.investisseur, montantNet) {
                // Synchronisation reussie
            } catch {
                emit AlerteSecurite(
                    "FOND: Synchronisation montant investi Toolbox echouee",
                    ordre.investisseur,
                    block.timestamp
                );
            }
        }

        // =====================================================================
        // ETAPE 10 : CLOTURE DU CYCLE — ARCHIVAGE IMMUABLE
        // L'empreinte cryptographique capture l'etat complet du cycle.
        // Toute tentative de modification posterieure sera detectee par
        // la fonction verifierIntegriteCycle().
        // =====================================================================
        bytes32 empreinteEtat = _calculerEmpreinteEtat(
            numeroCycleActuel,
            navFinale,
            _actifNetTotal,
            totalSupply()
        );

        _cyclesNAV[numeroCycleActuel] = CycleNAV({
            numeroCycle:           numeroCycleActuel,
            horodatage:            block.timestamp,
            navParPart:            navFinale,
            actifNetTotal:         _actifNetTotal,
            nombrePartsTotales:    totalSupply(),
            liquiditesDisponibles: _liquiditesEUR,
            fraisCourantsCycle:    totalFraisCourants,  // [FIX-2]
            fraisPerformanceCycle: fraisPerformance,     // [FIX-3]
            empreinteEtat:         empreinteEtat,
            estFinalise:           true
        });

        emit CycleNAVCloture(
            numeroCycleActuel,
            navFinale,
            _actifNetTotal,
            totalSupply(),
            totalFraisCourants,
            fraisPerformance,
            empreinteEtat,
            block.timestamp
        );

        _numeroCycleActuel++;
        _horodatageLastCycle  = block.timestamp;
        _enCoursDeTraitement  = false;
    }

    // =========================================================================
    // PHASE DE FINALITE — SOUSCRIPTION (MINT)
    // =========================================================================

    /// @notice Execute la phase de finalite pour une souscription : mint des parts
    /// @param idOrdre ID de l'ordre
    /// @param montantNet Montant net apres frais de transaction en EUR (18 dec)
    /// @param navParPart NAV par part du cycle courant (18 dec)
    /// @param frais Frais de transaction preleves (18 dec)
    ///
    /// @dev [FIX-4] Le calcul du nombre de parts est desormais delegue au Toolbox
    ///   via calculerPartsAEmettre(). Cela garantit la coherence avec les calculs
    ///   du Toolbox (meme implementation de Math.mulDiv, meme arrondi vers le bas).
    function _executerSouscription(
        bytes32 idOrdre,
        uint256 montantNet,
        uint256 navParPart,
        uint256 frais
    ) internal {
        Ordre storage ordre = _ordres[idOrdre];

        require(navParPart > 0, "FOND: NAV nulle - Impossible de calculer les parts");

        // [FIX-4] Delegation du calcul au Toolbox pour coherence Math.mulDiv
        // parts = (montantNet * PRECISION) / navParPart — arrondi vers le bas
        uint256 partsAEmettre = _toolbox.calculerPartsAEmettre(montantNet, navParPart);
        require(partsAEmettre > 0, "FOND: Montant trop faible pour emettre une part entiere");

        // --- EFFECTS : mises a jour d'etat AVANT le mint (pattern CEI) ---
        ordre.statut = StatutOrdre.EXECUTE;

        EntreeRegistre storage entree = _registreActionnaires[ordre.investisseur];
        uint256 ancienSolde = entree.partsDetenues;

        entree.partsDetenues         += partsAEmettre;
        entree.montantInvesti        += montantNet;
        entree.dateDerniereOperation  = block.timestamp;

        _liquiditesEUR  += montantNet;
        _actifNetTotal  += montantNet;
        _navParPart      = navParPart;

        // --- INTERACTIONS : mint ERC20 en DERNIER ---
        _mint(ordre.investisseur, partsAEmettre);

        emit RegistreActionnairesModifie(
            ordre.investisseur,
            ancienSolde,
            entree.partsDetenues,
            "SOUSCRIPTION",
            block.timestamp
        );

        emit SouscriptionExecutee(
            idOrdre,
            ordre.investisseur,
            montantNet,
            partsAEmettre,
            navParPart,
            frais,
            _numeroCycleActuel
        );
    }

    // =========================================================================
    // PHASE DE FINALITE — RACHAT (BURN)
    // =========================================================================

    /// @notice Execute la phase de finalite pour un rachat : burn des parts
    /// @param idOrdre ID de l'ordre
    /// @param nombreParts Nombre de parts a racheter (apres deduction eventuelle)
    /// @param navParPart NAV par part du cycle courant
    /// @param frais Frais de transaction (standard ou anticipes)
    /// @param estAnticipe True si rachat avant fin de lock-up
    ///
    /// @dev [FIX-4] Le calcul du montant brut est delegue au Toolbox via calculerMontantRachat().
    ///   [FIX-5] La distinction rachat standard / anticipe est tracee dans l'event.
    function _executerRachat(
        bytes32 idOrdre,
        uint256 nombreParts,
        uint256 navParPart,
        uint256 frais,
        bool    estAnticipe
    ) internal {
        Ordre storage ordre = _ordres[idOrdre];

        // [FIX-4] Delegation du calcul au Toolbox
        // montantBrut = (nombreParts * navParPart) / PRECISION
        uint256 montantBrut = _toolbox.calculerMontantRachat(nombreParts, navParPart);
        uint256 montantNet  = montantBrut > frais ? montantBrut - frais : 0;

        require(montantNet > 0,                     "FOND: Montant net du rachat nul apres frais");
        require(_liquiditesEUR >= montantNet,        "FOND: Liquidites insuffisantes pour le rachat");

        // --- EFFECTS ---
        ordre.statut = StatutOrdre.EXECUTE;

        EntreeRegistre storage entree = _registreActionnaires[ordre.investisseur];
        uint256 ancienSolde = entree.partsDetenues;

        entree.partsDetenues         -= nombreParts;
        entree.dateDerniereOperation  = block.timestamp;

        _liquiditesEUR  -= montantNet;
        _actifNetTotal   = _actifNetTotal >= montantNet ? _actifNetTotal - montantNet : 0;
        _navParPart       = navParPart;

        // --- INTERACTIONS : burn ERC20 EN DERNIER ---
        // Le burn est definitif et irreversible. Le virement EUR correspondant
        // est effectue off-chain par le depositaire qui ecoute l'event RachatExecute.
        _burn(ordre.investisseur, nombreParts);

        emit RegistreActionnairesModifie(
            ordre.investisseur,
            ancienSolde,
            entree.partsDetenues,
            estAnticipe ? "RACHAT_ANTICIPE" : "RACHAT",
            block.timestamp
        );

        emit RachatExecute(
            idOrdre,
            ordre.investisseur,
            nombreParts,
            montantNet,
            navParPart,
            frais,
            estAnticipe, // [FIX-5] Nouveau champ dans l'event
            _numeroCycleActuel
        );
    }

    // =========================================================================
    // CALCUL DE LA NAV INTERNE
    // =========================================================================

    /// @notice Calcule la NAV par part en aggreant tous les actifs et liquidites
    /// @return nav NAV par part en EUR (18 dec)
    ///
    /// @dev Formule fondamentale des OPC (UCITS/AIFMD) :
    ///   NAV = (Liquidites + Somme(valeurs actifs actifs)) / Parts en circulation
    ///
    ///   Note : cette fonction est appelee en milieu de cycle NAV (avant mint/burn)
    ///   et en fin de cycle (apres mint/burn) pour obtenir la NAV finale.
    ///   Les frais courants et de performance ont deja ete deduits de _actifNetTotal
    ///   avant cet appel.
    function _calculerNAVInterne() internal view returns (uint256 nav) {
        uint256 valeurTotale = _liquiditesEUR;

        for (uint256 i = 0; i < _listeActifs.length; i++) {
            Actif storage actif = _portefeuille[_listeActifs[i]];
            if (actif.estActif) {
                valeurTotale += actif.valeurActuelle;
            }
        }

        uint256 partsEnCirculation = totalSupply();

        if (partsEnCirculation == 0) {
            // Aucune part en circulation : la NAV est egale a la valeur initiale par convention
            return NAV_INITIALE;
        }

        // NAV = valeurTotale * PRECISION / partsEnCirculation
        // On utilise mulDiv pour eviter l'overflow : (1e30 * 1e18) avant division
        return valeurTotale.mulDiv(PRECISION, partsEnCirculation);
    }

    /// @notice Calcule et retourne la NAV actuelle (acces public en lecture)
    function calculerNAV() external view returns (uint256) {
        return _calculerNAVInterne();
    }

    // =========================================================================
    // GESTION DU PORTEFEUILLE
    // =========================================================================

    /// @notice Ajoute un actif au portefeuille du fonds
    /// @param identifiant ISIN ou identifiant interne (bytes32)
    /// @param description Description lisible de l'actif
    /// @param typeActif Type d'instrument (BILLET_TRESORERIE, OBLIGATION, etc.)
    /// @param valeurInitiale Valeur d'entree en EUR (18 dec)
    /// @param allocationCible Allocation cible en bp (ex: 2000 = 20%)
    function ajouterActif(
        bytes32 identifiant,
        string calldata description,
        TypeActif typeActif,
        uint256 valeurInitiale,
        uint256 allocationCible
    )
        external
        onlyRole(ROLE_GESTIONNAIRE)
        whenNotPaused
        nonReentrant
    {
        // --- CHECKS ---
        require(identifiant != bytes32(0),          "FOND: Identifiant d'actif vide");
        require(bytes(description).length > 0,      "FOND: Description vide");
        require(!_portefeuille[identifiant].estActif, "FOND: Actif deja present dans le portefeuille");
        require(_listeActifs.length < 50,           "FOND: Portefeuille plein (max 50 actifs)");

        // Verification que les allocations cibles totales ne depassent pas 100%
        uint256 totalAllocations = allocationCible;
        for (uint256 i = 0; i < _listeActifs.length; i++) {
            if (_portefeuille[_listeActifs[i]].estActif) {
                totalAllocations += _portefeuille[_listeActifs[i]].allocationCible;
            }
        }
        require(totalAllocations <= BASE_POINTS, "FOND: Allocations cibles depassent 100%");

        // --- EFFECTS ---
        _portefeuille[identifiant] = Actif({
            identifiant:       identifiant,
            description:       description,
            valeurActuelle:    valeurInitiale,
            allocationCible:   allocationCible,
            typeActif:         typeActif,
            derniereMiseAJour: block.timestamp,
            estActif:          true
        });

        _listeActifs.push(identifiant);
        _actifNetTotal += valeurInitiale;

        emit ActifAjoute(identifiant, description, typeActif, valeurInitiale, allocationCible);
    }

    /// @notice Met a jour la valorisation d'un actif (soumise par le valorisateur agree)
    /// @param identifiant Identifiant de l'actif
    /// @param nouvelleValeur Nouvelle valeur en EUR (18 dec)
    ///
    /// @dev Circuit breaker : si la variation depasse +/-20% en une seule mise a jour,
    ///   la transaction est revertee pour validation manuelle.
    ///   Ce seuil correspond a la limite d'un circuit breaker standard de marche.
    function mettreAJourValeurActif(
        bytes32 identifiant,
        uint256 nouvelleValeur
    )
        external
        onlyRole(ROLE_VALORISATEUR)
        whenNotPaused
    {
        // --- CHECKS ---
        require(_portefeuille[identifiant].estActif, "FOND: Actif inconnu ou inactif");

        Actif storage actif = _portefeuille[identifiant];

        // Circuit breaker : variation max de +/-20% par mise a jour
        if (actif.valeurActuelle > 0) {
            uint256 variation;
            if (nouvelleValeur > actif.valeurActuelle) {
                variation = ((nouvelleValeur - actif.valeurActuelle) * BASE_POINTS)
                          / actif.valeurActuelle;
            } else {
                variation = ((actif.valeurActuelle - nouvelleValeur) * BASE_POINTS)
                          / actif.valeurActuelle;
            }
            require(
                variation <= 2_000,
                "FOND: Variation de prix > 20% - Verification manuelle du valorisateur requise"
            );
        }

        // --- EFFECTS ---
        uint256 ancienneValeur = actif.valeurActuelle;
        int256  deltaValeur    = int256(nouvelleValeur) - int256(ancienneValeur);

        actif.valeurActuelle    = nouvelleValeur;
        actif.derniereMiseAJour = block.timestamp;

        // Mise a jour de l'ANT en fonction du delta de valorisation
        if (deltaValeur > 0) {
            _actifNetTotal += uint256(deltaValeur);
        } else if (deltaValeur < 0) {
            uint256 diminution = uint256(-deltaValeur);
            _actifNetTotal = _actifNetTotal > diminution ? _actifNetTotal - diminution : 0;
        }

        emit ActifValoriseMAJ(
            identifiant,
            ancienneValeur,
            nouvelleValeur,
            block.timestamp,
            msg.sender
        );

        emit NAVMiseAJour(
            _navParPart,
            _calculerNAVInterne(),
            _actifNetTotal,
            block.timestamp,
            msg.sender
        );
    }

    // =========================================================================
    // GESTION DES LIQUIDITES
    // =========================================================================

    /// @notice Enregistre un apport de liquidites confirme par le depositaire
    /// @param montantEUR Montant recu en EUR (18 dec)
    /// @param motif Description du mouvement (ex: "Reglement souscription")
    function enregistrerApportLiquidites(
        uint256 montantEUR,
        string calldata motif
    )
        external
        onlyRole(ROLE_DEPOSITAIRE)
        whenNotPaused
    {
        require(montantEUR > 0, "FOND: Montant nul");

        uint256 ancienMontant = _liquiditesEUR;
        _liquiditesEUR    += montantEUR;
        _actifNetTotal    += montantEUR;

        emit LiquiditesMiseAJour(ancienMontant, _liquiditesEUR, motif, block.timestamp);
    }

    /// @notice Enregistre un prelevement de liquidites confirme par le depositaire
    /// @param montantEUR Montant preleve en EUR (18 dec)
    /// @param motif Description du mouvement (ex: "Reglement rachat", "Achat actif")
    function enregistrerPrelevementLiquidites(
        uint256 montantEUR,
        string calldata motif
    )
        external
        onlyRole(ROLE_DEPOSITAIRE)
        whenNotPaused
    {
        require(montantEUR > 0, "FOND: Montant nul");
        require(_liquiditesEUR >= montantEUR, "FOND: Liquidites insuffisantes");

        uint256 ancienMontant = _liquiditesEUR;
        _liquiditesEUR    -= montantEUR;
        _actifNetTotal     = _actifNetTotal >= montantEUR ? _actifNetTotal - montantEUR : 0;

        emit LiquiditesMiseAJour(ancienMontant, _liquiditesEUR, motif, block.timestamp);
    }

    // =========================================================================
    // ADMINISTRATION DU CONTRAT
    // =========================================================================

    /// @notice Met a jour l'adresse du contrat Toolbox
    /// @param nouvelleAdresseToolbox Nouvelle adresse du Toolbox deploye
    /// @dev Operation critique : necessite ROLE_ADMIN.
    ///   Apres cette operation, le nouveau Toolbox doit avoir accorde ROLE_FOND_AUTORISE
    ///   a l'adresse de ce contrat Fund, sinon les cycles NAV echoueront.
    function mettreAJourToolbox(address nouvelleAdresseToolbox)
        external
        onlyRole(ROLE_ADMIN)
    {
        require(nouvelleAdresseToolbox != address(0),      "FOND: Adresse Toolbox invalide");
        require(
            nouvelleAdresseToolbox != address(_toolbox),
            "FOND: Adresse identique a l'actuelle"
        );

        address ancienneAdresse = address(_toolbox);
        _toolbox = IToolbox(nouvelleAdresseToolbox);

        emit ToolboxMiseAJour(ancienneAdresse, nouvelleAdresseToolbox, block.timestamp);
    }

    /// @notice Pause le contrat (circuit breaker reglementaire)
    function pauserContrat() external onlyRole(ROLE_ADMIN) {
        _pause();
        emit AlerteSecurite("Contrat pause par administrateur", msg.sender, block.timestamp);
    }

    /// @notice Reprend le contrat apres une pause
    function reprendreContrat() external onlyRole(ROLE_ADMIN) {
        _unpause();
    }

    // =========================================================================
    // FONCTIONS DE LECTURE (VIEW) — AUDITABILITE
    // =========================================================================

    /// @notice Retourne le detail complet d'un cycle NAV archive
    function lireCycleNAV(uint256 numeroCycle) external view returns (CycleNAV memory) {
        return _cyclesNAV[numeroCycle];
    }

    /// @notice Retourne les informations d'un ordre
    function lireOrdre(bytes32 idOrdre) external view returns (Ordre memory) {
        return _ordres[idOrdre];
    }

    /// @notice Retourne l'entree du registre des actionnaires (acces auditeur uniquement)
    function lireEntreeRegistre(address investisseur)
        external
        view
        onlyRole(ROLE_AUDITEUR)
        returns (EntreeRegistre memory)
    {
        return _registreActionnaires[investisseur];
    }

    /// @notice Retourne les informations d'un actif du portefeuille
    function lireActif(bytes32 identifiant) external view returns (Actif memory) {
        return _portefeuille[identifiant];
    }

    /// @notice Retourne les metriques globales du fonds
    function lireMesusFonds()
        external
        view
        returns (
            uint256 navParPart,
            uint256 actifNetTotal,
            uint256 liquiditesEUR,
            uint256 nombrePartsTotales,
            uint256 numeroCycleActuel,
            uint256 nombreActifs,
            uint256 nombreActionnaires
        )
    {
        return (
            _calculerNAVInterne(),
            _actifNetTotal,
            _liquiditesEUR,
            totalSupply(),
            _numeroCycleActuel,
            _listeActifs.length,
            _listeActionnaires.length
        );
    }

    /// @notice Retourne le code ISIN du fonds
    function isinFonds() external view returns (string memory) {
        return _isinFonds;
    }

    /// @notice Retourne le numero du cycle NAV courant
    function numeroCycleActuel() external view returns (uint256) {
        return _numeroCycleActuel;
    }

    /// @notice Verifie l'integrite cryptographique d'un cycle NAV archive
    /// @dev Permet a un auditeur de detecter toute alteration posterieure a la cloture.
    ///   Si integrite = false, le cycle a ete altere : alerte de securite critique.
    function verifierIntegriteCycle(uint256 numeroCycle)
        external
        view
        returns (
            bool integrite,
            bytes32 empreinteCalculee,
            bytes32 empreinteStockee
        )
    {
        CycleNAV storage cycle = _cyclesNAV[numeroCycle];
        empreinteCalculee = _calculerEmpreinteEtat(
            cycle.numeroCycle,
            cycle.navParPart,
            cycle.actifNetTotal,
            cycle.nombrePartsTotales
        );
        empreinteStockee = cycle.empreinteEtat;
        integrite = (empreinteCalculee == empreinteStockee);
    }

    // =========================================================================
    // FONCTIONS INTERNES UTILITAIRES
    // =========================================================================

    /// @notice Calcule l'empreinte cryptographique d'un etat NAV
    /// @dev keccak256 : resiste aux collisions, irreversible, standard Ethereum.
    ///   L'inclusion de address(this) empeche la portabilite de l'empreinte
    ///   vers un autre contrat Fund qui aurait les memes parametres numeriques.
    function _calculerEmpreinteEtat(
        uint256 numeroCycle,
        uint256 navParPart,
        uint256 actifNetTotal,
        uint256 nombreParts
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            numeroCycle,
            navParPart,
            actifNetTotal,
            nombreParts,
            block.timestamp,
            address(this)
        ));
    }

    // =========================================================================
    // OVERRIDES REQUIS PAR SOLIDITY (resolution des conflits d'heritage)
    // =========================================================================

    /// @dev Resolution du conflit ERC20 / ERC20Pausable sur _update().
    ///   Ajoute une verification de blacklisting sur les transferts secondaires
    ///   (hors mint/burn). Les mints ont from = address(0), les burns to = address(0).
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        if (from != address(0) && to != address(0)) {
            require(
                !_registreActionnaires[from].estBlackliste,
                "FOND: Emetteur blackliste - Transfert bloque"
            );
            require(
                !_registreActionnaires[to].estBlackliste,
                "FOND: Destinataire blackliste - Transfert bloque"
            );
        }
        super._update(from, to, value);
    }

    /// @dev [FIX-9] Correction : l'override supportsInterface ne doit pas inclure
    ///   ERC20 car ERC20 n'implemente pas supportsInterface (pas d'ERC165).
    ///   Seul AccessControl herite d'ERC165 et implemente supportsInterface.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl) // [FIX-9] : etait override(ERC20, AccessControl) — erreur de compilation
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /// @dev 18 decimales : precision maximale pour les calculs financiers en EUR.
    ///   Permet une granularite de 0.000000000000000001 part (1 attoPart).
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
