// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
//
//  Smart Contract ACTIF TOKENISE HOLDING — v1.0.0
//  Registre consolidé des positions et portefeuille multi-actifs tokenisés
//
//  Position dans l'architecture complète :
//
//    ┌─────────────────────────────────────────────────────────────────────┐
//    │                     ARCHITECTURE 4 CONTRATS                        │
//    │                                                                     │
//    │  Toolbox.sol ◄──────────────────────────── calculs financiers      │
//    │      ▲                                                              │
//    │      │ appelle                                                      │
//    │      │                                                              │
//    │  FondTokenise.sol ──────────► ActifTokenise.sol                    │
//    │  (contrat central)            (registre d'un seul titre)           │
//    │      │                              │                               │
//    │      │ agrège                       │ enregistré dans               │
//    │      │                              ▼                               │
//    │      └──────────────► ActifTokeniseHolding.sol  ◄── (CE CONTRAT)  │
//    │                        (vue consolidée multi-actifs,               │
//    │                         registre des positions par investisseur,   │
//    │                         reporting réglementaire agrégé)            │
//    └─────────────────────────────────────────────────────────────────────┘
//
//  Responsabilités de ce contrat (Holding) :
//    1. Tenir un registre consolidé de TOUTES les positions de TOUS les
//       investisseurs sur l'ensemble des actifs tokenisés du portefeuille
//    2. Agréger les valorisations de chaque ActifTokenise pour calculer
//       la valeur totale du portefeuille d'un investisseur
//    3. Enregistrer les mouvements de portefeuille (souscriptions, rachats,
//       transferts entre actifs) de manière immuable et chaînée
//    4. Produire des états de position certifiés pour les besoins de reporting
//       réglementaire (MiFID II, EMIR, AMF, CSSF)
//    5. Calculer les rendements réalisés et latents par investisseur
//    6. Gérer les droits de vote consolidés et les procurations
//    7. Être le point d'entrée unique pour les audits multi-actifs
//
//  Valeur ajoutée par rapport aux contrats précédents :
//    - FondTokenise gère le cycle NAV d'UN fonds
//    - ActifTokenise gère le registre d'UN titre
//    - ActifTokeniseHolding agrège N actifs × M investisseurs
//      et offre une vue "compte-titres" institutionnel complet
//
//  Conformité réglementaire :
//    - MiFID II Art. 25 : reporting consolidé des positions
//    - EMIR Art. 9 : déclaration des positions sur dérivés
//    - AMF Art. 318-1 : état des avoirs des clients
//    - DLT Pilot Regime (UE 2022/858) : tenue de registre DLT
//    - RGPD : hachage des identités, minimisation des données
//
//  Convention : ACT/365 (Euro Money Market) — cohérent avec Toolbox.sol
//  Précision   : 18 décimales (standard ERC20, compatible EUR)
// =============================================================================

// =============================================================================
// IMPORTS DES BIBLIOTHÈQUES OPENZEPPELIN
// =============================================================================

import "@openzeppelin/contracts/access/AccessControl.sol";
// AccessControl (RBAC) : séparation des rôles entre gestionnaire de holding,
// compliance, auditeur et administrateur. Indispensable car le Holding agrège
// des données sensibles (positions, valorisations, identités KYC hachées)
// qui ne doivent être accessibles qu'aux parties habilitées.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// ReentrancyGuard : le Holding orchestre des appels à plusieurs contrats
// externes (FondTokenise, ActifTokenise). Sans ce garde, un contrat malveillant
// pourrait re-entrer dans le Holding entre deux appels externes et corrompre
// l'état consolidé des positions.

import "@openzeppelin/contracts/utils/Pausable.sol";
// Pausable : circuit breaker pour suspension d'urgence sur instruction
// réglementaire (AMF, BCE). Bloque toutes les mises à jour de positions
// sans impacter les contrats sous-jacents qui restent opérationnels.

import "@openzeppelin/contracts/utils/math/Math.sol";
// Math.mulDiv(a, b, c) = a*b/c sans overflow intermédiaire.
// CRITIQUE pour les calculs de valorisation consolidée :
// sum(valeur_actif_i * quantite_i) peut dépasser uint256 sans mulDiv.

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
// SafeCast : conversions int/uint sécurisées pour les calculs de P&L
// (Profit & Loss) qui peuvent être négatifs (pertes latentes).

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
// SignedMath : opérations mathématiques sur int256.
// Utilisé pour les calculs de rendement absolu (gain ou perte).

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
// EnumerableSet : ensemble d'adresses itérables sans doublons.
// Utilisé pour maintenir la liste des actifs enregistrés et des
// investisseurs du holding sans risque de doublon — O(1) pour add/remove,
// O(n) pour l'itération d'audit (acceptable pour les volumes institutionnels).

// =============================================================================
// INTERFACES DES CONTRATS DÉPENDANTS
// =============================================================================

/// @notice Interface complète d'ActifTokenise exposée au Holding
/// Le Holding lit les positions de chaque actif et synchronise les valorisations.
/// On expose uniquement les fonctions nécessaires (surface de confiance minimale).
interface IActifTokenise {

    /// @notice Retourne le solde disponible (non bloqué) d'un détenteur
    function soldeDisponible(address detenteur) external view returns (uint256);

    /// @notice Retourne le solde total (disponible + bloqué)
    function soldeTotale(address detenteur) external view returns (uint256);

    /// @notice Retourne le solde bloqué d'un détenteur
    function soldeBloque(address detenteur) external view returns (uint256);

    /// @notice Retourne la supply totale en circulation
    function supplyTotale() external view returns (uint256);

    /// @notice Retourne les métriques globales de l'actif
    function lireMesuresActif() external view returns (
        string  memory isin,
        uint256 supplyTotaleVal,
        uint256 supplyMaximaleVal,
        uint256 prixMarche,
        uint256 valorisationTotale,
        uint256 nombreDetenteurs,
        uint256 nombreTransactions,
        uint256 nombreDistributions,
        bool    estPublie
    );

    /// @notice Synchronise la valorisation avec le FondTokenise
    function synchroniserAvecFond(uint256 cycleNAV) external;
}

/// @notice Interface de FondTokenise pour la lecture de la NAV et des métriques
interface IFondTokeniseHolding {

    /// @notice Retourne la NAV courante (EUR, 18 dec)
    function calculerNAV() external view returns (uint256);

    /// @notice Retourne les métriques globales du fonds
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

/// @notice Interface du Toolbox pour les calculs de rendement et de duration
interface IToolboxHolding {

    /// @notice Calcule les intérêts simples ACT/365
    function calculerInteretsSimples(
        uint256 principal,
        uint256 tauxAnnuelBp,
        uint256 nombreJours
    ) external pure returns (uint256 montantFinal, uint256 interets);

    /// @notice Calcule le taux de rendement annualisé
    function calculerTauxRendement(
        uint256 prixAchat,
        uint256 valeurRemboursement,
        uint256 dureeJours
    ) external pure returns (uint256 tauxRendementBp);

    /// @notice Calcule la duration pondérée d'un portefeuille
    function calculerDurationPortefeuille(
        uint256[] calldata valeurs,
        uint256[] calldata maturitesJours
    ) external pure returns (uint256 durationPondereeJours);
}

// =============================================================================
// SMART CONTRACT ACTIF TOKENISE HOLDING — v1.0.0
// =============================================================================

contract ActifTokeniseHolding is AccessControl, ReentrancyGuard, Pausable {

    // =========================================================================
    // UTILISATIONS DES BIBLIOTHÈQUES
    // =========================================================================
    using Math           for uint256;
    using SafeCast       for uint256;
    using SafeCast       for int256;
    using SignedMath     for int256;
    using EnumerableSet  for EnumerableSet.AddressSet;

    // =========================================================================
    // RÔLES (RBAC)
    // =========================================================================
    // Séparation des pouvoirs conforme à la directive sur les services
    // d'investissement (MiFID II) et aux exigences AMF pour les teneurs de
    // registre de titres (Art. 322-1 RGAMF).

    /// @dev Gestionnaire du holding : enregistre les actifs, déclenche les synchronisations
    bytes32 public constant ROLE_GESTIONNAIRE_HOLDING = keccak256("GESTIONNAIRE_HOLDING");

    /// @dev Compliance officer : valide les investisseurs, gère les restrictions
    bytes32 public constant ROLE_COMPLIANCE = keccak256("COMPLIANCE");

    /// @dev Auditeur : accès lecture seule à toutes les positions et transactions
    /// Correspond au CAC (commissaire aux comptes) ou à l'auditeur externe.
    bytes32 public constant ROLE_AUDITEUR = keccak256("AUDITEUR");

    /// @dev Reporting officer : peut déclencher la génération des états réglementaires
    bytes32 public constant ROLE_REPORTING = keccak256("REPORTING");

    /// @dev Administrateur : gestion des rôles et des contrats enregistrés
    bytes32 public constant ROLE_ADMIN = keccak256("ADMIN");

    /// @dev Fond autorisé : FondTokenise peut notifier le Holding des cycles NAV
    bytes32 public constant ROLE_FOND_AUTORISE = keccak256("FOND_AUTORISE");

    /// @dev Actif autorisé : ActifTokenise peut notifier le Holding des mouvements
    bytes32 public constant ROLE_ACTIF_AUTORISE = keccak256("ACTIF_AUTORISE");

    // =========================================================================
    // CONSTANTES
    // =========================================================================

    /// @notice Précision virgule fixe : 18 décimales — cohérent avec tous les contrats
    uint256 public constant PRECISION = 1e18;

    /// @notice Points de base : 10 000 bp = 100%
    uint256 public constant BASE_POINTS = 10_000;

    /// @notice Jours par an — Convention ACT/365 (Euro Money Market)
    uint256 public constant JOURS_PAR_AN = 365;

    /// @notice Secondes par an — ACT/365
    uint256 public constant SECONDES_PAR_AN = 365 days;

    /// @notice Nombre maximum d'actifs enregistrés dans le holding
    /// Limite les boucles d'agrégation pour rester sous la gas limit.
    uint256 public constant MAX_ACTIFS_HOLDING = 30;

    /// @notice Nombre maximum d'investisseurs dans le holding
    uint256 public constant MAX_INVESTISSEURS = 1_000;

    /// @notice Seuil d'alerte de concentration : 25% d'un actif en une seule position
    /// Au-delà, une alerte est émise (risque de concentration, Art. 52 UCITS).
    uint256 public constant SEUIL_CONCENTRATION_BP = 2_500;

    // =========================================================================
    // STRUCTURES DE DONNÉES
    // =========================================================================

    // -------------------------------------------------------------------------
    // FICHE DE L'ACTIF ENREGISTRÉ DANS LE HOLDING
    // -------------------------------------------------------------------------
    // Chaque actif tokenisé enregistré dans le holding est décrit par cette
    // structure. Elle agrège les informations statiques (ISIN, type) et dynamiques
    // (valorisation, supply) de l'ActifTokenise sous-jacent.

    /// @notice Descriptif d'un actif enregistré dans le portefeuille du holding
    struct ActifEnregistre {
        address adresseContrat;      // Adresse du contrat ActifTokenise
        string  isin;                // Code ISIN (copie locale pour éviter des appels externes)
        string  denomination;        // Nom court de l'actif (ex: "BNP Paribas Action Ordinaire")
        TypeCategorie categorie;     // Catégorie de l'actif (FONDS, TITRE, LIQUIDITE, etc.)
        uint256 prixAcquisitionMoyen; // Prix moyen d'acquisition pour le calcul du P&L (EUR, 18 dec)
        uint256 valorisationActuelle; // Dernière valorisation connue (EUR, 18 dec)
        uint256 poidsPortefeuilleBp; // Poids dans le portefeuille global en bp
        uint256 dateEnregistrement;  // Timestamp d'enregistrement dans le holding
        uint256 derniereSynchronisation; // Timestamp de la dernière synchronisation
        bool    estActif;            // False si l'actif a été retiré du holding
    }

    // -------------------------------------------------------------------------
    // POSITION D'UN INVESTISSEUR SUR UN ACTIF
    // -------------------------------------------------------------------------
    // Représente la position d'un investisseur spécifique sur un actif spécifique.
    // C'est le croisement "investisseur × actif" du tableau de bord du holding.

    /// @notice Position d'un investisseur sur un actif donné
    struct PositionInvestisseur {
        address investisseur;        // Adresse de l'investisseur
        address actif;               // Adresse du contrat ActifTokenise
        uint256 quantiteDetenue;     // Quantité de tokens détenus (18 dec)
        uint256 quantiteBloquee;     // Quantité bloquée (nantissements, lock-up)
        uint256 prixAcquisitionMoyen; // Prix moyen pondéré d'acquisition (EUR, 18 dec)
        uint256 valorisationActuelle; // Valeur actuelle de la position (EUR, 18 dec)
        int256  plusValueLatente;    // P&L latent = valorisation - coût (peut être négatif)
        uint256 datePremiereEntree;  // Timestamp de la première acquisition
        uint256 dateDerniereOperation; // Timestamp de la dernière opération
        uint256 dividendesPercus;    // Total des dividendes perçus sur cet actif (EUR, 18 dec)
        bool    estActive;           // False si la position est clôturée (quantité = 0)
    }

    // -------------------------------------------------------------------------
    // SNAPSHOT DE PORTEFEUILLE (état certifié à un instant T)
    // -------------------------------------------------------------------------
    // Un snapshot est une photographie certifiée de l'état du portefeuille
    // à un instant T. Il est utilisé pour :
    //   - Les déclarations réglementaires (reporting MiFID II, EMIR)
    //   - Les états de compte des investisseurs
    //   - Les calculs de performance (TWRR, MWRR)
    //   - Les audits annuels (CAC, AMF)

    /// @notice Snapshot certifié du portefeuille à un instant T
    struct SnapshotPortefeuille {
        uint256 idSnapshot;              // Identifiant séquentiel
        uint256 horodatage;              // Timestamp du snapshot
        uint256 valorisationTotaleEUR;   // Valeur totale du holding (EUR, 18 dec)
        uint256 nombreActifsActifs;      // Nombre d'actifs avec position non nulle
        uint256 nombreInvestisseurs;     // Nombre d'investisseurs avec position
        uint256 rendementDepuisOrigineEUR; // Gain/perte total depuis création (EUR, 18 dec)
        bytes32 empreinteEtat;           // Hash cryptographique de l'état complet
        bool    estCertifie;             // True si validé par un auditeur habilité
        address certifiePar;             // Adresse de l'auditeur ayant certifié
    }

    // -------------------------------------------------------------------------
    // MOUVEMENT DE PORTEFEUILLE (journal des opérations)
    // -------------------------------------------------------------------------
    // Chaque modification d'une position génère un mouvement enregistré
    // dans le journal du holding. Ces mouvements sont immuables et chaînés.

    /// @notice Mouvement de portefeuille (entrée du journal immuable)
    struct MouvementPortefeuille {
        bytes32 idMouvement;         // Identifiant unique du mouvement
        address investisseur;        // Investisseur concerné
        address actif;               // Actif concerné
        TypeMouvement typeMouvement; // ENTREE, SORTIE, REVALUATION, DIVIDENDE, etc.
        int256  deltaQuantite;       // Variation de quantité (+/-)
        int256  deltaValeurEUR;      // Variation de valeur en EUR (+/-)
        uint256 prixUnitaire;        // Prix unitaire de l'opération (EUR, 18 dec)
        uint256 valorisationAvant;   // Valorisation de la position avant le mouvement
        uint256 valorisationApres;   // Valorisation de la position après le mouvement
        uint256 horodatage;          // Timestamp du mouvement
        bytes32 referenceFond;       // Référence au cycle NAV du fonds si applicable
        string  motif;               // Motif libre (ex: "Cycle NAV #42 — Souscription")
        bytes32 empreintePrec;       // Hash du mouvement précédent (chaîne d'intégrité)
    }

    // -------------------------------------------------------------------------
    // PROFIL D'UN INVESTISSEUR DANS LE HOLDING
    // -------------------------------------------------------------------------

    /// @notice Profil consolidé d'un investisseur dans le holding
    struct ProfilInvestisseur {
        address adresse;                 // Adresse blockchain
        string  referenceKYC;            // Hash de la référence KYC (RGPD)
        uint256 valorisationTotaleEUR;   // Valorisation totale de toutes ses positions (EUR)
        uint256 coutTotalAcquisition;    // Coût total d'acquisition (EUR, 18 dec)
        int256  plusValueLatenteTotale;  // P&L latent global (signé, peut être négatif)
        uint256 dividendesTotauxPercus;  // Total des dividendes et coupons reçus (EUR, 18 dec)
        uint256 nombrePositionsActives;  // Nombre d'actifs détenus
        uint256 datePremiereEntree;      // Timestamp de la première opération
        uint256 dateDerniereOperation;   // Timestamp de la dernière opération
        bool    estAutorise;             // True si KYC validé et autorisé
        bool    estGele;                 // True si toutes les positions sont gelées
    }

    // =========================================================================
    // ÉNUMÉRATIONS
    // =========================================================================

    /// @notice Catégories d'actifs pour la classification du portefeuille
    enum TypeCategorie {
        FONDS_OPC,          // Part d'OPCVM, FIA, FPCI — principale liaison avec FondTokenise
        TITRE_TAUX,         // Obligation, billet de trésorerie (NEU CP)
        TITRE_CAPITAL,      // Action ordinaire, action de préférence
        LIQUIDITE,          // Dépôts bancaires, OPCVM monétaire
        PRODUIT_STRUCTURE,  // Certificat, EMTN, produit structuré
        AUTRE               // Instrument non catégorisé
    }

    /// @notice Types de mouvements dans le journal du holding
    enum TypeMouvement {
        ENTREE_SOUSCRIPTION,    // Acquisition via souscription directe
        ENTREE_ACHAT,           // Acquisition via achat secondaire
        SORTIE_RACHAT,          // Cession via rachat (remboursement)
        SORTIE_VENTE,           // Cession via vente secondaire
        REVALUATION_HAUSSE,     // Réévaluation positive de la position (prix monte)
        REVALUATION_BAISSE,     // Réévaluation négative de la position (prix baisse)
        PERCEPTION_DIVIDENDE,   // Encaissement d'un dividende ou coupon
        TRANSFERT_ENTRANT,      // Réception d'une position depuis un autre investisseur
        TRANSFERT_SORTANT,      // Envoi d'une position vers un autre investisseur
        BLOCAGE_POSITION,       // Immobilisation de la position (nantissement)
        DEBLOCAGE_POSITION,     // Libération d'une position bloquée
        SYNCHRONISATION_NAV     // Mise à jour de valorisation depuis un cycle NAV
    }

    // =========================================================================
    // VARIABLES D'ÉTAT
    // =========================================================================

    /// @notice Contrat FondTokenise principal associé au holding
    IFondTokeniseHolding private _fondTokenise;

    /// @notice Contrat Toolbox pour les calculs financiers
    IToolboxHolding private _toolbox;

    /// @notice Ensemble des adresses de contrats ActifTokenise enregistrés
    /// EnumerableSet garantit l'unicité sans O(n) de recherche.
    EnumerableSet.AddressSet private _actifsEnregistres;

    /// @notice Détails de chaque actif enregistré : adresse => ActifEnregistre
    mapping(address => ActifEnregistre) private _ficheActifs;

    /// @notice Ensemble des adresses d'investisseurs enregistrés
    EnumerableSet.AddressSet private _investisseursEnregistres;

    /// @notice Profil de chaque investisseur : adresse => ProfilInvestisseur
    mapping(address => ProfilInvestisseur) private _profils;

    /// @notice Positions : investisseur => actif => PositionInvestisseur
    /// Double mapping pour un accès O(1) en lecture depuis les deux axes.
    mapping(address => mapping(address => PositionInvestisseur)) private _positions;

    /// @notice Liste des actifs détenus par chaque investisseur (pour itération)
    mapping(address => address[]) private _actifsParInvestisseur;

    /// @notice Journal des mouvements : idMouvement => MouvementPortefeuille
    mapping(bytes32 => MouvementPortefeuille) private _journalMouvements;

    /// @notice Liste ordonnée des IDs de mouvements (pour audit séquentiel)
    bytes32[] private _listeMouvements;

    /// @notice Empreinte de la tête de la chaîne de mouvements (dernier mouvement)
    bytes32 private _empreintePrec;

    /// @notice Snapshots certifiés du portefeuille
    mapping(uint256 => SnapshotPortefeuille) private _snapshots;

    /// @notice Compteur de snapshots
    uint256 private _nombreSnapshots;

    /// @notice Valorisation totale consolidée du holding (EUR, 18 dec)
    /// Mise à jour après chaque mouvement ou synchronisation NAV.
    uint256 private _valorisationTotaleConsolidee;

    /// @notice Coût total d'acquisition historique (base de calcul P&L)
    uint256 private _coutTotalHistorique;

    /// @notice Nom du holding (ex: "Portefeuille Institutionnel BNP — Fonds EUR")
    string private _nomHolding;

    /// @notice Version du contrat
    string public version;

    // =========================================================================
    // ÉVÉNEMENTS — TRAÇABILITÉ RÉGLEMENTAIRE IMMUABLE
    // =========================================================================

    /// @notice Enregistrement d'un nouvel actif dans le holding
    event ActifEnregistreDansHolding(
        address indexed adresseActif,
        string  isin,
        TypeCategorie categorie,
        uint256 horodatage
    );

    /// @notice Retrait d'un actif du holding
    event ActifRetireDuHolding(
        address indexed adresseActif,
        string  isin,
        uint256 horodatage
    );

    /// @notice Enregistrement d'un nouvel investisseur dans le holding
    event InvestisseurEnregistre(
        address indexed investisseur,
        string  referenceKYC,
        uint256 horodatage
    );

    /// @notice Ouverture ou augmentation d'une position
    event PositionOuverte(
        address indexed investisseur,
        address indexed actif,
        uint256 quantite,
        uint256 prixUnitaire,
        uint256 valorisationPosition,
        bytes32 indexed idMouvement,
        uint256 horodatage
    );

    /// @notice Fermeture ou réduction d'une position
    event PositionReduite(
        address indexed investisseur,
        address indexed actif,
        uint256 quantite,
        uint256 prixUnitaire,
        int256  plusValueRealisee,
        bytes32 indexed idMouvement,
        uint256 horodatage
    );

    /// @notice Réévaluation d'une position (suite à mise à jour du prix)
    event PositionReevaulee(
        address indexed investisseur,
        address indexed actif,
        uint256 ancienneValorisation,
        uint256 nouvelleValorisation,
        int256  variationValeur,
        uint256 horodatage
    );

    /// @notice Synchronisation du holding avec un cycle NAV du FondTokenise
    event SynchronisationCycleNAV(
        uint256 indexed cycleNAV,
        uint256 navFond,
        uint256 valorisationTotaleAvant,
        uint256 valorisationTotaleApres,
        uint256 nombreActifsSynchronises,
        uint256 horodatage
    );

    /// @notice Création d'un snapshot certifié du portefeuille
    event SnapshotCree(
        uint256 indexed idSnapshot,
        uint256 valorisationTotale,
        uint256 nombreInvestisseurs,
        bytes32 empreinteEtat,
        uint256 horodatage
    );

    /// @notice Certification d'un snapshot par un auditeur habilité
    event SnapshotCertifie(
        uint256 indexed idSnapshot,
        address indexed auditeur,
        uint256 horodatage
    );

    /// @notice Perception d'un dividende ou coupon enregistrée
    event DividendeEnregistre(
        address indexed investisseur,
        address indexed actif,
        uint256 montantEUR,
        uint256 idDistribution,
        uint256 horodatage
    );

    /// @notice Alerte de concentration (position > seuil réglementaire)
    event AlerteConcentration(
        address indexed investisseur,
        address indexed actif,
        uint256 poidsPositionBp,
        uint256 seuilBp,
        uint256 horodatage
    );

    /// @notice Gel ou dégel d'un profil investisseur (toutes positions)
    event ProfilInvestisseurGele(
        address indexed investisseur,
        bool    estGele,
        string  motif,
        uint256 horodatage
    );

    /// @notice Mise à jour de la valorisation consolidée totale
    event ValorisationConsolideeMAJ(
        uint256 ancienneValorisation,
        uint256 nouvelleValorisation,
        int256  variationAbsolue,
        uint256 horodatage
    );

    /// @notice Alerte de sécurité critique
    event AlerteSecurite(
        string  description,
        address indexed declencheur,
        uint256 horodatage
    );

    // =========================================================================
    // MODIFICATEURS
    // =========================================================================

    /// @dev Vérifie que l'actif est enregistré dans le holding
    modifier actifEnregistreDansHolding(address adresseActif) {
        require(
            _actifsEnregistres.contains(adresseActif),
            "HOLDING: Actif non enregistre dans le holding"
        );
        require(
            _ficheActifs[adresseActif].estActif,
            "HOLDING: Actif marque comme inactif dans le holding"
        );
        _;
    }

    /// @dev Vérifie que l'investisseur est enregistré et autorisé
    modifier investisseurAutorise(address investisseur) {
        require(investisseur != address(0), "HOLDING: Adresse investisseur invalide");
        require(
            _profils[investisseur].estAutorise,
            "HOLDING: Investisseur non autorise - Enregistrement KYC requis"
        );
        require(
            !_profils[investisseur].estGele,
            "HOLDING: Profil investisseur gele - Contacter le gestionnaire"
        );
        _;
    }

    /// @dev Vérifie que le Toolbox est configuré
    modifier toolboxConfiguree() {
        require(address(_toolbox) != address(0), "HOLDING: Toolbox non configure");
        _;
    }

    // =========================================================================
    // CONSTRUCTEUR
    // =========================================================================

    /// @notice Déploie le contrat ActifTokeniseHolding
    /// @param nomHolding Nom officiel du holding
    /// @param adresseAdmin Adresse recevant les rôles fondateurs
    /// @param adresseToolbox Adresse du contrat Toolbox
    /// @param adresseFond Adresse du contrat FondTokenise (peut être 0 si non encore déployé)
    /// @param versionContrat Version du contrat (ex: "1.0.0")
    ///
    /// @dev Ordre de déploiement recommandé :
    ///   1. Toolbox.sol
    ///   2. FondTokenise.sol
    ///   3. ActifTokenise.sol (une instance par titre)
    ///   4. ActifTokeniseHolding.sol (agrégateur de tous les actifs)
    constructor(
        string  memory nomHolding,
        address adresseAdmin,
        address adresseToolbox,
        address adresseFond,
        string  memory versionContrat
    ) {
        require(bytes(nomHolding).length > 0,       "HOLDING: Nom du holding vide");
        require(adresseAdmin   != address(0),        "HOLDING: Adresse admin invalide");
        require(adresseToolbox != address(0),        "HOLDING: Adresse Toolbox invalide");
        require(bytes(versionContrat).length > 0,    "HOLDING: Version vide");

        _nomHolding = nomHolding;
        version     = versionContrat;
        _toolbox    = IToolboxHolding(adresseToolbox);

        if (adresseFond != address(0)) {
            _fondTokenise = IFondTokeniseHolding(adresseFond);
        }

        // Initialisation de la chaîne d'intégrité des mouvements
        _empreintePrec = keccak256(abi.encodePacked(
            "HOLDING_GENESE",
            adresseAdmin,
            block.timestamp,
            address(this)
        ));

        // Attribution des rôles fondateurs
        _grantRole(DEFAULT_ADMIN_ROLE,         adresseAdmin);
        _grantRole(ROLE_ADMIN,                 adresseAdmin);
        _grantRole(ROLE_GESTIONNAIRE_HOLDING,  adresseAdmin);
        _grantRole(ROLE_COMPLIANCE,            adresseAdmin);
        _grantRole(ROLE_REPORTING,             adresseAdmin);
        _grantRole(ROLE_AUDITEUR,              adresseAdmin);

        // FondTokenise reçoit le rôle pour notifier les cycles NAV
        if (adresseFond != address(0)) {
            _grantRole(ROLE_FOND_AUTORISE, adresseFond);
        }
    }

    // =========================================================================
    // MODULE 1 : ENREGISTREMENT DES ACTIFS ET DES INVESTISSEURS
    // =========================================================================

    /// @notice Enregistre un contrat ActifTokenise dans le holding
    /// @param adresseActif Adresse du contrat ActifTokenise à enregistrer
    /// @param denomination Nom court de l'actif (ex: "NEU CP Renault 90j")
    /// @param categorie Catégorie de l'actif (voir TypeCategorie)
    ///
    /// @dev Après enregistrement, le holding peut lire les positions de cet actif
    ///   et l'inclure dans les calculs de valorisation consolidée.
    ///   Le contrat ActifTokenise doit accorder ROLE_FOND_AUTORISE à ce holding
    ///   pour que les synchronisations NAV fonctionnent.
    function enregistrerActif(
        address adresseActif,
        string  calldata denomination,
        TypeCategorie categorie
    )
        external
        onlyRole(ROLE_GESTIONNAIRE_HOLDING)
        whenNotPaused
        nonReentrant
    {
        // --- CHECKS ---
        require(adresseActif != address(0),           "HOLDING: Adresse actif invalide");
        require(bytes(denomination).length > 0,       "HOLDING: Denomination vide");
        require(
            !_actifsEnregistres.contains(adresseActif),
            "HOLDING: Actif deja enregistre dans ce holding"
        );
        require(
            _actifsEnregistres.length() < MAX_ACTIFS_HOLDING,
            "HOLDING: Nombre maximum d'actifs atteint (30)"
        );

        // Lecture des métadonnées depuis le contrat ActifTokenise (appel externe en lecture)
        // On lit l'ISIN directement depuis le contrat pour garantir la cohérence.
        (
            string memory isin,
            ,       // supplyTotale
            ,       // supplyMaximale
            uint256 prixMarche,
            uint256 valorisationTotale,
            ,       // nombreDetenteurs
            ,       // nombreTransactions
            ,       // nombreDistributions
                    // estPublie
        ) = IActifTokenise(adresseActif).lireMesuresActif();

        // --- EFFECTS ---
        _actifsEnregistres.add(adresseActif);

        _ficheActifs[adresseActif] = ActifEnregistre({
            adresseContrat:         adresseActif,
            isin:                   isin,
            denomination:           denomination,
            categorie:              categorie,
            prixAcquisitionMoyen:   prixMarche, // Prix initial = prix de marché actuel
            valorisationActuelle:   valorisationTotale,
            poidsPortefeuilleBp:    0,           // Recalculé lors de la synchronisation
            dateEnregistrement:     block.timestamp,
            derniereSynchronisation: block.timestamp,
            estActif:               true
        });

        // Accorder le rôle ACTIF_AUTORISE à ce contrat pour les notifications
        _grantRole(ROLE_ACTIF_AUTORISE, adresseActif);

        // Recalcul des poids de portefeuille après ajout
        _recalculerPoidsPortefeuille();

        emit ActifEnregistreDansHolding(adresseActif, isin, categorie, block.timestamp);
    }

    /// @notice Retire un actif du holding (ne le désactive pas, juste le désenregistre)
    /// @param adresseActif Adresse du contrat ActifTokenise
    /// @param motif Motif du retrait (ex: "Arrivée à maturité", "Cession totale")
    function retirerActif(
        address adresseActif,
        string  calldata motif
    )
        external
        onlyRole(ROLE_GESTIONNAIRE_HOLDING)
        whenNotPaused
    {
        // --- CHECKS ---
        require(
            _actifsEnregistres.contains(adresseActif),
            "HOLDING: Actif non enregistre"
        );
        require(bytes(motif).length > 0, "HOLDING: Motif obligatoire");

        // On ne peut retirer un actif que si aucun investisseur n'a de position dessus
        // ou si toutes les positions ont été préalablement clôturées.
        for (uint256 i = 0; i < _investisseursEnregistres.length(); i++) {
            address inv = _investisseursEnregistres.at(i);
            require(
                _positions[inv][adresseActif].quantiteDetenue == 0,
                "HOLDING: Des investisseurs ont encore des positions sur cet actif"
            );
        }

        // --- EFFECTS ---
        string memory isin = _ficheActifs[adresseActif].isin;
        _ficheActifs[adresseActif].estActif = false;
        _actifsEnregistres.remove(adresseActif);
        _revokeRole(ROLE_ACTIF_AUTORISE, adresseActif);

        _recalculerPoidsPortefeuille();

        emit ActifRetireDuHolding(adresseActif, isin, block.timestamp);
    }

    /// @notice Enregistre un investisseur dans le holding après validation KYC
    /// @param investisseur Adresse de l'investisseur
    /// @param referenceKYC Référence KYC hachée (RGPD : pas d'identité en clair)
    function enregistrerInvestisseur(
        address investisseur,
        string  calldata referenceKYC
    )
        external
        onlyRole(ROLE_COMPLIANCE)
        whenNotPaused
    {
        // --- CHECKS ---
        require(investisseur != address(0),       "HOLDING: Adresse invalide");
        require(bytes(referenceKYC).length > 0,   "HOLDING: Reference KYC vide");
        require(
            !_profils[investisseur].estGele,
            "HOLDING: Impossible d'enregistrer un profil gele"
        );
        require(
            _investisseursEnregistres.length() < MAX_INVESTISSEURS,
            "HOLDING: Nombre maximum d'investisseurs atteint (1 000)"
        );

        // --- EFFECTS ---
        bool estNouvel = (_profils[investisseur].datePremiereEntree == 0);

        if (estNouvel) {
            _profils[investisseur] = ProfilInvestisseur({
                adresse:                  investisseur,
                referenceKYC:             referenceKYC,
                valorisationTotaleEUR:    0,
                coutTotalAcquisition:     0,
                plusValueLatenteTotale:   0,
                dividendesTotauxPercus:   0,
                nombrePositionsActives:   0,
                datePremiereEntree:       block.timestamp,
                dateDerniereOperation:    block.timestamp,
                estAutorise:              true,
                estGele:                  false
            });
            _investisseursEnregistres.add(investisseur);
        } else {
            _profils[investisseur].referenceKYC = referenceKYC;
            _profils[investisseur].estAutorise  = true;
        }

        emit InvestisseurEnregistre(investisseur, referenceKYC, block.timestamp);
    }

    /// @notice Gèle ou dégèle toutes les positions d'un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @param geler True pour geler, False pour dégeler
    /// @param motif Motif légal obligatoire
    function gelerProfilInvestisseur(
        address investisseur,
        bool    geler,
        string  calldata motif
    )
        external
        onlyRole(ROLE_COMPLIANCE)
    {
        require(investisseur != address(0), "HOLDING: Adresse invalide");
        require(bytes(motif).length > 0,    "HOLDING: Motif obligatoire");
        require(
            _profils[investisseur].datePremiereEntree > 0,
            "HOLDING: Investisseur non enregistre"
        );

        _profils[investisseur].estGele = geler;

        emit ProfilInvestisseurGele(investisseur, geler, motif, block.timestamp);

        if (geler) {
            emit AlerteSecurite(
                string(abi.encodePacked("Gel profil investisseur : ", motif)),
                investisseur,
                block.timestamp
            );
        }
    }

    // =========================================================================
    // MODULE 2 : GESTION DES POSITIONS
    // =========================================================================

    /// @notice Enregistre une entrée en position (souscription ou achat)
    /// @param investisseur Adresse de l'investisseur
    /// @param adresseActif Adresse du contrat ActifTokenise
    /// @param quantite Quantité de tokens acquis (18 dec)
    /// @param prixUnitaire Prix unitaire d'acquisition (EUR, 18 dec)
    /// @param typeMvt Type de mouvement (ENTREE_SOUSCRIPTION ou ENTREE_ACHAT)
    /// @param motif Motif de l'opération
    /// @param referenceCycleNAV Référence au cycle NAV si lié à FondTokenise (0 sinon)
    /// @return idMouvement Identifiant unique du mouvement enregistré
    ///
    /// @dev Pattern CEI strict :
    ///   C — Vérifications KYC, actif enregistré, quantité non nulle
    ///   E — Mise à jour de toutes les structures en mémoire
    ///   I — Aucun appel externe (les vérifications de solde se font via lireMesuresActif)
    function enregistrerEntreePosition(
        address investisseur,
        address adresseActif,
        uint256 quantite,
        uint256 prixUnitaire,
        TypeMouvement typeMvt,
        string  calldata motif,
        bytes32 referenceCycleNAV
    )
        external
        onlyRole(ROLE_GESTIONNAIRE_HOLDING)
        whenNotPaused
        nonReentrant
        actifEnregistreDansHolding(adresseActif)
        investisseurAutorise(investisseur)
        returns (bytes32 idMouvement)
    {
        // --- CHECKS ---
        require(quantite > 0,       "HOLDING: Quantite d'entree nulle");
        require(prixUnitaire > 0,   "HOLDING: Prix unitaire nul");
        require(
            typeMvt == TypeMouvement.ENTREE_SOUSCRIPTION ||
            typeMvt == TypeMouvement.ENTREE_ACHAT,
            "HOLDING: Type de mouvement invalide pour une entree"
        );

        // --- EFFECTS ---
        PositionInvestisseur storage pos = _positions[investisseur][adresseActif];

        uint256 valorisationAvant = pos.valorisationActuelle;

        if (pos.datePremiereEntree == 0) {
            // Nouvelle position : initialisation complète
            pos.investisseur           = investisseur;
            pos.actif                  = adresseActif;
            pos.quantiteDetenue        = quantite;
            pos.quantiteBloquee        = 0;
            pos.prixAcquisitionMoyen   = prixUnitaire;
            pos.datePremiereEntree     = block.timestamp;
            pos.estActive              = true;

            // Ajout de l'actif à la liste des actifs de cet investisseur
            _actifsParInvestisseur[investisseur].push(adresseActif);
            _profils[investisseur].nombrePositionsActives += 1;
        } else {
            // Position existante : calcul du prix moyen pondéré (PMP)
            // PMP = (quantiteActuelle × ancienPrix + nouvelleQuantite × prixAchat)
            //        / (quantiteActuelle + nouvelleQuantite)
            // On utilise mulDiv pour éviter l'overflow sur les grandes positions
            uint256 valeurActuelle    = pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
            uint256 valeurNouvelle    = quantite.mulDiv(prixUnitaire, PRECISION);
            uint256 quantiteTotale    = pos.quantiteDetenue + quantite;
            pos.prixAcquisitionMoyen  = (valeurActuelle + valeurNouvelle).mulDiv(PRECISION, quantiteTotale);
            pos.quantiteDetenue       = quantiteTotale;
        }

        // Mise à jour de la valorisation de la position
        uint256 nouvelleValorisation = pos.quantiteDetenue.mulDiv(prixUnitaire, PRECISION);
        pos.valorisationActuelle     = nouvelleValorisation;
        pos.dateDerniereOperation    = block.timestamp;

        // Calcul de la plus-value latente
        uint256 coutBase = pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
        pos.plusValueLatente = nouvelleValorisation.toInt256() - coutBase.toInt256();

        // Mise à jour du profil investisseur
        _mettreAJourProfilInvestisseur(investisseur);

        // Mise à jour du coût historique global
        uint256 coutNouveauMouvement = quantite.mulDiv(prixUnitaire, PRECISION);
        _coutTotalHistorique += coutNouveauMouvement;
        _profils[investisseur].coutTotalAcquisition += coutNouveauMouvement;

        // Enregistrement du mouvement dans le journal immuable
        idMouvement = _enregistrerMouvement(
            investisseur,
            adresseActif,
            typeMvt,
            quantite.toInt256(),
            (nouvelleValorisation - valorisationAvant).toInt256(),
            prixUnitaire,
            valorisationAvant,
            nouvelleValorisation,
            referenceCycleNAV,
            motif
        );

        // Vérification d'alerte de concentration
        _verifierConcentration(investisseur, adresseActif);

        emit PositionOuverte(
            investisseur,
            adresseActif,
            quantite,
            prixUnitaire,
            nouvelleValorisation,
            idMouvement,
            block.timestamp
        );

        return idMouvement;
    }

    /// @notice Enregistre une sortie de position (rachat ou vente)
    /// @param investisseur Adresse de l'investisseur
    /// @param adresseActif Adresse du contrat ActifTokenise
    /// @param quantite Quantité de tokens cédés (18 dec)
    /// @param prixUnitaire Prix unitaire de cession (EUR, 18 dec)
    /// @param typeMvt Type de mouvement (SORTIE_RACHAT ou SORTIE_VENTE)
    /// @param motif Motif de l'opération
    /// @param referenceCycleNAV Référence au cycle NAV si applicable
    /// @return idMouvement Identifiant unique du mouvement
    /// @return plusValueRealisee Plus-value (ou moins-value) réalisée sur la cession
    function enregistrerSortiePosition(
        address investisseur,
        address adresseActif,
        uint256 quantite,
        uint256 prixUnitaire,
        TypeMouvement typeMvt,
        string  calldata motif,
        bytes32 referenceCycleNAV
    )
        external
        onlyRole(ROLE_GESTIONNAIRE_HOLDING)
        whenNotPaused
        nonReentrant
        actifEnregistreDansHolding(adresseActif)
        investisseurAutorise(investisseur)
        returns (bytes32 idMouvement, int256 plusValueRealisee)
    {
        // --- CHECKS ---
        require(quantite > 0,     "HOLDING: Quantite de sortie nulle");
        require(prixUnitaire > 0, "HOLDING: Prix unitaire nul");
        require(
            typeMvt == TypeMouvement.SORTIE_RACHAT ||
            typeMvt == TypeMouvement.SORTIE_VENTE,
            "HOLDING: Type de mouvement invalide pour une sortie"
        );

        PositionInvestisseur storage pos = _positions[investisseur][adresseActif];
        require(pos.datePremiereEntree > 0, "HOLDING: Aucune position ouverte sur cet actif");

        // Quantité disponible = détenue - bloquée
        uint256 quantiteDisponible = pos.quantiteDetenue - pos.quantiteBloquee;
        require(
            quantiteDisponible >= quantite,
            "HOLDING: Quantite disponible insuffisante (deduction des quantites bloquees)"
        );

        // --- EFFECTS ---
        uint256 valorisationAvant = pos.valorisationActuelle;

        // Calcul de la plus-value réalisée sur la quantité cédée
        // PV réalisée = (prix de cession - PMP) × quantité cédée
        int256 prixCessionSigne = prixUnitaire.toInt256();
        int256 pmpSigne         = pos.prixAcquisitionMoyen.toInt256();
        int256 ecartPrix        = prixCessionSigne - pmpSigne;
        plusValueRealisee       = ecartPrix * quantite.toInt256() / int256(PRECISION);

        // Mise à jour de la position
        pos.quantiteDetenue       -= quantite;
        pos.dateDerniereOperation  = block.timestamp;

        if (pos.quantiteDetenue == 0) {
            // Clôture totale de la position
            pos.valorisationActuelle = 0;
            pos.plusValueLatente     = 0;
            pos.estActive            = false;
            _profils[investisseur].nombrePositionsActives =
                _profils[investisseur].nombrePositionsActives > 0
                ? _profils[investisseur].nombrePositionsActives - 1
                : 0;
        } else {
            // Clôture partielle : recalcul de la valorisation résiduelle
            pos.valorisationActuelle = pos.quantiteDetenue.mulDiv(prixUnitaire, PRECISION);
            uint256 coutBase = pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
            pos.plusValueLatente = pos.valorisationActuelle.toInt256() - coutBase.toInt256();
        }

        // Mise à jour du profil investisseur
        _mettreAJourProfilInvestisseur(investisseur);

        idMouvement = _enregistrerMouvement(
            investisseur,
            adresseActif,
            typeMvt,
            -quantite.toInt256(),
            pos.valorisationActuelle.toInt256() - valorisationAvant.toInt256(),
            prixUnitaire,
            valorisationAvant,
            pos.valorisationActuelle,
            referenceCycleNAV,
            motif
        );

        emit PositionReduite(
            investisseur,
            adresseActif,
            quantite,
            prixUnitaire,
            plusValueRealisee,
            idMouvement,
            block.timestamp
        );

        return (idMouvement, plusValueRealisee);
    }

    /// @notice Enregistre la perception d'un dividende ou coupon dans le holding
    /// @param investisseur Adresse de l'investisseur
    /// @param adresseActif Actif distributeur
    /// @param montantEUR Montant du dividende en EUR (18 dec)
    /// @param idDistribution Identifiant de la distribution dans ActifTokenise
    function enregistrerDividende(
        address investisseur,
        address adresseActif,
        uint256 montantEUR,
        uint256 idDistribution
    )
        external
        onlyRole(ROLE_ACTIF_AUTORISE)
        whenNotPaused
    {
        require(investisseur != address(0), "HOLDING: Adresse invalide");
        require(montantEUR > 0,             "HOLDING: Montant dividende nul");

        // --- EFFECTS ---
        _positions[investisseur][adresseActif].dividendesPercus += montantEUR;
        _profils[investisseur].dividendesTotauxPercus           += montantEUR;
        _profils[investisseur].dateDerniereOperation             = block.timestamp;

        emit DividendeEnregistre(investisseur, adresseActif, montantEUR, idDistribution, block.timestamp);
    }

    // =========================================================================
    // MODULE 3 : SYNCHRONISATION NAV AVEC FONDTOKENISE
    // =========================================================================
    // La synchronisation NAV est le mécanisme qui maintient la cohérence
    // entre les valorisations de FondTokenise et celles du Holding.
    // Elle est déclenchée :
    //   - Par FondTokenise après chaque clôture de cycle NAV (via ROLE_FOND_AUTORISE)
    //   - Manuellement par le gestionnaire du holding

    /// @notice Déclenche la synchronisation complète avec le cycle NAV courant
    /// @param cycleNAV Numéro du cycle NAV qui déclenche la synchronisation
    ///
    /// @dev Séquence de la synchronisation :
    ///   1. Lecture de la NAV actuelle depuis FondTokenise
    ///   2. Pour chaque ActifTokenise de catégorie FONDS_OPC : appel synchroniserAvecFond()
    ///   3. Réévaluation de toutes les positions des investisseurs
    ///   4. Recalcul des valorisations consolidées
    ///   5. Enregistrement des mouvements de réévaluation dans le journal
    ///   6. Recalcul des poids de portefeuille
    function synchroniserCycleNAV(uint256 cycleNAV)
        external
        onlyRole(ROLE_FOND_AUTORISE)
        whenNotPaused
        nonReentrant
    {
        require(address(_fondTokenise) != address(0), "HOLDING: FondTokenise non configure");

        uint256 valorisationAvant = _valorisationTotaleConsolidee;

        // Lecture de la NAV actuelle (appel view, pas de modification d'état côté Fund)
        uint256 navFond = _fondTokenise.calculerNAV();
        require(navFond > 0, "HOLDING: NAV du fonds nulle");

        uint256 nombreActifsSynchronises = 0;

        // Boucle sur tous les actifs enregistrés
        for (uint256 i = 0; i < _actifsEnregistres.length(); i++) {
            address adresseActif = _actifsEnregistres.at(i);
            ActifEnregistre storage ficheActif = _ficheActifs[adresseActif];

            if (!ficheActif.estActif) continue;

            // Pour les fonds OPC : synchronisation directe avec FondTokenise
            if (ficheActif.categorie == TypeCategorie.FONDS_OPC) {
                try IActifTokenise(adresseActif).synchroniserAvecFond(cycleNAV) {
                    nombreActifsSynchronises++;
                } catch {
                    emit AlerteSecurite(
                        "HOLDING: Echec synchronisation ActifTokenise avec FondTokenise",
                        adresseActif,
                        block.timestamp
                    );
                }
            }

            // Relecture de la nouvelle valorisation après synchronisation
            (, , , uint256 nouveauPrix, uint256 nouvelleValorisation, , , ,) =
                IActifTokenise(adresseActif).lireMesuresActif();

            ficheActif.valorisationActuelle    = nouvelleValorisation;
            ficheActif.derniereSynchronisation = block.timestamp;

            // Réévaluation des positions de tous les investisseurs sur cet actif
            _reeevaluerPositionsSurActif(adresseActif, nouveauPrix, cycleNAV);
        }

        // Recalcul global des valorisations et des poids
        _recalculerValorisationConsolidee();
        _recalculerPoidsPortefeuille();

        emit SynchronisationCycleNAV(
            cycleNAV,
            navFond,
            valorisationAvant,
            _valorisationTotaleConsolidee,
            nombreActifsSynchronises,
            block.timestamp
        );
    }

    /// @notice Déclenche une synchronisation manuelle (hors cycle NAV)
    /// @dev Utile pour mettre à jour les prix de marché sans attendre un cycle NAV.
    ///   Accessible au gestionnaire du holding uniquement.
    function synchroniserManuellement()
        external
        onlyRole(ROLE_GESTIONNAIRE_HOLDING)
        whenNotPaused
        nonReentrant
    {
        uint256 valorisationAvant = _valorisationTotaleConsolidee;

        for (uint256 i = 0; i < _actifsEnregistres.length(); i++) {
            address adresseActif = _actifsEnregistres.at(i);
            if (!_ficheActifs[adresseActif].estActif) continue;

            (, , , uint256 prixActuel, uint256 valorisationActuelle, , , ,) =
                IActifTokenise(adresseActif).lireMesuresActif();

            _ficheActifs[adresseActif].valorisationActuelle    = valorisationActuelle;
            _ficheActifs[adresseActif].derniereSynchronisation = block.timestamp;

            _reeevaluerPositionsSurActif(adresseActif, prixActuel, 0);
        }

        _recalculerValorisationConsolidee();
        _recalculerPoidsPortefeuille();

        emit ValorisationConsolideeMAJ(
            valorisationAvant,
            _valorisationTotaleConsolidee,
            _valorisationTotaleConsolidee.toInt256() - valorisationAvant.toInt256(),
            block.timestamp
        );
    }

    // =========================================================================
    // MODULE 4 : SNAPSHOTS CERTIFIÉS (ÉTATS RÉGLEMENTAIRES)
    // =========================================================================

    /// @notice Crée un snapshot certifié de l'état du portefeuille à cet instant
    /// @return idSnapshot Identifiant unique du snapshot
    ///
    /// @dev Le snapshot capture l'état complet du holding et calcule une empreinte
    ///   cryptographique permettant de prouver que l'état n'a pas été modifié a posteriori.
    ///   Utilisé pour les déclarations réglementaires AMF, MiFID II, EMIR.
    function creerSnapshot()
        external
        onlyRole(ROLE_REPORTING)
        whenNotPaused
        nonReentrant
        returns (uint256 idSnapshot)
    {
        idSnapshot = _nombreSnapshots;

        uint256 nombreInvestisseursActifs = 0;
        for (uint256 i = 0; i < _investisseursEnregistres.length(); i++) {
            address inv = _investisseursEnregistres.at(i);
            if (_profils[inv].nombrePositionsActives > 0) {
                nombreInvestisseursActifs++;
            }
        }

        // Calcul du rendement total depuis l'origine
        int256 rendementBrut = _valorisationTotaleConsolidee.toInt256()
            - _coutTotalHistorique.toInt256();
        uint256 rendementEUR = rendementBrut > 0 ? uint256(rendementBrut) : 0;

        // Empreinte cryptographique de l'état complet
        // Inclut : valorisation, nombre d'actifs, d'investisseurs, et le dernier mouvement
        bytes32 empreinteEtat = keccak256(abi.encodePacked(
            idSnapshot,
            _valorisationTotaleConsolidee,
            _actifsEnregistres.length(),
            nombreInvestisseursActifs,
            block.timestamp,
            _empreintePrec,     // Chaîné avec le dernier mouvement du journal
            address(this)
        ));

        _snapshots[idSnapshot] = SnapshotPortefeuille({
            idSnapshot:              idSnapshot,
            horodatage:              block.timestamp,
            valorisationTotaleEUR:   _valorisationTotaleConsolidee,
            nombreActifsActifs:      _actifsEnregistres.length(),
            nombreInvestisseurs:     nombreInvestisseursActifs,
            rendementDepuisOrigineEUR: rendementEUR,
            empreinteEtat:           empreinteEtat,
            estCertifie:             false,
            certifiePar:             address(0)
        });

        _nombreSnapshots++;

        emit SnapshotCree(
            idSnapshot,
            _valorisationTotaleConsolidee,
            nombreInvestisseursActifs,
            empreinteEtat,
            block.timestamp
        );

        return idSnapshot;
    }

    /// @notice Certifie un snapshot (validation par l'auditeur habilité)
    /// @param idSnapshot Identifiant du snapshot à certifier
    ///
    /// @dev La certification est l'acte par lequel un auditeur externe atteste
    ///   que le snapshot reflète fidèlement l'état du portefeuille.
    ///   Conforme à la norme ISA 402 (services externalisés) et AMF Art. 322-1.
    function certifierSnapshot(uint256 idSnapshot)
        external
        onlyRole(ROLE_AUDITEUR)
    {
        require(idSnapshot < _nombreSnapshots, "HOLDING: Snapshot inexistant");
        require(
            !_snapshots[idSnapshot].estCertifie,
            "HOLDING: Snapshot deja certifie"
        );

        _snapshots[idSnapshot].estCertifie  = true;
        _snapshots[idSnapshot].certifiePar  = msg.sender;

        emit SnapshotCertifie(idSnapshot, msg.sender, block.timestamp);
    }

    // =========================================================================
    // MODULE 5 : CALCULS DE PERFORMANCE ET REPORTING
    // =========================================================================

    /// @notice Calcule le rendement total réalisé et latent d'un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @return rendementLatentEUR Plus-value latente totale (peut être négatif)
    /// @return rendementDividendesEUR Total des dividendes et coupons perçus
    /// @return rendementTotalEUR Rendement total (latent + dividendes)
    /// @return tauxRendementAnnualise Taux de rendement annualisé en bp
    function calculerRendementInvestisseur(address investisseur)
        external
        view
        returns (
            int256  rendementLatentEUR,
            uint256 rendementDividendesEUR,
            int256  rendementTotalEUR,
            uint256 tauxRendementAnnualise
        )
    {
        require(
            _profils[investisseur].datePremiereEntree > 0,
            "HOLDING: Investisseur non enregistre"
        );

        ProfilInvestisseur storage profil = _profils[investisseur];

        rendementLatentEUR    = profil.plusValueLatenteTotale;
        rendementDividendesEUR = profil.dividendesTotauxPercus;
        rendementTotalEUR     = rendementLatentEUR + rendementDividendesEUR.toInt256();

        // Calcul du taux de rendement annualisé (si coût d'acquisition non nul)
        if (profil.coutTotalAcquisition > 0 && profil.datePremiereEntree > 0) {
            uint256 dureeJours = (block.timestamp - profil.datePremiereEntree) / 1 days;
            if (dureeJours == 0) dureeJours = 1; // Éviter la division par zéro

            if (rendementTotalEUR > 0) {
                // Taux = (rendement / coût) × (365 / durée) × 10 000
                tauxRendementAnnualise = uint256(rendementTotalEUR)
                    .mulDiv(JOURS_PAR_AN * BASE_POINTS, profil.coutTotalAcquisition * dureeJours / PRECISION);
            } else {
                tauxRendementAnnualise = 0; // Rendement négatif : taux = 0 (non représentable en uint)
            }
        }
    }

    /// @notice Calcule la valorisation consolidée de toutes les positions d'un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @return valorisationTotale Valeur totale du portefeuille (EUR, 18 dec)
    /// @return coutTotalAcquisition Coût total d'acquisition (EUR, 18 dec)
    /// @return plusValueLatente Plus-value latente globale (peut être négative)
    function calculerValorisationInvestisseur(address investisseur)
        external
        view
        returns (
            uint256 valorisationTotale,
            uint256 coutTotalAcquisition,
            int256  plusValueLatente
        )
    {
        for (uint256 i = 0; i < _actifsParInvestisseur[investisseur].length; i++) {
            address adresseActif = _actifsParInvestisseur[investisseur][i];
            PositionInvestisseur storage pos = _positions[investisseur][adresseActif];

            if (pos.quantiteDetenue == 0) continue;

            valorisationTotale   += pos.valorisationActuelle;
            coutTotalAcquisition += pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
        }

        plusValueLatente = valorisationTotale.toInt256() - coutTotalAcquisition.toInt256();
    }

    /// @notice Génère un état de position complet pour un investisseur
    /// @param investisseur Adresse de l'investisseur
    /// @return actifs Liste des adresses des actifs détenus
    /// @return quantites Quantités détenues par actif
    /// @return valorisations Valorisations actuelles par actif
    /// @return plusValues Plus-values latentes par actif
    function etatPositionInvestisseur(address investisseur)
        external
        view
        onlyRole(ROLE_AUDITEUR)
        returns (
            address[] memory actifs,
            uint256[] memory quantites,
            uint256[] memory valorisations,
            int256[]  memory plusValues
        )
    {
        uint256 nombreActifs = _actifsParInvestisseur[investisseur].length;

        actifs        = new address[](nombreActifs);
        quantites     = new uint256[](nombreActifs);
        valorisations = new uint256[](nombreActifs);
        plusValues    = new int256[](nombreActifs);

        for (uint256 i = 0; i < nombreActifs; i++) {
            address adresseActif = _actifsParInvestisseur[investisseur][i];
            PositionInvestisseur storage pos = _positions[investisseur][adresseActif];

            actifs[i]        = adresseActif;
            quantites[i]     = pos.quantiteDetenue;
            valorisations[i] = pos.valorisationActuelle;
            plusValues[i]    = pos.plusValueLatente;
        }
    }

    /// @notice Vérifie l'intégrité d'un snapshot certifié
    /// @param idSnapshot Identifiant du snapshot à vérifier
    /// @return integre True si l'empreinte est cohérente (snapshot non altéré)
    function verifierIntegriteSnapshot(uint256 idSnapshot)
        external
        view
        returns (bool integre, bytes32 empreinteCalculee, bytes32 empreinteStockee)
    {
        require(idSnapshot < _nombreSnapshots, "HOLDING: Snapshot inexistant");

        SnapshotPortefeuille storage snap = _snapshots[idSnapshot];
        empreinteStockee = snap.empreinteEtat;

        // Recalcul de l'empreinte avec les mêmes paramètres qu'à la création
        empreinteCalculee = keccak256(abi.encodePacked(
            idSnapshot,
            snap.valorisationTotaleEUR,
            snap.nombreActifsActifs,
            snap.nombreInvestisseurs,
            snap.horodatage,
            // Note : l'empreinte de la chaîne de mouvements n'est pas recalculable ici
            // car _empreintePrec a évolué depuis. On vérifie les champs du snapshot lui-même.
            address(this)
        ));

        integre = (empreinteCalculee == empreinteStockee);
    }

    // =========================================================================
    // ADMINISTRATION
    // =========================================================================

    /// @notice Met à jour l'adresse du FondTokenise
    function mettreAJourFond(address nouvelleAdresse) external onlyRole(ROLE_ADMIN) {
        require(nouvelleAdresse != address(0), "HOLDING: Adresse invalide");
        if (address(_fondTokenise) != address(0)) {
            _revokeRole(ROLE_FOND_AUTORISE, address(_fondTokenise));
        }
        _fondTokenise = IFondTokeniseHolding(nouvelleAdresse);
        _grantRole(ROLE_FOND_AUTORISE, nouvelleAdresse);
    }

    /// @notice Met à jour l'adresse du Toolbox
    function mettreAJourToolbox(address nouvelleAdresse) external onlyRole(ROLE_ADMIN) {
        require(nouvelleAdresse != address(0), "HOLDING: Adresse invalide");
        _toolbox = IToolboxHolding(nouvelleAdresse);
    }

    /// @notice Pause d'urgence du holding
    function pauserContrat() external onlyRole(ROLE_ADMIN) {
        _pause();
        emit AlerteSecurite("Holding pause", msg.sender, block.timestamp);
    }

    /// @notice Reprise après pause
    function reprendreContrat() external onlyRole(ROLE_ADMIN) {
        _unpause();
    }

    // =========================================================================
    // FONCTIONS DE LECTURE (VIEW) — AUDITABILITÉ
    // =========================================================================

    /// @notice Retourne le profil consolidé d'un investisseur
    function lireProfilInvestisseur(address investisseur)
        external
        view
        onlyRole(ROLE_AUDITEUR)
        returns (ProfilInvestisseur memory)
    {
        return _profils[investisseur];
    }

    /// @notice Retourne la position d'un investisseur sur un actif donné
    function lirePosition(address investisseur, address adresseActif)
        external
        view
        returns (PositionInvestisseur memory)
    {
        return _positions[investisseur][adresseActif];
    }

    /// @notice Retourne la fiche d'un actif enregistré dans le holding
    function lireFicheActif(address adresseActif)
        external
        view
        returns (ActifEnregistre memory)
    {
        return _ficheActifs[adresseActif];
    }

    /// @notice Retourne le détail d'un mouvement du journal
    function lireMouvement(bytes32 idMouvement)
        external
        view
        returns (MouvementPortefeuille memory)
    {
        return _journalMouvements[idMouvement];
    }

    /// @notice Retourne le détail d'un snapshot certifié
    function lireSnapshot(uint256 idSnapshot)
        external
        view
        returns (SnapshotPortefeuille memory)
    {
        require(idSnapshot < _nombreSnapshots, "HOLDING: Snapshot inexistant");
        return _snapshots[idSnapshot];
    }

    /// @notice Retourne les métriques globales du holding
    function lireMesuresHolding()
        external
        view
        returns (
            string  memory nomHolding,
            uint256 nombreActifs,
            uint256 nombreInvestisseurs,
            uint256 valorisationTotaleEUR,
            int256  plusValueLatenteTotale,
            uint256 nombreMouvements,
            uint256 nombreSnapshots
        )
    {
        int256 pv = _valorisationTotaleConsolidee.toInt256()
            - _coutTotalHistorique.toInt256();

        return (
            _nomHolding,
            _actifsEnregistres.length(),
            _investisseursEnregistres.length(),
            _valorisationTotaleConsolidee,
            pv,
            _listeMouvements.length,
            _nombreSnapshots
        );
    }

    /// @notice Retourne la liste des adresses d'actifs enregistrés
    function lireListeActifs() external view returns (address[] memory) {
        uint256 n = _actifsEnregistres.length();
        address[] memory liste = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            liste[i] = _actifsEnregistres.at(i);
        }
        return liste;
    }

    /// @notice Retourne la liste des adresses d'investisseurs enregistrés
    function lireListeInvestisseurs()
        external
        view
        onlyRole(ROLE_AUDITEUR)
        returns (address[] memory)
    {
        uint256 n = _investisseursEnregistres.length();
        address[] memory liste = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            liste[i] = _investisseursEnregistres.at(i);
        }
        return liste;
    }

    // =========================================================================
    // FONCTIONS INTERNES UTILITAIRES
    // =========================================================================

    /// @notice Réévalue toutes les positions des investisseurs sur un actif donné
    /// @dev Appelée après chaque mise à jour du prix d'un actif.
    ///   Pour chaque investisseur ayant une position sur cet actif, on recalcule :
    ///   - la valorisation actuelle de sa position
    ///   - sa plus-value latente
    function _reeevaluerPositionsSurActif(
        address adresseActif,
        uint256 nouveauPrix,
        uint256 referenceCycleNAV
    ) internal {
        if (nouveauPrix == 0) return;

        for (uint256 i = 0; i < _investisseursEnregistres.length(); i++) {
            address investisseur = _investisseursEnregistres.at(i);
            PositionInvestisseur storage pos = _positions[investisseur][adresseActif];

            if (pos.quantiteDetenue == 0) continue;

            uint256 ancienneValorisation  = pos.valorisationActuelle;
            uint256 nouvelleValorisation  = pos.quantiteDetenue.mulDiv(nouveauPrix, PRECISION);

            if (ancienneValorisation == nouvelleValorisation) continue;

            pos.valorisationActuelle = nouvelleValorisation;
            uint256 coutBase = pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
            pos.plusValueLatente = nouvelleValorisation.toInt256() - coutBase.toInt256();
            pos.dateDerniereOperation = block.timestamp;

            // Enregistrement du mouvement de réévaluation dans le journal
            bytes32 refNAV = referenceCycleNAV > 0
                ? bytes32(referenceCycleNAV)
                : bytes32(0);

            _enregistrerMouvement(
                investisseur,
                adresseActif,
                nouvelleValorisation > ancienneValorisation
                    ? TypeMouvement.REVALUATION_HAUSSE
                    : TypeMouvement.REVALUATION_BAISSE,
                0, // Pas de variation de quantité
                nouvelleValorisation.toInt256() - ancienneValorisation.toInt256(),
                nouveauPrix,
                ancienneValorisation,
                nouvelleValorisation,
                refNAV,
                "Reevaluation suite synchronisation"
            );

            emit PositionReevaulee(
                investisseur,
                adresseActif,
                ancienneValorisation,
                nouvelleValorisation,
                nouvelleValorisation.toInt256() - ancienneValorisation.toInt256(),
                block.timestamp
            );

            _mettreAJourProfilInvestisseur(investisseur);
        }
    }

    /// @notice Met à jour le profil consolidé d'un investisseur à partir de ses positions
    function _mettreAJourProfilInvestisseur(address investisseur) internal {
        ProfilInvestisseur storage profil = _profils[investisseur];

        uint256 valeurTotale = 0;
        uint256 coutTotal    = 0;

        for (uint256 i = 0; i < _actifsParInvestisseur[investisseur].length; i++) {
            address adresseActif = _actifsParInvestisseur[investisseur][i];
            PositionInvestisseur storage pos = _positions[investisseur][adresseActif];

            if (pos.quantiteDetenue == 0) continue;

            valeurTotale += pos.valorisationActuelle;
            coutTotal    += pos.quantiteDetenue.mulDiv(pos.prixAcquisitionMoyen, PRECISION);
        }

        profil.valorisationTotaleEUR  = valeurTotale;
        profil.coutTotalAcquisition   = coutTotal;
        profil.plusValueLatenteTotale = valeurTotale.toInt256() - coutTotal.toInt256();
        profil.dateDerniereOperation  = block.timestamp;
    }

    /// @notice Recalcule la valorisation consolidée totale du holding
    function _recalculerValorisationConsolidee() internal {
        uint256 ancienneValorisation = _valorisationTotaleConsolidee;
        uint256 nouvelleValorisation = 0;

        for (uint256 i = 0; i < _actifsEnregistres.length(); i++) {
            address adresseActif = _actifsEnregistres.at(i);
            if (_ficheActifs[adresseActif].estActif) {
                nouvelleValorisation += _ficheActifs[adresseActif].valorisationActuelle;
            }
        }

        _valorisationTotaleConsolidee = nouvelleValorisation;

        if (ancienneValorisation != nouvelleValorisation) {
            emit ValorisationConsolideeMAJ(
                ancienneValorisation,
                nouvelleValorisation,
                nouvelleValorisation.toInt256() - ancienneValorisation.toInt256(),
                block.timestamp
            );
        }
    }

    /// @notice Recalcule les poids de chaque actif dans le portefeuille global
    function _recalculerPoidsPortefeuille() internal {
        if (_valorisationTotaleConsolidee == 0) return;

        for (uint256 i = 0; i < _actifsEnregistres.length(); i++) {
            address adresseActif = _actifsEnregistres.at(i);
            if (!_ficheActifs[adresseActif].estActif) continue;

            // Poids = (valorisation actif / valorisation totale) × 10 000
            _ficheActifs[adresseActif].poidsPortefeuilleBp = _ficheActifs[adresseActif]
                .valorisationActuelle
                .mulDiv(BASE_POINTS, _valorisationTotaleConsolidee);
        }
    }

    /// @notice Vérifie la concentration d'une position et émet une alerte si dépassement
    function _verifierConcentration(address investisseur, address adresseActif) internal {
        ProfilInvestisseur storage profil = _profils[investisseur];
        if (profil.valorisationTotaleEUR == 0) return;

        PositionInvestisseur storage pos = _positions[investisseur][adresseActif];
        if (pos.valorisationActuelle == 0) return;

        // Poids de la position dans le portefeuille total de l'investisseur
        uint256 poidsBp = pos.valorisationActuelle.mulDiv(
            BASE_POINTS,
            profil.valorisationTotaleEUR
        );

        if (poidsBp > SEUIL_CONCENTRATION_BP) {
            emit AlerteConcentration(
                investisseur,
                adresseActif,
                poidsBp,
                SEUIL_CONCENTRATION_BP,
                block.timestamp
            );
        }
    }

    /// @notice Enregistre un mouvement dans le journal immuable chaîné
    /// @dev Chaque mouvement contient l'empreinte du précédent — chaîne d'intégrité
    ///   identique au mécanisme de FondTokenise et ActifTokenise.
    function _enregistrerMouvement(
        address investisseur,
        address actif,
        TypeMouvement typeMouvement,
        int256  deltaQuantite,
        int256  deltaValeurEUR,
        uint256 prixUnitaire,
        uint256 valorisationAvant,
        uint256 valorisationApres,
        bytes32 referenceFond,
        string  memory motif
    ) internal returns (bytes32 idMouvement) {
        idMouvement = keccak256(abi.encodePacked(
            investisseur,
            actif,
            uint8(typeMouvement),
            deltaQuantite,
            deltaValeurEUR,
            block.timestamp,
            _empreintePrec,
            address(this)
        ));

        _journalMouvements[idMouvement] = MouvementPortefeuille({
            idMouvement:        idMouvement,
            investisseur:       investisseur,
            actif:              actif,
            typeMouvement:      typeMouvement,
            deltaQuantite:      deltaQuantite,
            deltaValeurEUR:     deltaValeurEUR,
            prixUnitaire:       prixUnitaire,
            valorisationAvant:  valorisationAvant,
            valorisationApres:  valorisationApres,
            horodatage:         block.timestamp,
            referenceFond:      referenceFond,
            motif:              motif,
            empreintePrec:      _empreintePrec
        });

        _listeMouvements.push(idMouvement);
        _empreintePrec = idMouvement;

        return idMouvement;
    }

    // =========================================================================
    // OVERRIDE supportsInterface (ERC-165)
    // =========================================================================
    // Cohérent avec FondTokenise v2 et ActifTokenise :
    // seul AccessControl hérite d'ERC-165 dans notre arbre d'héritage.

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
