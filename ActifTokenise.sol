// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
//
//  Smart Contract ACTIF TOKENISE — v1.0.0
//  Registre immuable et tamper-proof des actions / parts tokenisees
//
//  Role dans l'architecture :
//    FondTokenise (contrat central)  ──────────────────────────────────┐
//        │                                                              │
//        ├── appelle ──► Toolbox (calculs financiers)                  │
//        │                                                              │
//        └── emet / brule ──► ActifTokenise (ce contrat) ◄────────────┘
//                                   │
//                                   └── agrege dans ──► ActifTokeniseHolding
//
//  Responsabilites de ce contrat :
//    1. Tenir le registre canonique des actions / parts tokenisees (ERC-1400)
//    2. Enregistrer chaque emission, transfert et rachat de maniere immuable
//    3. Associer chaque token a ses metadonnees reglementaires (ISIN, emetteur,
//       restrictions de transfert, droits attaches)
//    4. Implementer les restrictions de transfert conformes a la Directive Prospectus
//       et aux regles AMF sur les titres financiers numeriques (Art. L211-3 CMF)
//    5. Fournir un registre d'actionnaires certifie et auditabler
//    6. Calculer et distribuer les dividendes / coupons en EUR
//    7. Exposer les donnees de valorisation au FondTokenise via l'interface IActifTokenise
//
//  Conformite reglementaire :
//    - AMF (Art. L211-3 CMF) : titres financiers emis sous forme numerique
//    - DLT Pilot Regime (Reglement UE 2022/858) : infrastructure DLT pour titres
//    - MiFID II : registre de transactions et reporting
//    - EMIR : reporting des transactions sur titres
//    - Directive Prospectus (2017/1129/UE) : restrictions d'offre au public
//    - RGPD : hachage des identites KYC
//
//  Standard de token choisi : ERC-1400 (Security Token Standard)
//    Pourquoi ERC-1400 plutot qu'ERC-20 simple ?
//    ERC-1400 est le standard de facto pour les titres financiers tokenises :
//    - Partitions : chaque categorie de titre (action A, action B, preference) est
//      une partition distincte, comme les tranches d'un fonds structuré
//    - Restrictions de transfert : transferCanCheck() et canTransfer() permettent
//      d'implementer les regles reglementaires sans modifier le standard
//    - Documents on-chain : rattache les prospectus, statuts, et actes juridiques
//    - Operateurs autorises : concept de "controlled transfer" pour le depositaire
//    Note : On reimplemente les principes ERC-1400 en Solidity pur plutot qu'importer
//    une bibliotheque tierce non auditee. Cela donne un controle total sur le code.
//
//  Precision : 18 decimales (standard ERC20-compatible, fractions d'actions possibles)
// =============================================================================

// =============================================================================
// IMPORTS DES BIBLIOTHEQUES
// =============================================================================

import "@openzeppelin/contracts/access/AccessControl.sol";
// AccessControl : RBAC a granularite fine. Indispensable pour separer :
//   - l'emetteur (droit de creer des tokens)
//   - le registraire (droit de modifier le registre)
//   - l'agent de transfert (droit de forcer des transferts reglementaires)
//   - le compliance officer (droit de geler / debloquer)
//   - l'auditeur (lecture seule des donnees sensibles)

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// ReentrancyGuard : protection contre les attaques de re-entrance.
// Les fonctions d'emission et de rachat de tokens manipulent des soldes :
// toute re-entrance pourrait creer des tokens sans contrepartie.

import "@openzeppelin/contracts/utils/Pausable.sol";
// Pausable : suspension d'urgence des transferts.
// Requis par le DLT Pilot Regime (Art. 8.4) : l'operateur doit pouvoir
// suspendre les operations sur instruction du regulateur (AMF / BCE).

import "@openzeppelin/contracts/utils/math/Math.sol";
// Math.mulDiv : arithmetique sans overflow pour les calculs financiers.
// Identique a FondTokenise et Toolbox pour la coherence de precision.

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
// SafeCast : conversions int/uint securisees.
// Utilise pour les calculs de dividendes et de valorisation signes.

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
// ECDSA : verification de signatures cryptographiques Ethereum.
// Utilise pour authentifier les autorisations de transfert hors-chaine
// (ex : le depositaire signe une autorisation off-chain, validee on-chain).

import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
// MessageHashUtils : construit les hashs de messages conformes EIP-191 / EIP-712.
// Necessite pour valider les signatures ECDSA des autorisations de transfert.

import "@openzeppelin/contracts/utils/Strings.sol";
// Strings : conversion uint256 -> string pour la generation des URI de documents.

// =============================================================================
// INTERFACES DES CONTRATS DEPENDANTS
// =============================================================================

/// @notice Interface minimale de FondTokenise pour la synchronisation de valorisation
/// Pourquoi minimal ? On n'expose que ce dont ActifTokenise a besoin.
/// Principe de surface de confiance minimale (minimal trust surface).
interface IFondTokenise {
    /// @notice Retourne la NAV actuelle du fonds (EUR, 18 dec)
    function calculerNAV() external view returns (uint256);

    /// @notice Retourne les metriques globales du fonds
    function lireMesusFonds() external view returns (
        uint256 navParPart,
        uint256 actifNetTotal,
        uint256 liquiditesEUR,
        uint256 nombrePartsTotales,
        uint256 numeroCycleActuel,
        uint256 nombreActifs,
        uint256 nombreActionnaires
    );
}

/// @notice Interface du Toolbox pour les calculs de valorisation des actifs tokenises
/// On reutilise calculerDepreciationLineaire et calculerInteretsSimples
/// qui sont des fonctions pure (gratuites en gas, disponibles sans autorisation).
interface IToolboxActif {
    /// @notice Calcule la depreciation lineaire d'un billet de tresorerie
    function calculerDepreciationLineaire(
        uint256 valeurNominale,
        uint256 tauxAnnuel,
        uint256 dureeJours,
        uint256 joursEcoules
    ) external pure returns (uint256 valeurActuelle);

    /// @notice Calcule les interets simples ACT/365
    function calculerInteretsSimples(
        uint256 principal,
        uint256 tauxAnnuelBp,
        uint256 nombreJours
    ) external pure returns (uint256 montantFinal, uint256 interets);

    /// @notice Calcule le taux de rendement actuariel annualise
    function calculerTauxRendement(
        uint256 prixAchat,
        uint256 valeurRemboursement,
        uint256 dureeJours
    ) external pure returns (uint256 tauxRendementBp);
}

// =============================================================================
// SMART CONTRACT ACTIF TOKENISE
// =============================================================================

contract ActifTokenise is AccessControl, ReentrancyGuard, Pausable {

    // =========================================================================
    // UTILISATIONS DES BIBLIOTHEQUES
    // =========================================================================
    using Math       for uint256;
    using SafeCast   for uint256;
    using SafeCast   for int256;
    using ECDSA      for bytes32;
    using Strings    for uint256;

    // =========================================================================
    // ROLES (RBAC)
    // =========================================================================
    // Architecture des roles conforme aux exigences du DLT Pilot Regime
    // (Reglement UE 2022/858, Art. 7) sur la gouvernance des systemes DLT
    // utilises pour le reglement-livraison de titres financiers.

    /// @dev Emetteur : peut emettre (mint) de nouveaux tokens de titres
    /// Correspond au role de "depositaire central de titres" (CSD) dans la terminologie
    /// du Reglement UE 909/2014 sur les depositaires centraux (CSDR).
    bytes32 public constant ROLE_EMETTEUR = keccak256("EMETTEUR");

    /// @dev Registraire : gere le registre des detenteurs et les metadonnees
    /// En pratique : la banque teneuse de registre (ex: CACEIS, SGSS, BNP Securities).
    bytes32 public constant ROLE_REGISTRAIRE = keccak256("REGISTRAIRE");

    /// @dev Agent de transfert : peut forcer des transferts (ex: succession, gel judiciaire)
    /// Necessite une double autorisation (agent + compliance) pour les transferts forces.
    bytes32 public constant ROLE_AGENT_TRANSFERT = keccak256("AGENT_TRANSFERT");

    /// @dev Compliance officer : gele/debloques les adresses, valide les restrictions
    bytes32 public constant ROLE_COMPLIANCE = keccak256("COMPLIANCE");

    /// @dev Operateur de dividendes : autorise a declencher les distributions
    /// Separe du registraire pour respecter la separation des fonctions.
    bytes32 public constant ROLE_OPERATEUR_DIVIDENDES = keccak256("OPERATEUR_DIVIDENDES");

    /// @dev Valorisateur : soumet les prix de marche pour la valorisation
    bytes32 public constant ROLE_VALORISATEUR = keccak256("VALORISATEUR");

    /// @dev Auditeur : acces en lecture seule au registre complet
    bytes32 public constant ROLE_AUDITEUR = keccak256("AUDITEUR");

    /// @dev Administrateur : gestion des roles et parametres critiques
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    /// @dev Fonds autorise : FondTokenise peut declencher des operations sur cet actif
    /// Ce role est accorde a l'adresse du contrat FondTokenise lors du deploiement.
    bytes32 public constant ROLE_FOND_AUTORISE = keccak256("FOND_AUTORISE");

    // =========================================================================
    // CONSTANTES
    // =========================================================================

    /// @notice Precision virgule fixe : 18 decimales (standard ERC20, compatible EUR)
    uint256 public constant PRECISION = 1e18;

    /// @notice Points de base : 10 000 bp = 100%
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice Jours par an — Convention ACT/365 (Euro Money Market, coherent avec Toolbox)
    uint256 public constant JOURS_PAR_AN = 365;

    /// @notice Secondes par an — ACT/365
    uint256 public constant SECONDES_PAR_AN = 365 days;

    /// @notice Nombre maximum de detenteurs enregistres (limite pour l'iteration on-chain)
    /// Au-dela, les operations d'audit iteratif devront etre effectuees off-chain.
    uint256 public constant MAX_DETENTEURS = 500;

    /// @notice Delai minimum entre deux distributions de dividendes (protection anti-spam)
    /// 30 jours = standard de distribution pour les OPC (Art. 411-136 RGAMF)
    uint256 public constant DELAI_MIN_DISTRIBUTION = 30 days;

    // =========================================================================
    // STRUCTURES DE DONNEES
    // =========================================================================

    // -------------------------------------------------------------------------
    // METADONNEES REGLEMENTAIRES DU TITRE
    // -------------------------------------------------------------------------
    // Chaque actif tokenise doit etre associe a un ensemble de metadonnees
    // reglementaires permettant son identification unique et sa categorisation.
    // Ces informations sont necessaires pour la declaration MiFID II (Art. 26)
    // et le reporting EMIR.

    /// @notice Metadonnees reglementaires du titre tokenise
    struct MetadonneesTitre {
        // --- Identification ---
        string isin;                 // Code ISIN (12 car., ex: "FR0000131104" pour BNP)
        string cfi;                  // Classification CFI (6 car., ex: "ESVUFR" pour action ordinaire)
        string denominationLegale;   // Denomination legale complete de l'emetteur
        string symbole;              // Symbole de cotation (ex: "BNP", "CA", "SAN")

        // --- Classification ---
        TypeTitre typeTitre;         // Action, obligation, part de fonds, etc.
        ClasseAction classeAction;   // Ordinaire, preference, fondateur, etc.

        // --- Valeur ---
        uint256 valeurNominaleParPart;  // Valeur nominale par titre (EUR, 18 dec)
                                         // Pour les actions : valeur inscrite aux statuts
                                         // Pour les obligations : montant de remboursement

        // --- Droits attaches ---
        uint256 droitVoteParPart;    // Nb de voix par titre (ex: 2 pour actions double droit)
        bool aDroitDividende;        // True si ce titre donne droit au dividende
        bool aDroitVote;             // True si ce titre donne droit de vote

        // --- Restrictions ---
        bool transfertRestreint;     // True si les transferts necessitent une approbation
        bool offrePubliqueExclue;    // True si reserve aux investisseurs qualifies (Prosp. 2017/1129)
        uint256 periodeIncessibilite; // Duree d'incessibilite en secondes (ex: 365 days pour BSPCE)

        // --- Dates ---
        uint256 dateEmission;        // Timestamp de la premiere emission
        uint256 dateMaturite;        // Timestamp de maturite (0 = pas de maturite, pour actions)

        // --- Juridiction ---
        string juridiction;          // Droit applicable (ex: "FR", "LU", "IE")
        string adresseRegistre;      // URI du registre legale off-chain (IPFS ou URL)
    }

    // -------------------------------------------------------------------------
    // REGISTRE DES DETENTEURS
    // -------------------------------------------------------------------------
    // Tenu par le registraire, ce registre est la source de verite juridique
    // sur la propriete des titres tokenises.
    // Conformite : Art. L228-1 Code de Commerce (registre des actionnaires)

    /// @notice Entree du registre des detenteurs de titres
    struct EntreeDetenteur {
        address adresse;              // Adresse blockchain du detenteur
        uint256 solde;                // Solde de tokens (18 dec)
        uint256 soldeBloque;          // Solde immobilise (gel reglementaire, nantissement)
        uint256 datePremiereAcquisition; // Timestamp premiere acquisition
        uint256 dateDerniereOperation;   // Timestamp derniere operation
        string  referenceKYC;         // Hash de la reference KYC (RGPD : pas d'identite claire)
        bool    estDetenteurAutorise; // True si KYC valide et autorise a detenir
        bool    estGele;              // True si le compte est gele (sanctions, contentieux)
        uint256 dividendesAccumules;  // Dividendes non encore reclames (EUR, 18 dec)
        uint256 nonce;                // Compteur d'operations pour prevention des replays
    }

    // -------------------------------------------------------------------------
    // HISTORIQUE DES TRANSACTIONS (registre immuable)
    // -------------------------------------------------------------------------
    // Chaque operation sur le titre est enregistree de facon immuable.
    // Cette trace constitue la preuve juridique opposable aux tiers.
    // Conformite : Art. R. 228-10 Code de Commerce, MiFID II Art. 25

    /// @notice Enregistrement d'une transaction sur le titre
    struct Transaction {
        bytes32 idTransaction;       // Identifiant unique de la transaction
        address expediteur;          // Adresse source (address(0) pour emission)
        address destinataire;        // Adresse destination (address(0) pour rachat)
        uint256 quantite;            // Quantite de tokens transferes (18 dec)
        uint256 prixUnitaire;        // Prix unitaire au moment de la transaction (EUR, 18 dec)
        uint256 montantTotal;        // Montant total en EUR (18 dec)
        TypeTransaction typeTransaction; // EMISSION, TRANSFERT, RACHAT, BLOCAGE, DEBLOCAGE
        uint256 horodatage;          // Timestamp de la transaction (Unix)
        bytes32 referenceFond;       // Identifiant du cycle NAV du fonds si applicable
        string  motif;               // Motif libre (ex: "Souscription cycle #42")
        bytes32 empreintePrec;       // Hash de la transaction precedente (chaine d'integrite)
    }

    // -------------------------------------------------------------------------
    // DISTRIBUTION DE DIVIDENDES / COUPONS
    // -------------------------------------------------------------------------

    /// @notice Enregistrement d'une distribution de dividendes ou coupons
    struct Distribution {
        uint256 idDistribution;      // Identifiant sequentiel
        uint256 montantTotalEUR;     // Montant total distribue (EUR, 18 dec)
        uint256 montantParToken;     // Montant par token (EUR, 18 dec) = total / supply
        uint256 snapshotSupply;      // Supply totale au moment du snapshot
        uint256 horodatageSnapshot;  // Timestamp du snapshot de reference
        uint256 horodatageDistrib;   // Timestamp de la distribution effective
        TypeDistribution typeDistrib; // DIVIDENDE, COUPON, REMBOURSEMENT_PARTIEL
        bool estFinalise;            // True si tous les dividendes ont ete reclames
        bytes32 empreinteDistrib;    // Hash cryptographique pour audit
    }

    // -------------------------------------------------------------------------
    // DOCUMENTS JURIDIQUES ON-CHAIN
    // -------------------------------------------------------------------------
    // Le DLT Pilot Regime (Art. 7.3) et la Directive Prospectus exigent que les
    // documents constitutifs soient accessibles aux investisseurs.
    // On stocke les hashs et URI des documents (pas leur contenu, pour des raisons de gas).

    /// @notice Reference a un document juridique associe au titre
    struct DocumentJuridique {
        bytes32 typeDocument;        // keccak256 du type (ex: keccak256("PROSPECTUS"))
        string  uri;                 // URI HTTPS ou IPFS du document
        bytes32 hashContenu;         // keccak256 du contenu du document (verification integrite)
        uint256 datePublication;     // Timestamp de publication
        uint256 dateExpiration;      // Timestamp d'expiration (0 = pas d'expiration)
        bool    estValide;           // False si le document a ete revoque
    }

    // =========================================================================
    // ENUMERATIONS
    // =========================================================================

    /// @notice Types de titres financiers tokenises supportes
    enum TypeTitre {
        ACTION_ORDINAIRE,      // Action avec droit de vote et dividende
        ACTION_PREFERENCE,     // Action avec droits prefentiels (dividende prioritaire)
        ACTION_FONDATEUR,      // Action de fondateur (droits de vote renforces)
        OBLIGATION,            // Titre de creance a taux fixe ou variable
        PART_FONDS,            // Part d'OPC (OPCVM, FIA, FPCI)
        BILLET_TRESORERIE,     // NEU CP (< 1 an, discount)
        CERTIFICAT,            // Certificat representatif d'actif reel (immobilier, commodite)
        AUTRE                  // Instrument non categorise
    }

    /// @notice Classes d'actions (pour la gestion des droits differencies)
    enum ClasseAction {
        CLASSE_A,   // Standard : 1 action = 1 voix, dividende ordinaire
        CLASSE_B,   // Double droit de vote (suite a detention > 2 ans, Loi Florange)
        CLASSE_C,   // Sans droit de vote (action de preference pure)
        SANS_OBJET  // Pour les titres de dette et fonds
    }

    /// @notice Types de transactions enregistrees dans l'historique
    enum TypeTransaction {
        EMISSION,              // Creation de nouveaux tokens (mint)
        TRANSFERT,             // Transfert entre detenteurs
        RACHAT,                // Destruction de tokens (burn)
        BLOCAGE,               // Immobilisation d'un solde (nantissement, gel)
        DEBLOCAGE,             // Liberation d'un solde bloque
        TRANSFERT_FORCE,       // Transfert ordonne par autorite judiciaire ou regulatoire
        CONVERSION             // Conversion entre classes d'actions
    }

    /// @notice Types de distributions
    enum TypeDistribution {
        DIVIDENDE,             // Distribution de benefices aux actionnaires
        COUPON,                // Paiement d'interet sur obligation
        REMBOURSEMENT_PARTIEL, // Amortissement partiel du principal
        REMBOURSEMENT_FINAL,   // Remboursement integral a maturite
        PRIME_EMISSION         // Distribution de la prime d'emission
    }

    /// @notice Statuts possibles d'un transfert (ERC-1400 canTransfer codes)
    enum StatutTransfert {
        TRANSFERT_OK,                    // 0x51 : transfert autorise
        SUCCES_AVEC_RESTRICTIONS,        // 0x52 : autorise avec conditions
        INSUFFISANT_SOLDE,               // 0x50 : solde insuffisant
        DETENTEUR_GELE,                  // 0x53 : compte gele
        DESTINATAIRE_NON_AUTORISE,       // 0x54 : KYC/AML non valide
        TRANSFERT_RESTREINT,             // 0x55 : restriction contractuelle
        PERIODE_INCESSIBILITE,           // 0x56 : periode de blocage non echouee
        DOCUMENT_REQUIS,                 // 0x57 : prospectus/accord requis
        MONTANT_INVALIDE,                // 0x58 : montant nul ou negatif
        ERREUR_INTERNE                   // 0x5F : erreur interne
    }

    // =========================================================================
    // VARIABLES D'ETAT
    // =========================================================================

    /// @notice Metadonnees reglementaires du titre (immuables apres publication)
    MetadonneesTitre private _metadonnees;

    /// @notice Reference au contrat FondTokenise (peut etre nul si standalone)
    IFondTokenise private _fondTokenise;

    /// @notice Reference au contrat Toolbox (pour les calculs de valorisation)
    IToolboxActif private _toolbox;

    /// @notice Supply totale de tokens en circulation (18 dec)
    uint256 private _supplyTotale;

    /// @notice Supply maximale autorisee (0 = illimitee)
    /// Correspond au capital autorise inscrit dans les statuts.
    uint256 private _supplyMaximale;

    /// @notice Soldes par detenteur : adresse => solde (18 dec)
    /// Mapping principal pour les operations courantes (O(1))
    mapping(address => uint256) private _soldes;

    /// @notice Soldes bloques par detenteur : adresse => montant immobilise (18 dec)
    /// Le solde disponible = _soldes[addr] - _soldesBlockes[addr]
    mapping(address => uint256) private _soldesBlockes;

    /// @notice Registre complet des detenteurs : adresse => EntreeDetenteur
    /// Source de verite juridique, maintenu par le registraire
    mapping(address => EntreeDetenteur) private _registreDetenteurs;

    /// @notice Liste ordonnee des adresses de detenteurs (pour iteration d'audit)
    address[] private _listeDetenteurs;

    /// @notice Allowances de transfert : detenteur => operateur => montant autorise
    /// Pattern ERC-20 etendu pour les operateurs autorises (agent de transfert, etc.)
    mapping(address => mapping(address => uint256)) private _allowances;

    /// @notice Historique des transactions : hash de transaction => Transaction
    mapping(bytes32 => Transaction) private _historiqueTransactions;

    /// @notice Liste ordonnee des IDs de transactions (pour audit sequentiel)
    bytes32[] private _listeTransactions;

    /// @notice Hash de la derniere transaction (pour chainer les empreintes)
    bytes32 private _empreintePrec;

    /// @notice Distributions de dividendes/coupons : id => Distribution
    mapping(uint256 => Distribution) private _distributions;

    /// @notice Compteur de distributions
    uint256 private _nombreDistributions;

    /// @notice Dividendes reclames par detenteur et par distribution
    /// detenteur => idDistrib => montantReclame
    mapping(address => mapping(uint256 => uint256)) private _dividendesReclames;

    /// @notice Documents juridiques : typeDocument => liste de documents
    mapping(bytes32 => DocumentJuridique[]) private _documents;

    /// @notice Types de documents enregistres (pour iteration)
    bytes32[] private _typesDocuments;

    /// @notice Nonces pour prevention des replays de signatures ECDSA
    mapping(address => uint256) private _nonces;

    /// @notice Prix de marche courant (EUR, 18 dec) - soumis par le valorisateur
    uint256 private _prixMarche;

    /// @notice Timestamp de la derniere mise a jour du prix
    uint256 private _horodatageLastPrix;

    /// @notice Valorisation totale de l'actif (prixMarche × supplyTotale / PRECISION)
    uint256 private _valorisationTotale;

    /// @notice Statut de publication : True si les metadonnees sont publiees et gelees
    /// Une fois publie, les metadonnees essentielles ne peuvent plus etre modifiees.
    bool private _estPublie;

    /// @notice Version du contrat
    string public version;

    // =========================================================================
    // EVENEMENTS — TRACE REGLEMENTAIRE ET AUDIT IMMUABLE
    // =========================================================================
    // Chaque evenement est la trace legale d'une operation sur le titre.
    // Conformite : Art. R228-10 C.Com., MiFID II Art. 25, EMIR Art. 9.

    /// @notice Emission de nouveaux tokens (mint)
    event TokensEmis(
        address indexed destinataire,
        uint256 quantite,
        uint256 prixUnitaire,
        bytes32 indexed idTransaction,
        string  motif,
        uint256 horodatage
    );

    /// @notice Destruction de tokens (burn / rachat)
    event TokensRachetes(
        address indexed detenteur,
        uint256 quantite,
        uint256 prixUnitaire,
        bytes32 indexed idTransaction,
        string  motif,
        uint256 horodatage
    );

    /// @notice Transfert de tokens entre detenteurs
    event TransfertEffectue(
        address indexed expediteur,
        address indexed destinataire,
        uint256 quantite,
        uint256 prixUnitaire,
        bytes32 indexed idTransaction,
        bool    estForce,
        uint256 horodatage
    );

    /// @notice Blocage d'un solde (nantissement, gel judiciaire, lock-up)
    event SoldeBloqueModifie(
        address indexed detenteur,
        uint256 ancienSoldeBloque,
        uint256 nouveauSoldeBloque,
        string  motif,
        uint256 horodatage
    );

    /// @notice Gel ou degel d'un compte
    event CompteGeleModifie(
        address indexed detenteur,
        bool    estGele,
        string  motif,
        address indexed parCompliance,
        uint256 horodatage
    );

    /// @notice Enregistrement d'un nouveau detenteur dans le registre
    event DetenteurEnregistre(
        address indexed detenteur,
        string  referenceKYC,
        uint256 horodatage
    );

    /// @notice Mise a jour du prix de marche
    event PrixMarcheMisAJour(
        uint256 ancienPrix,
        uint256 nouveauPrix,
        uint256 valorisationTotale,
        address indexed valorisateur,
        uint256 horodatage
    );

    /// @notice Ouverture d'une distribution de dividendes / coupons
    event DistributionOuverte(
        uint256 indexed idDistribution,
        TypeDistribution typeDistrib,
        uint256 montantTotalEUR,
        uint256 montantParToken,
        uint256 snapshotSupply,
        uint256 horodatage
    );

    /// @notice Reclamation de dividendes par un detenteur
    event DividendesReclames(
        address indexed detenteur,
        uint256 indexed idDistribution,
        uint256 montantEUR,
        uint256 horodatage
    );

    /// @notice Publication d'un document juridique
    event DocumentJuridiquePublie(
        bytes32 indexed typeDocument,
        string  uri,
        bytes32 hashContenu,
        uint256 horodatage
    );

    /// @notice Revocation d'un document juridique
    event DocumentJuridiqueRevoque(
        bytes32 indexed typeDocument,
        uint256 indexDocument,
        string  motif,
        uint256 horodatage
    );

    /// @notice Synchronisation avec FondTokenise (cycle NAV)
    event SynchronisationFond(
        uint256 navFond,
        uint256 prixActif,
        uint256 cycleNAV,
        uint256 horodatage
    );

    /// @notice Tentative de transfert refusee (traçabilite des refus)
    event TransfertRefuse(
        address indexed expediteur,
        address indexed destinataire,
        uint256 quantite,
        StatutTransfert raison,
        uint256 horodatage
    );

    /// @notice Alerte de securite
    event AlerteSecurite(
        string  description,
        address indexed declencheur,
        uint256 horodatage
    );

    /// @notice Mise a jour de la supply maximale autorisee
    event SupplyMaximaleMisAJour(
        uint256 ancienneSupply,
        uint256 nouvelleSupply,
        uint256 horodatage
    );

    /// @notice Publication des metadonnees (gelee apres publication)
    event MetadonneesPubliees(
        string  isin,
        TypeTitre typeTitre,
        uint256 horodatage
    );

    // =========================================================================
    // MODIFICATEURS
    // =========================================================================

    /// @dev Verifie que le titre a ete publie (metadonnees gelees)
    modifier seulementApresPublication() {
        require(_estPublie, "ACTIF: Titre non encore publie - Publier les metadonnees d'abord");
        _;
    }

    /// @dev Verifie que le titre n'est pas encore publie (modification possible)
    modifier seulementAvantPublication() {
        require(!_estPublie, "ACTIF: Titre deja publie - Metadonnees gelees");
        _;
    }

    /// @dev Verifie que le detenteur est autorise (KYC valide, non gele)
    modifier seulementDetenteurAutorise(address detenteur) {
        require(detenteur != address(0), "ACTIF: Adresse detenteur invalide");
        require(
            _registreDetenteurs[detenteur].estDetenteurAutorise,
            "ACTIF: Detenteur non autorise - Enregistrement KYC requis"
        );
        require(
            !_registreDetenteurs[detenteur].estGele,
            "ACTIF: Compte detenteur gele - Contacter le registraire"
        );
        _;
    }

    /// @dev Verifie que les contrats externes sont configures
    modifier toolboxConfiguree() {
        require(
            address(_toolbox) != address(0),
            "ACTIF: Toolbox non configure"
        );
        _;
    }

    // =========================================================================
    // CONSTRUCTEUR
    // =========================================================================

    /// @notice Deploie le contrat ActifTokenise
    /// @param adresseAdmin Adresse recevant les roles fondateurs
    /// @param adresseToolbox Adresse du Toolbox pour les calculs financiers
    /// @param adresseFond Adresse du FondTokenise (peut etre address(0) si standalone)
    /// @param supplyMaximale Supply maximale autorisee en tokens (0 = illimitee)
    /// @param versionContrat Version du contrat (ex: "1.0.0")
    ///
    /// @dev L'ordre de deploiement recommande :
    ///   1. Toolbox.sol
    ///   2. FondTokenise.sol (avec adresse Toolbox)
    ///   3. ActifTokenise.sol (avec adresses Toolbox + FondTokenise)
    ///   4. ActifTokeniseHolding.sol (avec adresses des 3 precedents)
    constructor(
        address adresseAdmin,
        address adresseToolbox,
        address adresseFond,
        uint256 supplyMaximale,
        string memory versionContrat
    ) {
        require(adresseAdmin   != address(0), "ACTIF: Adresse admin invalide");
        require(adresseToolbox != address(0), "ACTIF: Adresse Toolbox invalide");
        require(bytes(versionContrat).length > 0, "ACTIF: Version vide");

        version      = versionContrat;
        _toolbox     = IToolboxActif(adresseToolbox);
        _supplyMaximale = supplyMaximale; // 0 = illimite (capital autorise non plafonne)

        // Connexion optionnelle au FondTokenise
        if (adresseFond != address(0)) {
            _fondTokenise = IFondTokenise(adresseFond);
        }

        // Initialisation de la chaine d'integrite des transactions
        _empreintePrec = keccak256(abi.encodePacked(
            "GENESE",
            adresseAdmin,
            block.timestamp,
            address(this)
        ));

        // Attribution des roles fondateurs
        _grantRole(DEFAULT_ADMIN_ROLE, adresseAdmin);
        _grantRole(ROLE_ADMIN,               adresseAdmin);
        _grantRole(ROLE_EMETTEUR,            adresseAdmin);
        _grantRole(ROLE_REGISTRAIRE,         adresseAdmin);
        _grantRole(ROLE_COMPLIANCE,          adresseAdmin);
        _grantRole(ROLE_VALORISATEUR,        adresseAdmin);
        _grantRole(ROLE_OPERATEUR_DIVIDENDES, adresseAdmin);

        // Si un FondTokenise est fourni, il recoit automatiquement ROLE_FOND_AUTORISE
        if (adresseFond != address(0)) {
            _grantRole(ROLE_FOND_AUTORISE, adresseFond);
        }
    }

    // =========================================================================
    // MODULE 1 : PUBLICATION DES METADONNEES REGLEMENTAIRES
    // =========================================================================
    // Les metadonnees sont publiees en une seule operation puis gelees.
    // Ce mecanisme garantit que l'ISIN, le type de titre et les droits attaches
    // ne peuvent pas etre modifies apres la premiere emission.

    /// @notice Publie les metadonnees reglementaires du titre (operation unique et irreversible)
    /// @param isin Code ISIN (12 caracteres)
    /// @param cfi Code CFI (6 caracteres) — Classification des Instruments Financiers ISO 10962
    /// @param denominationLegale Denomination legale complete de l'emetteur
    /// @param symbole Symbole de negociation (ex: "BNP", "SAN")
    /// @param typeTitre Type de titre (voir enum TypeTitre)
    /// @param classeAction Classe d'action (voir enum ClasseAction)
    /// @param valeurNominaleParPart Valeur nominale en EUR (18 dec)
    /// @param droitVoteParPart Nombre de voix par titre (0 si pas de droit de vote)
    /// @param aDroitDividende True si ce titre donne droit au dividende
    /// @param aDroitVote True si ce titre donne droit de vote
    /// @param transfertRestreint True si les transferts necessitent une pre-approbation
    /// @param offrePubliqueExclue True si reserve aux investisseurs qualifies
    /// @param periodeIncessibilite Duree d'incessibilite en secondes (0 = aucune)
    /// @param dateMaturite Timestamp de maturite (0 = titre perpetuel, ex: actions)
    /// @param juridiction Droit applicable (ex: "FR", "LU")
    ///
    /// @dev Une fois les metadonnees publiees, l'ISIN, le typeTitre, la valeurNominale
    ///   et les droits attaches sont immutables. Seul l'URI du registre peut etre
    ///   mis a jour par le registraire (pour pointer vers un document actualise).
    function publierMetadonnees(
        string  calldata isin,
        string  calldata cfi,
        string  calldata denominationLegale,
        string  calldata symbole,
        TypeTitre typeTitre,
        ClasseAction classeAction,
        uint256 valeurNominaleParPart,
        uint256 droitVoteParPart,
        bool    aDroitDividende,
        bool    aDroitVote,
        bool    transfertRestreint,
        bool    offrePubliqueExclue,
        uint256 periodeIncessibilite,
        uint256 dateMaturite,
        string  calldata juridiction
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
        seulementAvantPublication
    {
        // --- CHECKS ---
        require(bytes(isin).length == 12,                   "ACTIF: ISIN invalide - 12 caracteres requis");
        require(bytes(cfi).length == 6,                     "ACTIF: Code CFI invalide - 6 caracteres requis");
        require(bytes(denominationLegale).length > 0,       "ACTIF: Denomination legale vide");
        require(bytes(symbole).length > 0,                  "ACTIF: Symbole vide");
        require(valeurNominaleParPart > 0,                  "ACTIF: Valeur nominale nulle");
        require(bytes(juridiction).length > 0,              "ACTIF: Juridiction vide");
        require(
            dateMaturite == 0 || dateMaturite > block.timestamp,
            "ACTIF: Date de maturite deja passee"
        );

        // --- EFFECTS : publication et gel des metadonnees ---
        _metadonnees = MetadonneesTitre({
            isin:                  isin,
            cfi:                   cfi,
            denominationLegale:    denominationLegale,
            symbole:               symbole,
            typeTitre:             typeTitre,
            classeAction:          classeAction,
            valeurNominaleParPart: valeurNominaleParPart,
            droitVoteParPart:      droitVoteParPart,
            aDroitDividende:       aDroitDividende,
            aDroitVote:            aDroitVote,
            transfertRestreint:    transfertRestreint,
            offrePubliqueExclue:   offrePubliqueExclue,
            periodeIncessibilite:  periodeIncessibilite,
            dateEmission:          block.timestamp,
            dateMaturite:          dateMaturite,
            juridiction:           juridiction,
            adresseRegistre:       ""  // URI renseignee separement
        });

        _estPublie = true;

        emit MetadonneesPubliees(isin, typeTitre, block.timestamp);
    }

    // =========================================================================
    // MODULE 2 : REGISTRE DES DETENTEURS
    // =========================================================================

    /// @notice Enregistre un nouveau detenteur dans le registre des titres
    /// @param detenteur Adresse blockchain du detenteur
    /// @param referenceKYC Hash de la reference KYC (keccak256 de l'ID KYC off-chain)
    ///
    /// @dev Le registraire est responsable de la validite du KYC.
    ///   La reference KYC est un hash : elle ne contient pas de donnee personnelle
    ///   (conformite RGPD Art. 25 — privacy by design).
    function enregistrerDetenteur(
        address detenteur,
        string calldata referenceKYC
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
        whenNotPaused
    {
        // --- CHECKS ---
        require(detenteur != address(0),              "ACTIF: Adresse detenteur invalide");
        require(bytes(referenceKYC).length > 0,       "ACTIF: Reference KYC vide");
        require(
            !_registreDetenteurs[detenteur].estGele,
            "ACTIF: Impossible d'enregistrer un compte gele"
        );
        require(
            _listeDetenteurs.length < MAX_DETENTEURS,
            "ACTIF: Registre plein - Contacter l'administrateur"
        );

        // --- EFFECTS ---
        bool estNouveauDetenteur = (_registreDetenteurs[detenteur].datePremiereAcquisition == 0);

        if (estNouveauDetenteur) {
            _registreDetenteurs[detenteur] = EntreeDetenteur({
                adresse:                  detenteur,
                solde:                    0,
                soldeBloque:              0,
                datePremiereAcquisition:  block.timestamp,
                dateDerniereOperation:    block.timestamp,
                referenceKYC:             referenceKYC,
                estDetenteurAutorise:     true,
                estGele:                  false,
                dividendesAccumules:      0,
                nonce:                    0
            });
            _listeDetenteurs.push(detenteur);
        } else {
            // Mise a jour du KYC sur un compte existant
            _registreDetenteurs[detenteur].referenceKYC          = referenceKYC;
            _registreDetenteurs[detenteur].estDetenteurAutorise   = true;
        }

        emit DetenteurEnregistre(detenteur, referenceKYC, block.timestamp);
    }

    /// @notice Gele ou degele un compte (sanctions, contentieux, instruction judiciaire)
    /// @param detenteur Adresse du compte a modifier
    /// @param geler True pour geler, False pour degeler
    /// @param motif Motif legal obligatoire (ex: "Gel avoirs OFAC", "Mesure conservatoire")
    function gelerCompte(
        address detenteur,
        bool    geler,
        string  calldata motif
    )
        external
        onlyRole(ROLE_COMPLIANCE)
    {
        // --- CHECKS ---
        require(detenteur != address(0),       "ACTIF: Adresse invalide");
        require(bytes(motif).length > 0,       "ACTIF: Motif obligatoire");
        require(
            _registreDetenteurs[detenteur].datePremiereAcquisition > 0,
            "ACTIF: Detenteur non enregistre"
        );

        // --- EFFECTS ---
        _registreDetenteurs[detenteur].estGele = geler;

        emit CompteGeleModifie(detenteur, geler, motif, msg.sender, block.timestamp);

        if (geler) {
            emit AlerteSecurite(
                string(abi.encodePacked("Compte gele : ", motif)),
                detenteur,
                block.timestamp
            );
        }
    }

    // =========================================================================
    // MODULE 3 : EMISSION DE TOKENS (MINT)
    // =========================================================================
    // L'emission de tokens represente la creation de nouveaux titres financiers.
    // Elle ne peut avoir lieu que si :
    //   1. Les metadonnees sont publiees
    //   2. Le destinataire est enregistre et autorise (KYC valide)
    //   3. La supply maximale n'est pas depassee
    //   4. L'emetteur dispose du role ROLE_EMETTEUR

    /// @notice Emet des tokens a destination d'un detenteur autorise
    /// @param destinataire Adresse du futur detenteur
    /// @param quantite Quantite de tokens a emettre (18 dec)
    /// @param prixUnitaire Prix d'emission unitaire en EUR (18 dec)
    /// @param motif Motif de l'emission (ex: "Souscription initiale", "Augmentation de capital")
    /// @return idTransaction Identifiant unique de la transaction d'emission
    ///
    /// @dev Pattern CEI strict :
    ///   C — Verification des autorisations, de la supply max, du KYC
    ///   E — Mise a jour des soldes, du registre, enregistrement de la transaction
    ///   I — Emission de l'event (aucun appel externe dans cette fonction)
    function emettreTokens(
        address destinataire,
        uint256 quantite,
        uint256 prixUnitaire,
        string  calldata motif
    )
        external
        onlyRole(ROLE_EMETTEUR)
        whenNotPaused
        nonReentrant
        seulementApresPublication
        seulementDetenteurAutorise(destinataire)
        returns (bytes32 idTransaction)
    {
        // =====================================================================
        // CHECKS
        // =====================================================================
        require(quantite > 0,       "ACTIF: Quantite d'emission nulle");
        require(prixUnitaire > 0,   "ACTIF: Prix d'emission nul");

        // Verification de la supply maximale (si plafonnee)
        if (_supplyMaximale > 0) {
            require(
                _supplyTotale + quantite <= _supplyMaximale,
                "ACTIF: Supply maximale depassee - Augmentation de capital requise"
            );
        }

        // =====================================================================
        // EFFECTS — Toutes les mutations d'etat avant tout appel externe
        // =====================================================================

        // Mise a jour des soldes
        _soldes[destinataire]   += quantite;
        _supplyTotale           += quantite;

        // Mise a jour du registre
        EntreeDetenteur storage entree = _registreDetenteurs[destinataire];
        entree.solde                  = _soldes[destinataire];
        entree.dateDerniereOperation  = block.timestamp;
        entree.nonce                 += 1;

        // Calcul du montant total de la transaction
        uint256 montantTotal = quantite.mulDiv(prixUnitaire, PRECISION);

        // Mise a jour de la valorisation
        _mettreAJourValorisationInterne();

        // Enregistrement de la transaction dans l'historique immuable
        idTransaction = _enregistrerTransaction(
            address(0),    // Expedition depuis le neant (emission)
            destinataire,
            quantite,
            prixUnitaire,
            montantTotal,
            TypeTransaction.EMISSION,
            motif
        );

        emit TokensEmis(
            destinataire,
            quantite,
            prixUnitaire,
            idTransaction,
            motif,
            block.timestamp
        );

        return idTransaction;
    }

    // =========================================================================
    // MODULE 4 : RACHAT DE TOKENS (BURN)
    // =========================================================================

    /// @notice Rachete (detruit) des tokens d'un detenteur
    /// @param detenteur Adresse du detenteur dont les tokens seront rachetes
    /// @param quantite Quantite de tokens a racheter (18 dec)
    /// @param prixUnitaire Prix de rachat unitaire en EUR (18 dec)
    /// @param motif Motif du rachat (ex: "Remboursement a maturite", "Rachat sur demande")
    /// @return idTransaction Identifiant unique de la transaction de rachat
    function racheterTokens(
        address detenteur,
        uint256 quantite,
        uint256 prixUnitaire,
        string  calldata motif
    )
        external
        onlyRole(ROLE_EMETTEUR)
        whenNotPaused
        nonReentrant
        seulementApresPublication
        returns (bytes32 idTransaction)
    {
        // =====================================================================
        // CHECKS
        // =====================================================================
        require(detenteur != address(0),  "ACTIF: Adresse detenteur invalide");
        require(quantite > 0,             "ACTIF: Quantite de rachat nulle");
        require(prixUnitaire > 0,         "ACTIF: Prix de rachat nul");

        // Verification du solde disponible (solde total - solde bloque)
        uint256 soldeDisponible = _soldes[detenteur] - _soldesBlockes[detenteur];
        require(
            soldeDisponible >= quantite,
            "ACTIF: Solde disponible insuffisant (prise en compte des soldes bloques)"
        );

        // =====================================================================
        // EFFECTS
        // =====================================================================

        _soldes[detenteur]  -= quantite;
        _supplyTotale       -= quantite;

        EntreeDetenteur storage entree = _registreDetenteurs[detenteur];
        entree.solde                  = _soldes[detenteur];
        entree.dateDerniereOperation  = block.timestamp;
        entree.nonce                 += 1;

        uint256 montantTotal = quantite.mulDiv(prixUnitaire, PRECISION);
        _mettreAJourValorisationInterne();

        idTransaction = _enregistrerTransaction(
            detenteur,
            address(0),    // Vers le neant (destruction)
            quantite,
            prixUnitaire,
            montantTotal,
            TypeTransaction.RACHAT,
            motif
        );

        emit TokensRachetes(
            detenteur,
            quantite,
            prixUnitaire,
            idTransaction,
            motif,
            block.timestamp
        );

        return idTransaction;
    }

    // =========================================================================
    // MODULE 5 : TRANSFERTS DE TOKENS
    // =========================================================================
    // Les transferts implementent le principe ERC-1400 :
    //   - canTransfer() verifie les restrictions AVANT le transfert
    //   - transferWithData() effectue le transfert avec une reference juridique
    //   - transferForce() permet a l'agent de transfert d'agir sur autorisation judiciaire

    /// @notice Verifie si un transfert est autorise (ERC-1400 canTransfer)
    /// @param expediteur Adresse source
    /// @param destinataire Adresse destination
    /// @param quantite Quantite a transferer
    /// @return statut Code de statut (voir enum StatutTransfert)
    /// @return message Message explicatif
    ///
    /// @dev Fonction view : peut etre appelee gratuitement avant de soumettre un transfert.
    ///   Permet au front-end d'informer l'utilisateur du motif de refus eventuel.
    function verifierTransfert(
        address expediteur,
        address destinataire,
        uint256 quantite
    )
        public
        view
        returns (StatutTransfert statut, string memory message)
    {
        // Verification du montant
        if (quantite == 0) {
            return (StatutTransfert.MONTANT_INVALIDE, "Quantite nulle");
        }

        // Verification de l'expediteur
        if (expediteur == address(0)) {
            return (StatutTransfert.MONTANT_INVALIDE, "Expediteur invalide");
        }

        // Verification gel du compte expediteur
        if (_registreDetenteurs[expediteur].estGele) {
            return (StatutTransfert.DETENTEUR_GELE, "Compte expediteur gele");
        }

        // Verification du solde disponible
        uint256 soldeDisponible = _soldes[expediteur] - _soldesBlockes[expediteur];
        if (soldeDisponible < quantite) {
            return (StatutTransfert.INSUFFISANT_SOLDE, "Solde disponible insuffisant");
        }

        // Verification du destinataire
        if (destinataire == address(0)) {
            return (StatutTransfert.DESTINATAIRE_NON_AUTORISE, "Adresse destinataire nulle");
        }

        // Verification KYC du destinataire
        if (!_registreDetenteurs[destinataire].estDetenteurAutorise) {
            return (StatutTransfert.DESTINATAIRE_NON_AUTORISE, "Destinataire non enregistre ou KYC invalide");
        }

        // Verification gel du compte destinataire
        if (_registreDetenteurs[destinataire].estGele) {
            return (StatutTransfert.DETENTEUR_GELE, "Compte destinataire gele");
        }

        // Verification des restrictions de transfert (metadonnees du titre)
        if (_metadonnees.transfertRestreint) {
            return (StatutTransfert.TRANSFERT_RESTREINT, "Titre a transferts restreints - Approbation requise");
        }

        // Verification de la periode d'incessibilite
        if (_metadonnees.periodeIncessibilite > 0) {
            uint256 dateFinIncessibilite = _registreDetenteurs[expediteur].datePremiereAcquisition
                + _metadonnees.periodeIncessibilite;
            if (block.timestamp < dateFinIncessibilite) {
                return (StatutTransfert.PERIODE_INCESSIBILITE, "Periode d'incessibilite non echouee");
            }
        }

        return (StatutTransfert.TRANSFERT_OK, "Transfert autorise");
    }

    /// @notice Transfert de tokens avec reference juridique (ERC-1400 transferWithData)
    /// @param destinataire Adresse du destinataire
    /// @param quantite Quantite a transferer (18 dec)
    /// @param referenceJuridique Reference contractuelle ou ordonnancement (ex: numero de bon de cession)
    /// @return idTransaction Identifiant unique de la transaction
    ///
    /// @dev Ce transfert est initie par msg.sender (le detenteur lui-meme).
    ///   Pour les transferts autorises par un operateur (ex: agent de transfert),
    ///   utiliser transferDepuis().
    function transfererAvecReference(
        address destinataire,
        uint256 quantite,
        string  calldata referenceJuridique
    )
        external
        whenNotPaused
        nonReentrant
        seulementApresPublication
        seulementDetenteurAutorise(msg.sender)
        returns (bytes32 idTransaction)
    {
        // =====================================================================
        // CHECKS — Verification via canTransfer
        // =====================================================================
        (StatutTransfert statut, string memory message) = verifierTransfert(
            msg.sender,
            destinataire,
            quantite
        );

        if (statut != StatutTransfert.TRANSFERT_OK) {
            emit TransfertRefuse(msg.sender, destinataire, quantite, statut, block.timestamp);
            revert(string(abi.encodePacked("ACTIF: Transfert refuse - ", message)));
        }

        // =====================================================================
        // EFFECTS
        // =====================================================================
        idTransaction = _executerTransfert(
            msg.sender,
            destinataire,
            quantite,
            referenceJuridique,
            false // pas un transfert force
        );

        return idTransaction;
    }

    /// @notice Transfert depuis un compte tiers via allowance (pattern ERC-20)
    /// @param expediteur Adresse source
    /// @param destinataire Adresse destination
    /// @param quantite Quantite a transferer
    /// @param referenceJuridique Reference de l'operation
    function transfererDepuis(
        address expediteur,
        address destinataire,
        uint256 quantite,
        string  calldata referenceJuridique
    )
        external
        whenNotPaused
        nonReentrant
        seulementApresPublication
        returns (bytes32 idTransaction)
    {
        // --- CHECKS ---
        require(
            _allowances[expediteur][msg.sender] >= quantite,
            "ACTIF: Allowance insuffisante - Appeler approuverOperateur() d'abord"
        );

        (StatutTransfert statut, string memory message) = verifierTransfert(
            expediteur,
            destinataire,
            quantite
        );
        if (statut != StatutTransfert.TRANSFERT_OK) {
            emit TransfertRefuse(expediteur, destinataire, quantite, statut, block.timestamp);
            revert(string(abi.encodePacked("ACTIF: Transfert refuse - ", message)));
        }

        // --- EFFECTS ---
        _allowances[expediteur][msg.sender] -= quantite;

        idTransaction = _executerTransfert(
            expediteur,
            destinataire,
            quantite,
            referenceJuridique,
            false
        );

        return idTransaction;
    }

    /// @notice Transfert force par l'agent de transfert (autorisation judiciaire ou reglementaire)
    /// @param expediteur Adresse source
    /// @param destinataire Adresse destination
    /// @param quantite Quantite a transferer
    /// @param motifLegal Motif legal obligatoire (ex: "Ordonnance TGI Paris n°2024-1234")
    ///
    /// @dev Un transfert force peut contourner le gel d'un compte (pour transfert judiciaire).
    ///   Il NE peut PAS contourner les soldes bloques par nantissement : le crediteur
    ///   nanti a la priorite sur le transfert force (droit des suretés).
    function transfererForce(
        address expediteur,
        address destinataire,
        uint256 quantite,
        string  calldata motifLegal
    )
        external
        onlyRole(ROLE_AGENT_TRANSFERT)
        whenNotPaused
        nonReentrant
        seulementApresPublication
        returns (bytes32 idTransaction)
    {
        // --- CHECKS ---
        require(expediteur   != address(0), "ACTIF: Expediteur invalide");
        require(destinataire != address(0), "ACTIF: Destinataire invalide");
        require(quantite > 0,               "ACTIF: Quantite nulle");
        require(bytes(motifLegal).length > 0, "ACTIF: Motif legal obligatoire pour transfert force");

        // Un transfert force DOIT respecter les soldes bloques (nantissements)
        uint256 soldeDisponible = _soldes[expediteur] - _soldesBlockes[expediteur];
        require(
            soldeDisponible >= quantite,
            "ACTIF: Solde disponible insuffisant (soldes bloques proteges)"
        );

        // Le destinataire doit etre enregistre (KYC valide) meme pour un transfert force
        require(
            _registreDetenteurs[destinataire].estDetenteurAutorise,
            "ACTIF: Destinataire non autorise meme pour un transfert force"
        );

        // --- EFFECTS ---
        idTransaction = _executerTransfert(
            expediteur,
            destinataire,
            quantite,
            motifLegal,
            true // transfert force
        );

        emit AlerteSecurite(
            string(abi.encodePacked("Transfert force : ", motifLegal)),
            msg.sender,
            block.timestamp
        );

        return idTransaction;
    }

    /// @notice Approuve un operateur pour gerer une allowance
    /// @param operateur Adresse de l'operateur autorise
    /// @param montant Montant autorise (18 dec)
    function approuverOperateur(address operateur, uint256 montant) external whenNotPaused {
        require(operateur != address(0), "ACTIF: Adresse operateur invalide");
        require(operateur != msg.sender,  "ACTIF: Auto-approbation interdite");

        _allowances[msg.sender][operateur] = montant;
    }

    // =========================================================================
    // MODULE 6 : GESTION DES SOLDES BLOQUES (NANTISSEMENTS / GEL)
    // =========================================================================

    /// @notice Bloque une portion du solde d'un detenteur
    /// @param detenteur Adresse du detenteur
    /// @param montant Montant supplementaire a bloquer (18 dec)
    /// @param motif Motif du blocage (ex: "Nantissement BNP Paribas", "Mesure conservatoire")
    ///
    /// @dev Cas d'usage :
    ///   - Nantissement de titres en garantie d'un credit
    ///   - Immobilisation pendante une assemblee generale
    ///   - Mise sous sequestre judiciaire
    ///   - Period de lock-up post-introduction en bourse
    function bloquerSolde(
        address detenteur,
        uint256 montant,
        string  calldata motif
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
        whenNotPaused
    {
        // --- CHECKS ---
        require(detenteur != address(0),  "ACTIF: Adresse invalide");
        require(montant > 0,              "ACTIF: Montant a bloquer nul");
        require(bytes(motif).length > 0,  "ACTIF: Motif obligatoire");

        uint256 soldeDisponible = _soldes[detenteur] - _soldesBlockes[detenteur];
        require(
            soldeDisponible >= montant,
            "ACTIF: Solde disponible insuffisant pour le blocage"
        );

        // --- EFFECTS ---
        uint256 ancienSoldeBloque = _soldesBlockes[detenteur];
        _soldesBlockes[detenteur]                       += montant;
        _registreDetenteurs[detenteur].soldeBloque       = _soldesBlockes[detenteur];
        _registreDetenteurs[detenteur].dateDerniereOperation = block.timestamp;

        emit SoldeBloqueModifie(
            detenteur,
            ancienSoldeBloque,
            _soldesBlockes[detenteur],
            motif,
            block.timestamp
        );
    }

    /// @notice Debloques une portion du solde bloque d'un detenteur
    /// @param detenteur Adresse du detenteur
    /// @param montant Montant a debloquer (18 dec)
    /// @param motif Motif du deblocage (ex: "Mainlevee nantissement", "Fin de lock-up")
    function debloquerSolde(
        address detenteur,
        uint256 montant,
        string  calldata motif
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
        whenNotPaused
    {
        // --- CHECKS ---
        require(detenteur != address(0),  "ACTIF: Adresse invalide");
        require(montant > 0,              "ACTIF: Montant a debloquer nul");
        require(bytes(motif).length > 0,  "ACTIF: Motif obligatoire");
        require(
            _soldesBlockes[detenteur] >= montant,
            "ACTIF: Solde bloque insuffisant"
        );

        // --- EFFECTS ---
        uint256 ancienSoldeBloque = _soldesBlockes[detenteur];
        _soldesBlockes[detenteur]                       -= montant;
        _registreDetenteurs[detenteur].soldeBloque       = _soldesBlockes[detenteur];
        _registreDetenteurs[detenteur].dateDerniereOperation = block.timestamp;

        emit SoldeBloqueModifie(
            detenteur,
            ancienSoldeBloque,
            _soldesBlockes[detenteur],
            motif,
            block.timestamp
        );
    }

    // =========================================================================
    // MODULE 7 : DISTRIBUTIONS (DIVIDENDES / COUPONS)
    // =========================================================================
    // Mecanisme de distribution en deux phases :
    //   Phase 1 — SNAPSHOT : capture de la supply et ouverture de la distribution
    //   Phase 2 — CLAIM    : chaque detenteur reclame sa part au prorata de son solde
    //
    // Ce mecanisme "pull" (reclamation a la demande) est prefere au "push" (distribution
    // automatique) pour deux raisons :
    //   1. Gas : distribuer a 500 detenteurs en une transaction depasse la gas limit
    //   2. Securite : evite les problemes de reentrancyavec des contrats destantaires

    /// @notice Ouvre une nouvelle distribution de dividendes ou coupons
    /// @param montantTotalEUR Montant total a distribuer en EUR (18 dec)
    /// @param typeDistrib Type de distribution (DIVIDENDE, COUPON, etc.)
    /// @return idDistribution Identifiant unique de la distribution
    ///
    /// @dev La distribution capture un snapshot de la supply ACTUELLE.
    ///   Les detenteurs ayant acquis des titres APRES le snapshot ne sont pas eligibles.
    function ouvrirDistribution(
        uint256 montantTotalEUR,
        TypeDistribution typeDistrib
    )
        external
        onlyRole(ROLE_OPERATEUR_DIVIDENDES)
        whenNotPaused
        nonReentrant
        seulementApresPublication
        returns (uint256 idDistribution)
    {
        // --- CHECKS ---
        require(montantTotalEUR > 0, "ACTIF: Montant de distribution nul");
        require(_supplyTotale > 0,   "ACTIF: Aucun token en circulation - Distribution impossible");
        require(
            _metadonnees.aDroitDividende,
            "ACTIF: Ce titre ne donne pas droit au dividende"
        );

        // Verification du delai minimum entre deux distributions
        if (_nombreDistributions > 0) {
            Distribution storage derniere = _distributions[_nombreDistributions - 1];
            require(
                block.timestamp >= derniere.horodatageDistrib + DELAI_MIN_DISTRIBUTION,
                "ACTIF: Delai minimum entre distributions non ecoule (30 jours)"
            );
        }

        // --- EFFECTS ---
        idDistribution = _nombreDistributions;

        uint256 snapshotSupply = _supplyTotale;

        // Montant par token = montantTotal / supply (avec precision 18 dec)
        // mulDiv evite l'overflow sur les grandes distributions
        uint256 montantParToken = montantTotalEUR.mulDiv(PRECISION, snapshotSupply);

        bytes32 empreinteDistrib = keccak256(abi.encodePacked(
            idDistribution,
            montantTotalEUR,
            montantParToken,
            snapshotSupply,
            block.timestamp,
            address(this)
        ));

        _distributions[idDistribution] = Distribution({
            idDistribution:      idDistribution,
            montantTotalEUR:     montantTotalEUR,
            montantParToken:     montantParToken,
            snapshotSupply:      snapshotSupply,
            horodatageSnapshot:  block.timestamp,
            horodatageDistrib:   block.timestamp,
            typeDistrib:         typeDistrib,
            estFinalise:         false,
            empreinteDistrib:    empreinteDistrib
        });

        _nombreDistributions++;

        emit DistributionOuverte(
            idDistribution,
            typeDistrib,
            montantTotalEUR,
            montantParToken,
            snapshotSupply,
            block.timestamp
        );

        return idDistribution;
    }

    /// @notice Reclame les dividendes d'une distribution pour msg.sender
    /// @param idDistribution Identifiant de la distribution a reclamer
    /// @return montantEUR Montant de dividendes credites (EUR, 18 dec)
    ///
    /// @dev Calcul du montant eligible :
    ///   montant = soldeAuSnapshot × montantParToken / PRECISION
    ///   Note : on utilise le solde ACTUEL comme approximation du solde au snapshot.
    ///   En production, un mecanisme de snapshot (ERC-20Snapshot ou ERC-20Votes)
    ///   serait implemente pour capturer le solde exact a la date du snapshot.
    function reclamerDividendes(uint256 idDistribution)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 montantEUR)
    {
        // --- CHECKS ---
        require(idDistribution < _nombreDistributions, "ACTIF: Distribution inexistante");

        Distribution storage distrib = _distributions[idDistribution];
        require(!distrib.estFinalise, "ACTIF: Distribution finalisee - Plus de reclamations possibles");

        require(
            _registreDetenteurs[msg.sender].estDetenteurAutorise,
            "ACTIF: Detenteur non autorise"
        );
        require(
            !_registreDetenteurs[msg.sender].estGele,
            "ACTIF: Compte gele - Reclamation impossible"
        );
        require(
            _dividendesReclames[msg.sender][idDistribution] == 0,
            "ACTIF: Dividendes deja reclames pour cette distribution"
        );

        uint256 soldePourDistrib = _soldes[msg.sender];
        require(soldePourDistrib > 0, "ACTIF: Solde nul - Aucun dividende a reclamer");

        // --- EFFECTS ---
        // montant = solde × montantParToken / PRECISION
        montantEUR = soldePourDistrib.mulDiv(distrib.montantParToken, PRECISION);
        require(montantEUR > 0, "ACTIF: Montant de dividende trop faible (< 1 wei EUR)");

        _dividendesReclames[msg.sender][idDistribution] = montantEUR;
        _registreDetenteurs[msg.sender].dividendesAccumules += montantEUR;
        _registreDetenteurs[msg.sender].dateDerniereOperation = block.timestamp;

        emit DividendesReclames(msg.sender, idDistribution, montantEUR, block.timestamp);

        // Note : le paiement physique en EUR est effectue off-chain par l'operateur
        // de dividendes qui ecoute l'event DividendesReclames et effectue le virement.
        // Le contrat enregistre la creance (montantEUR) mais ne detient pas les EUR.

        return montantEUR;
    }

    // =========================================================================
    // MODULE 8 : VALORISATION
    // =========================================================================

    /// @notice Soumet un nouveau prix de marche pour cet actif
    /// @param nouveauPrix Prix unitaire en EUR (18 dec)
    ///
    /// @dev Circuit breaker : variation maximale de 20% par mise a jour.
    ///   Coherent avec le circuit breaker de FondTokenise.mettreAJourValeurActif().
    function soumettrePrixMarche(uint256 nouveauPrix)
        external
        onlyRole(ROLE_VALORISATEUR)
        whenNotPaused
    {
        require(nouveauPrix > 0, "ACTIF: Prix nul");

        // Circuit breaker : variation max 20%
        if (_prixMarche > 0) {
            uint256 variation;
            if (nouveauPrix > _prixMarche) {
                variation = (nouveauPrix - _prixMarche).mulDiv(BASE_POINTS, _prixMarche);
            } else {
                variation = (_prixMarche - nouveauPrix).mulDiv(BASE_POINTS, _prixMarche);
            }
            require(
                variation <= 2_000,
                "ACTIF: Variation de prix > 20% - Validation manuelle du valorisateur requise"
            );
        }

        uint256 ancienPrix = _prixMarche;
        _prixMarche        = nouveauPrix;
        _horodatageLastPrix = block.timestamp;

        _mettreAJourValorisationInterne();

        emit PrixMarcheMisAJour(
            ancienPrix,
            nouveauPrix,
            _valorisationTotale,
            msg.sender,
            block.timestamp
        );
    }

    /// @notice Synchronise la valorisation de cet actif avec la NAV du FondTokenise
    /// @dev Appelee par FondTokenise lors de la cloture d'un cycle NAV.
    ///   Le prix de marche de l'actif est mis a jour pour reflechir la NAV du fonds.
    ///   Cette synchronisation permet au Holding de consolider des valorisations coherentes.
    function synchroniserAvecFond(uint256 cycleNAV)
        external
        onlyRole(ROLE_FOND_AUTORISE)
        whenNotPaused
    {
        require(address(_fondTokenise) != address(0), "ACTIF: FondTokenise non configure");

        // Lecture de la NAV du fonds (appel view : pas de modification d'etat cote Fund)
        uint256 navFond = _fondTokenise.calculerNAV();
        require(navFond > 0, "ACTIF: NAV du fonds nulle");

        // La NAV du fonds devient le prix de reference de cet actif
        _prixMarche         = navFond;
        _horodatageLastPrix = block.timestamp;

        _mettreAJourValorisationInterne();

        emit SynchronisationFond(navFond, _prixMarche, cycleNAV, block.timestamp);
    }

    // =========================================================================
    // MODULE 9 : DOCUMENTS JURIDIQUES
    // =========================================================================

    /// @notice Publie un document juridique associe au titre
    /// @param typeDocument keccak256 du type (ex: keccak256("PROSPECTUS"), keccak256("STATUTS"))
    /// @param uri URI du document (HTTPS ou IPFS CID)
    /// @param hashContenu keccak256 du contenu du document (pour verification d'integrite)
    /// @param dateExpiration Timestamp d'expiration (0 = pas d'expiration)
    function publierDocument(
        bytes32 typeDocument,
        string  calldata uri,
        bytes32 hashContenu,
        uint256 dateExpiration
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
        whenNotPaused
    {
        require(typeDocument != bytes32(0),     "ACTIF: Type de document invalide");
        require(bytes(uri).length > 0,          "ACTIF: URI vide");
        require(hashContenu != bytes32(0),      "ACTIF: Hash du contenu vide");
        require(
            dateExpiration == 0 || dateExpiration > block.timestamp,
            "ACTIF: Date d'expiration deja passee"
        );

        // Ajout du nouveau type s'il n'existe pas encore
        bool typeConnu = false;
        for (uint256 i = 0; i < _typesDocuments.length; i++) {
            if (_typesDocuments[i] == typeDocument) {
                typeConnu = true;
                break;
            }
        }
        if (!typeConnu) {
            _typesDocuments.push(typeDocument);
        }

        _documents[typeDocument].push(DocumentJuridique({
            typeDocument:    typeDocument,
            uri:             uri,
            hashContenu:     hashContenu,
            datePublication: block.timestamp,
            dateExpiration:  dateExpiration,
            estValide:       true
        }));

        emit DocumentJuridiquePublie(typeDocument, uri, hashContenu, block.timestamp);
    }

    /// @notice Revoque un document juridique (ex: remplacement d'un prospectus)
    function revoquerDocument(
        bytes32 typeDocument,
        uint256 indexDocument,
        string  calldata motif
    )
        external
        onlyRole(ROLE_REGISTRAIRE)
    {
        require(indexDocument < _documents[typeDocument].length, "ACTIF: Index invalide");
        require(_documents[typeDocument][indexDocument].estValide, "ACTIF: Document deja revoque");

        _documents[typeDocument][indexDocument].estValide = false;

        emit DocumentJuridiqueRevoque(typeDocument, indexDocument, motif, block.timestamp);
    }

    // =========================================================================
    // MODULE 10 : GESTION DU SUPPLY MAXIMUM
    // =========================================================================

    /// @notice Met a jour la supply maximale autorisee (augmentation de capital)
    /// @param nouvelleSupplyMax Nouvelle supply maximale (0 = illimitee)
    ///
    /// @dev La supply maximale ne peut qu'augmenter (ou passer a 0).
    ///   Une diminution requiert une operation de rachat prealable.
    function mettreAJourSupplyMaximale(uint256 nouvelleSupplyMax)
        external
        onlyRole(ROLE_EMETTEUR)
    {
        require(
            nouvelleSupplyMax == 0 || nouvelleSupplyMax >= _supplyTotale,
            "ACTIF: Nouvelle supply max inferieure a la supply actuelle"
        );
        require(
            nouvelleSupplyMax == 0 || nouvelleSupplyMax >= _supplyMaximale,
            "ACTIF: Reduction de la supply maximale non autorisee"
        );

        uint256 ancienneSupply = _supplyMaximale;
        _supplyMaximale = nouvelleSupplyMax;

        emit SupplyMaximaleMisAJour(ancienneSupply, nouvelleSupplyMax, block.timestamp);
    }

    // =========================================================================
    // ADMINISTRATION
    // =========================================================================

    /// @notice Met a jour l'adresse du Toolbox
    function mettreAJourToolbox(address nouvelleAdresse) external onlyRole(ROLE_ADMIN) {
        require(nouvelleAdresse != address(0),         "ACTIF: Adresse invalide");
        require(nouvelleAdresse != address(_toolbox),  "ACTIF: Adresse identique");
        _toolbox = IToolboxActif(nouvelleAdresse);
    }

    /// @notice Met a jour l'adresse du FondTokenise
    function mettreAJourFond(address nouvelleAdresse) external onlyRole(ROLE_ADMIN) {
        require(nouvelleAdresse != address(0), "ACTIF: Adresse invalide");
        _fondTokenise = IFondTokenise(nouvelleAdresse);
        _grantRole(ROLE_FOND_AUTORISE, nouvelleAdresse);
    }

    /// @notice Met a jour l'URI du registre legal off-chain
    function mettreAJourAdresseRegistre(string calldata nouvelleUri)
        external
        onlyRole(ROLE_REGISTRAIRE)
    {
        require(bytes(nouvelleUri).length > 0, "ACTIF: URI vide");
        _metadonnees.adresseRegistre = nouvelleUri;
    }

    /// @notice Pause d'urgence du contrat
    function pauserContrat() external onlyRole(ROLE_ADMIN) {
        _pause();
        emit AlerteSecurite("Contrat ActifTokenise pause", msg.sender, block.timestamp);
    }

    /// @notice Reprise apres pause
    function reprendreContrat() external onlyRole(ROLE_ADMIN) {
        _unpause();
    }

    // =========================================================================
    // FONCTIONS DE LECTURE (VIEW) — AUDITABILITE
    // =========================================================================

    /// @notice Retourne le solde disponible (non bloque) d'un detenteur
    function soldeDisponible(address detenteur) external view returns (uint256) {
        return _soldes[detenteur] - _soldesBlockes[detenteur];
    }

    /// @notice Retourne le solde total (disponible + bloque) d'un detenteur
    function soldeTotale(address detenteur) external view returns (uint256) {
        return _soldes[detenteur];
    }

    /// @notice Retourne le solde bloque d'un detenteur
    function soldeBloque(address detenteur) external view returns (uint256) {
        return _soldesBlockes[detenteur];
    }

    /// @notice Retourne la supply totale en circulation
    function supplyTotale() external view returns (uint256) {
        return _supplyTotale;
    }

    /// @notice Retourne la supply maximale autorisee (0 = illimitee)
    function supplyMaximale() external view returns (uint256) {
        return _supplyMaximale;
    }

    /// @notice Retourne les metadonnees reglementaires du titre
    function lireMetadonnees() external view returns (MetadonneesTitre memory) {
        return _metadonnees;
    }

    /// @notice Retourne l'entree du registre d'un detenteur (acces auditeur)
    function lireEntreeDetenteur(address detenteur)
        external
        view
        onlyRole(ROLE_AUDITEUR)
        returns (EntreeDetenteur memory)
    {
        return _registreDetenteurs[detenteur];
    }

    /// @notice Retourne le detail d'une transaction enregistree
    function lireTransaction(bytes32 idTransaction)
        external
        view
        returns (Transaction memory)
    {
        return _historiqueTransactions[idTransaction];
    }

    /// @notice Retourne les details d'une distribution
    function lireDistribution(uint256 idDistribution)
        external
        view
        returns (Distribution memory)
    {
        require(idDistribution < _nombreDistributions, "ACTIF: Distribution inexistante");
        return _distributions[idDistribution];
    }

    /// @notice Retourne le montant de dividendes eligible pour un detenteur sur une distribution
    function lireDividendesEligibles(address detenteur, uint256 idDistribution)
        external
        view
        returns (uint256 montantEligible, bool dejaReclame)
    {
        require(idDistribution < _nombreDistributions, "ACTIF: Distribution inexistante");

        dejaReclame = (_dividendesReclames[detenteur][idDistribution] > 0);

        if (dejaReclame) {
            montantEligible = _dividendesReclames[detenteur][idDistribution];
        } else {
            Distribution storage distrib = _distributions[idDistribution];
            montantEligible = _soldes[detenteur].mulDiv(distrib.montantParToken, PRECISION);
        }
    }

    /// @notice Retourne les metriques globales de l'actif tokenise
    function lireMesuresActif()
        external
        view
        returns (
            string  memory isin,
            uint256 supplyTotaleVal,
            uint256 supplyMaximaleVal,
            uint256 prixMarche,
            uint256 valorisationTotale,
            uint256 nombreDetenteurs,
            uint256 nombreTransactions,
            uint256 nombreDistributions,
            bool    estPublie
        )
    {
        return (
            _metadonnees.isin,
            _supplyTotale,
            _supplyMaximale,
            _prixMarche,
            _valorisationTotale,
            _listeDetenteurs.length,
            _listeTransactions.length,
            _nombreDistributions,
            _estPublie
        );
    }

    /// @notice Retourne le dernier document valide d'un type donne
    function lireDernierDocument(bytes32 typeDocument)
        external
        view
        returns (DocumentJuridique memory)
    {
        DocumentJuridique[] storage docs = _documents[typeDocument];
        require(docs.length > 0, "ACTIF: Aucun document de ce type");

        // Recherche du dernier document valide (le plus recent)
        for (uint256 i = docs.length; i > 0; i--) {
            if (docs[i - 1].estValide) {
                return docs[i - 1];
            }
        }
        revert("ACTIF: Aucun document valide de ce type");
    }

    /// @notice Retourne l'allowance accordee a un operateur
    function lireAllowance(address proprietaire, address operateur)
        external
        view
        returns (uint256)
    {
        return _allowances[proprietaire][operateur];
    }

    /// @notice Verifie l'integrite de la chaine de transactions
    /// @param idTransaction Hash de la transaction a verifier
    /// @return integre True si l'empreinte de la transaction est coherente
    function verifierIntegriteTransaction(bytes32 idTransaction)
        external
        view
        returns (bool integre)
    {
        Transaction storage tx_ = _historiqueTransactions[idTransaction];
        require(tx_.horodatage > 0, "ACTIF: Transaction inconnue");

        bytes32 empreinteAttendue = keccak256(abi.encodePacked(
            tx_.expediteur,
            tx_.destinataire,
            tx_.quantite,
            tx_.prixUnitaire,
            tx_.montantTotal,
            tx_.horodatage,
            tx_.empreintePrec,
            address(this)
        ));

        integre = (idTransaction == empreinteAttendue);
    }

    /// @notice Retourne le nonce actuel d'un detenteur (prevention replay)
    function lireNonce(address detenteur) external view returns (uint256) {
        return _nonces[detenteur];
    }

    // =========================================================================
    // FONCTIONS INTERNES UTILITAIRES
    // =========================================================================

    /// @notice Execute le transfert interne de tokens entre deux detenteurs
    /// @dev Fonction interne commune a transfererAvecReference, transfererDepuis
    ///   et transfererForce. Applique toutes les mutations d'etat.
    function _executerTransfert(
        address expediteur,
        address destinataire,
        uint256 quantite,
        string  memory motif,
        bool    estForce
    ) internal returns (bytes32 idTransaction) {
        // --- EFFECTS ---
        _soldes[expediteur]  -= quantite;
        _soldes[destinataire] += quantite;

        // Mise a jour du registre expediteur
        EntreeDetenteur storage entreeExp  = _registreDetenteurs[expediteur];
        entreeExp.solde                   = _soldes[expediteur];
        entreeExp.dateDerniereOperation   = block.timestamp;
        entreeExp.nonce                  += 1;

        // Mise a jour du registre destinataire
        EntreeDetenteur storage entreeDest = _registreDetenteurs[destinataire];
        entreeDest.solde                  = _soldes[destinataire];
        entreeDest.dateDerniereOperation  = block.timestamp;
        entreeDest.nonce                 += 1;

        uint256 montantTotal = quantite.mulDiv(_prixMarche > 0 ? _prixMarche : _metadonnees.valeurNominaleParPart, PRECISION);

        idTransaction = _enregistrerTransaction(
            expediteur,
            destinataire,
            quantite,
            _prixMarche > 0 ? _prixMarche : _metadonnees.valeurNominaleParPart,
            montantTotal,
            estForce ? TypeTransaction.TRANSFERT_FORCE : TypeTransaction.TRANSFERT,
            motif
        );

        emit TransfertEffectue(
            expediteur,
            destinataire,
            quantite,
            _prixMarche,
            idTransaction,
            estForce,
            block.timestamp
        );

        return idTransaction;
    }

    /// @notice Enregistre une transaction dans l'historique immuable
    /// @dev Cree une empreinte chainee : chaque transaction contient le hash de la precedente.
    ///   Cela forme une chaine cryptographique qui garantit l'ordre et l'integrite
    ///   de toutes les transactions (similaire a une mini-blockchain dans la blockchain).
    ///   Si une transaction est modifiee, toutes les empreintes subsequentes deviennent invalides.
    function _enregistrerTransaction(
        address expediteur,
        address destinataire,
        uint256 quantite,
        uint256 prixUnitaire,
        uint256 montantTotal,
        TypeTransaction typeTransaction,
        string  memory motif
    ) internal returns (bytes32 idTransaction) {
        // L'ID de la transaction EST son empreinte cryptographique
        // => toute modification posterieure est immediatement detectable
        idTransaction = keccak256(abi.encodePacked(
            expediteur,
            destinataire,
            quantite,
            prixUnitaire,
            montantTotal,
            block.timestamp,
            _empreintePrec,   // Chaine avec la transaction precedente
            address(this)
        ));

        _historiqueTransactions[idTransaction] = Transaction({
            idTransaction:   idTransaction,
            expediteur:      expediteur,
            destinataire:    destinataire,
            quantite:        quantite,
            prixUnitaire:    prixUnitaire,
            montantTotal:    montantTotal,
            typeTransaction: typeTransaction,
            horodatage:      block.timestamp,
            referenceFond:   bytes32(0), // Rempli si lie a un cycle NAV du Fund
            motif:           motif,
            empreintePrec:   _empreintePrec
        ));

        _listeTransactions.push(idTransaction);

        // Mise a jour de la tete de chaine pour la prochaine transaction
        _empreintePrec = idTransaction;

        return idTransaction;
    }

    /// @notice Met a jour la valorisation totale interne
    /// @dev Appelée apres chaque changement de supply ou de prix
    function _mettreAJourValorisationInterne() internal {
        if (_prixMarche > 0 && _supplyTotale > 0) {
            _valorisationTotale = _supplyTotale.mulDiv(_prixMarche, PRECISION);
        } else if (_supplyTotale > 0) {
            // Fallback sur la valeur nominale si aucun prix de marche n'est disponible
            _valorisationTotale = _supplyTotale.mulDiv(_metadonnees.valeurNominaleParPart, PRECISION);
        } else {
            _valorisationTotale = 0;
        }
    }

    // =========================================================================
    // OVERRIDE supportsInterface (ERC-165)
    // =========================================================================
    // On surcharge uniquement AccessControl car c'est le seul ancetre qui
    // implementes ERC-165 (supportsInterface). Coherent avec FondTokenise v2.

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
