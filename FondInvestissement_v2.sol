// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// ============================================================
//  IMPORTATIONS DES BIBLIOTHEQUES OPENZEPPELIN
//  Nous utilisons OpenZeppelin car c'est la reference industrielle
//  pour les smart contracts securises. Ces bibliotheques sont
//  auditees, battle-tested et maintenues activement.
// ============================================================
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IToolbox {
    function calculerFrais(uint256 montant, uint8 typeFrais) external view returns (uint256);
    function calculerDepreciationLineaire(uint256 valeurNominale, uint256 dateEmission, uint256 dateEcheance, uint256 timestampActuel) external pure returns (uint256);
    function calculerReequilibrage(uint256 valeurPortefeuille, int256 nouvellesSouscriptions) external view returns (uint256[] memory achats, uint256[] memory ventes);
    function evaluerPortefeuille(address[] calldata actifs, uint256[] calldata quantites) external view returns (uint256);
}

interface ITokenizedAsset {
    function valeurUnitaire() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IAssetHolding {
    function deposerActif(address actif, uint256 montant) external;
    function retirerActif(address actif, uint256 montant, address destinataire) external;
    function soldeActif(address actif) external view returns (uint256);
    function valeurTotale() external view returns (uint256);
}

contract FondInvestissement is ERC20, ERC20Burnable, ERC20Pausable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ROLES
    bytes32 public constant ROLE_ADMIN = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROLE_GESTIONNAIRE = keccak256("ROLE_GESTIONNAIRE");
    bytes32 public constant ROLE_AGENT_TRANSFERT = keccak256("ROLE_AGENT_TRANSFERT");
    bytes32 public constant ROLE_AUDITEUR = keccak256("ROLE_AUDITEUR");
    bytes32 public constant ROLE_DEPOSITAIRE = keccak256("ROLE_DEPOSITAIRE");
    bytes32 public constant ROLE_ORACLE = keccak256("ROLE_ORACLE");

    // CONSTANTES
    uint256 public constant PRECISION = 1e18;
    uint256 public constant VALEUR_PART_INITIALE = 100 * PRECISION;
    uint256 public constant SOUSCRIPTION_MINIMUM = 100_000 * PRECISION;
    uint256 public constant MAX_ORDRES_PAR_CYCLE = 50;

    // ENUMS
    enum StatutOrdre { EN_ATTENTE, VALIDE, EXECUTE, REJETE, ANNULE }
    enum TypeOrdre { SOUSCRIPTION, RACHAT }

    // STRUCTURES
    struct Ordre {
        uint256 id;
        address investisseur;
        TypeOrdre typeOrdre;
        uint256 montantEUR;
        uint256 timestampReception;
        uint256 cycleNAV;
        uint256 navExecution;
        uint256 partsMinteesBrulees;
        uint256 fraisAppliques;
        StatutOrdre statut;
        bytes32 hashOrdre;
    }

    struct CycleNAV {
        uint256 id;
        uint256 timestamp;
        uint256 valeurActifNet;
        uint256 nombreParts;
        uint256 navParPart;
        uint256 valeurPortefeuille;
        uint256 tresorerie;
        uint256 totalSouscriptions;
        uint256 totalRachats;
        uint256[] ordresTraites;
        bool finalise;
        bytes32 hashCycle;
    }

    struct EntreeActionnaire {
        address adresse;
        uint256 nombreParts;
        uint256 valeurInvestieEUR;
        uint256 datePremiereEntree;
        uint256 dateDerniereOperation;
        bool estActif;
        bool kycValide;
        uint256[] historiqueCycles;
    }

    struct EvenementAudit {
        uint256 timestamp;
        address acteur;
        bytes32 typeEvenement;
        bytes32 hashDonnees;
        uint256 cycleNAVAssocie;
    }

    // VARIABLES D'ETAT
    IToolbox public toolbox;
    IAssetHolding public assetHolding;
    IERC20 public tokenEUR;

    uint256 public compteurOrdres;
    uint256 public compteurCyclesNAV;
    uint256 public cycleNAVCourant;
    uint256 public tresorerie;
    uint256 public navParPartCourante;
    uint256 public nombreInvestisseursActifs;
    bool private _cycleNAVEnCours;

    mapping(uint256 => Ordre) public ordres;
    mapping(uint256 => CycleNAV) public cyclesNAV;
    mapping(address => EntreeActionnaire) public registreActionnaires;
    mapping(address => uint256) public portefeuille;
    mapping(address => bool) public estActifAutorise;

    address[] public listeActionnaires;
    uint256[] public fileOrdresEnAttente;
    address[] public actifsAutorises;
    EvenementAudit[] public journalAudit;

    // EVENEMENTS
    event OrdreRecu(uint256 indexed idOrdre, address indexed investisseur, TypeOrdre typeOrdre, uint256 montant, uint256 cycleNAV, uint256 timestamp);
    event OrdreExecute(uint256 indexed idOrdre, address indexed investisseur, TypeOrdre typeOrdre, uint256 navAppliquee, uint256 partsMinteesBrulees, uint256 fraisAppliques, uint256 timestamp);
    event OrdreRejete(uint256 indexed idOrdre, address indexed investisseur, string raison, uint256 timestamp);
    event NAVCalculee(uint256 indexed cycleNAV, uint256 navParPart, uint256 valeurActifNet, uint256 nombreParts, uint256 timestamp);
    event CycleNAVFinalise(uint256 indexed cycleNAV, uint256 navParPart, uint256 totalSouscriptions, uint256 totalRachats, uint256 timestamp, bytes32 hashCycle);
    event RegistreActionnaireMisAJour(address indexed actionnaire, uint256 nombrePartsAvant, uint256 nombrePartsApres, uint256 cycleNAV, uint256 timestamp);
    event PortefeuilleReequilibre(uint256 indexed cycleNAV, uint256 valeurAvant, uint256 valeurApres, uint256 timestamp);
    event ToolboxMisAJour(address indexed ancienneAdresse, address indexed nouvelleAdresse);
    event ActifAutoriseMisAJour(address indexed actif, bool estAutorise);
    event KYCValide(address indexed investisseur, address indexed validateur, uint256 timestamp);

    // MODIFICATEURS
    modifier seulementKYCValide(address investisseur) {
        require(registreActionnaires[investisseur].kycValide, "FOND: KYC non valide");
        _;
    }

    modifier cycleNAVNonEnCours() {
        require(!_cycleNAVEnCours, "FOND: Cycle NAV deja en cours");
        _;
    }

    modifier cycleNAVValide(uint256 idCycle) {
        require(idCycle <= compteurCyclesNAV && idCycle > 0, "FOND: ID cycle invalide");
        _;
    }

    modifier ordreExistant(uint256 idOrdre) {
        require(idOrdre > 0 && idOrdre <= compteurOrdres, "FOND: ID ordre invalide");
        _;
    }

    // CONSTRUCTEUR
    constructor(
        string memory nomFonds,
        string memory symboleFonds,
        address adresseToolbox,
        address adresseAssetHolding,
        address adresseTokenEUR,
        address admin,
        address gestionnaire,
        address agentTransfert,
        address depositaire
    ) ERC20(nomFonds, symboleFonds) {
        require(adresseToolbox != address(0), "FOND: Adresse Toolbox nulle");
        require(adresseAssetHolding != address(0), "FOND: Adresse AssetHolding nulle");
        require(adresseTokenEUR != address(0), "FOND: Adresse token EUR nulle");
        require(admin != address(0), "FOND: Adresse admin nulle");
        require(gestionnaire != address(0), "FOND: Adresse gestionnaire nulle");
        require(agentTransfert != address(0), "FOND: Adresse agent transfert nulle");
        require(depositaire != address(0), "FOND: Adresse depositaire nulle");

        toolbox = IToolbox(adresseToolbox);
        assetHolding = IAssetHolding(adresseAssetHolding);
        tokenEUR = IERC20(adresseTokenEUR);

        _grantRole(ROLE_ADMIN, admin);
        _grantRole(ROLE_GESTIONNAIRE, gestionnaire);
        _grantRole(ROLE_AGENT_TRANSFERT, agentTransfert);
        _grantRole(ROLE_DEPOSITAIRE, depositaire);

        navParPartCourante = VALEUR_PART_INITIALE;
        cycleNAVCourant = 1;

        _enregistrerAudit(admin, keccak256("CREATION_FONDS"), keccak256(abi.encodePacked(nomFonds, symboleFonds, block.timestamp)), 0);
    }

    // ============================================================
    // SECTION 1 : REGISTRE DES ACTIONNAIRES
    // Obligation legale : Article L214-8 du Code Monetaire et Financier
    // ============================================================

    /// @notice Enregistre un nouvel investisseur avec validation KYC/AML
    /// @dev Pattern CEI : pas d'interactions externes ici, uniquement des effets d'etat
    function enregistrerActionnaire(address investisseur, bool kycApprouve)
        external onlyRole(ROLE_AGENT_TRANSFERT) whenNotPaused
    {
        // CHECKS
        require(investisseur != address(0), "FOND: Adresse investisseur nulle");
        require(!registreActionnaires[investisseur].estActif, "FOND: Deja enregistre");

        // EFFECTS
        registreActionnaires[investisseur] = EntreeActionnaire({
            adresse: investisseur,
            nombreParts: 0,
            valeurInvestieEUR: 0,
            datePremiereEntree: block.timestamp,
            dateDerniereOperation: block.timestamp,
            estActif: true,
            kycValide: kycApprouve,
            historiqueCycles: new uint256[](0)
        });

        listeActionnaires.push(investisseur);
        nombreInvestisseursActifs++;

        if (kycApprouve) emit KYCValide(investisseur, msg.sender, block.timestamp);

        _enregistrerAudit(msg.sender, keccak256("ENREGISTREMENT_ACTIONNAIRE"),
            keccak256(abi.encodePacked(investisseur, kycApprouve, block.timestamp)), cycleNAVCourant);
    }

    /// @notice Met a jour le statut KYC d'un investisseur
    /// @dev Revoquer le KYC bloque les nouvelles operations mais preserve les parts existantes
    function mettreAJourKYC(address investisseur, bool nouveauStatutKYC)
        external onlyRole(ROLE_AGENT_TRANSFERT)
    {
        // CHECKS
        require(registreActionnaires[investisseur].estActif, "FOND: Investisseur non enregistre");

        // EFFECTS
        bool ancienStatut = registreActionnaires[investisseur].kycValide;
        registreActionnaires[investisseur].kycValide = nouveauStatutKYC;

        if (nouveauStatutKYC && !ancienStatut) emit KYCValide(investisseur, msg.sender, block.timestamp);

        _enregistrerAudit(msg.sender, keccak256("MISE_A_JOUR_KYC"),
            keccak256(abi.encodePacked(investisseur, ancienStatut, nouveauStatutKYC)), cycleNAVCourant);
    }

    // ============================================================
    // SECTION 2 : ORDRES DE SOUSCRIPTION / RACHAT
    // Pattern CEI strict + ReentrancyGuard sur toutes les fonctions
    // manipulant des transferts de tokens
    // ============================================================

    /**
     * @notice Capture et enregistre un ordre de souscription
     * @dev Pattern CEI :
     *   CHECKS  -> validations metier (KYC, montant minimum, file non saturee, solde EUR)
     *   EFFECTS -> creation de l'ordre + hash d'integrite + ajout en file d'attente
     *   INTERACTIONS -> transfert EUR en escrow (APRES tous les changements d'etat)
     *
     * Pourquoi ReentrancyGuard ici ?
     * Le transfert ERC-20 (safeTransferFrom) est un appel externe.
     * Si tokenEUR est un contrat malveillant ou compromis, il pourrait rappeler
     * soumettreSouscription avant que l'etat soit stabilise. nonReentrant l'en empeche.
     */
    function soumettreSouscription(uint256 montantEUR)
        external
        nonReentrant
        whenNotPaused
        seulementKYCValide(msg.sender)
        returns (uint256 idOrdre)
    {
        // CHECKS
        require(montantEUR >= SOUSCRIPTION_MINIMUM, "FOND: Montant inferieur au minimum institutionnel");
        require(fileOrdresEnAttente.length < MAX_ORDRES_PAR_CYCLE, "FOND: File saturee");
        require(tokenEUR.allowance(msg.sender, address(this)) >= montantEUR, "FOND: Approbation EUR insuffisante");
        require(tokenEUR.balanceOf(msg.sender) >= montantEUR, "FOND: Solde EUR insuffisant");

        // EFFECTS
        compteurOrdres++;
        idOrdre = compteurOrdres;

        bytes32 hashOrdre = keccak256(abi.encodePacked(
            idOrdre, msg.sender, TypeOrdre.SOUSCRIPTION, montantEUR, block.timestamp, cycleNAVCourant
        ));

        ordres[idOrdre] = Ordre({
            id: idOrdre,
            investisseur: msg.sender,
            typeOrdre: TypeOrdre.SOUSCRIPTION,
            montantEUR: montantEUR,
            timestampReception: block.timestamp,
            cycleNAV: cycleNAVCourant,
            navExecution: 0,
            partsMinteesBrulees: 0,
            fraisAppliques: 0,
            statut: StatutOrdre.EN_ATTENTE,
            hashOrdre: hashOrdre
        });

        fileOrdresEnAttente.push(idOrdre);
        registreActionnaires[msg.sender].dateDerniereOperation = block.timestamp;

        // INTERACTIONS (appel externe en dernier)
        tokenEUR.safeTransferFrom(msg.sender, address(this), montantEUR);

        emit OrdreRecu(idOrdre, msg.sender, TypeOrdre.SOUSCRIPTION, montantEUR, cycleNAVCourant, block.timestamp);
        _enregistrerAudit(msg.sender, keccak256("SOUSCRIPTION_RECUE"), hashOrdre, cycleNAVCourant);
    }

    /**
     * @notice Capture et enregistre un ordre de rachat
     * @dev Pattern CEI :
     *   CHECKS  -> verification parts disponibles, file non saturee
     *   EFFECTS -> creation de l'ordre + hash d'integrite + ajout en file
     *   INTERACTIONS -> transfert parts en escrow via _transfer interne
     *
     * Le paiement EUR est effectue lors de l'execution du cycle NAV,
     * pas ici — les parts sont "gelees" en escrow jusqu'a execution.
     */
    function soumettreRachat(uint256 nombreParts)
        external
        nonReentrant
        whenNotPaused
        seulementKYCValide(msg.sender)
        returns (uint256 idOrdre)
    {
        // CHECKS
        require(nombreParts > 0, "FOND: Nombre de parts nul");
        require(balanceOf(msg.sender) >= nombreParts, "FOND: Solde parts insuffisant");
        require(fileOrdresEnAttente.length < MAX_ORDRES_PAR_CYCLE, "FOND: File saturee");

        // EFFECTS
        compteurOrdres++;
        idOrdre = compteurOrdres;

        bytes32 hashOrdre = keccak256(abi.encodePacked(
            idOrdre, msg.sender, TypeOrdre.RACHAT, nombreParts, block.timestamp, cycleNAVCourant
        ));

        ordres[idOrdre] = Ordre({
            id: idOrdre,
            investisseur: msg.sender,
            typeOrdre: TypeOrdre.RACHAT,
            montantEUR: nombreParts,
            timestampReception: block.timestamp,
            cycleNAV: cycleNAVCourant,
            navExecution: 0,
            partsMinteesBrulees: 0,
            fraisAppliques: 0,
            statut: StatutOrdre.EN_ATTENTE,
            hashOrdre: hashOrdre
        });

        fileOrdresEnAttente.push(idOrdre);
        registreActionnaires[msg.sender].dateDerniereOperation = block.timestamp;

        // INTERACTIONS : lock des parts en escrow (appel interne _transfer)
        _transfer(msg.sender, address(this), nombreParts);

        emit OrdreRecu(idOrdre, msg.sender, TypeOrdre.RACHAT, nombreParts, cycleNAVCourant, block.timestamp);
        _enregistrerAudit(msg.sender, keccak256("RACHAT_RECU"), hashOrdre, cycleNAVCourant);
    }

    /**
     * @notice Annule un ordre en attente avant execution du cycle NAV
     * @dev Pattern CEI critique :
     *   EFFECTS -> statut ANNULE + retrait de file (avant tout remboursement)
     *   INTERACTIONS -> remboursement EUR ou restitution parts (apres changement d'etat)
     * La protection ReentrancyGuard + changement de statut avant remboursement
     * garantit l'impossibilite d'une double-annulation.
     */
    function annulerOrdre(uint256 idOrdre)
        external
        nonReentrant
        whenNotPaused
        ordreExistant(idOrdre)
    {
        // CHECKS
        Ordre storage ordre = ordres[idOrdre];
        require(ordre.investisseur == msg.sender, "FOND: Non proprietaire de l'ordre");
        require(ordre.statut == StatutOrdre.EN_ATTENTE, "FOND: Ordre non annulable");

        // EFFECTS (avant toute interaction externe)
        ordre.statut = StatutOrdre.ANNULE;
        _retirerDeLaFile(idOrdre);

        // INTERACTIONS
        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            tokenEUR.safeTransfer(msg.sender, ordre.montantEUR);
        } else {
            _transfer(address(this), msg.sender, ordre.montantEUR);
        }

        _enregistrerAudit(msg.sender, keccak256("ORDRE_ANNULE"), ordre.hashOrdre, cycleNAVCourant);
    }

    // ============================================================
    // SECTION 3 : CYCLE NAV COMPLET
    //
    // Architecture "1 ordre = 1 cycle NAV" :
    // Chaque ordre declenche son propre cycle complet de valorisation.
    // Cela garantit une NAV precise pour chaque investisseur, sans
    // approximation par mutualisation. Pour 10 ordres simultanes
    // => 10 cycles NAV sequentiels distincts.
    //
    // Sequence :
    //  1. Synchronisation C-1 (registre precedent, soldes, actifs en attente)
    //  2. Logique d'investissement via Toolbox (reequilibrage portefeuille)
    //  3. Application des frais via Toolbox
    //  4. Calcul NAV temps reel (portefeuille + tresorerie / nb parts)
    //  5. Finalite : mint/burn atomique + mise a jour registre
    // ============================================================

    /**
     * @notice Execute un cycle NAV complet pour un ordre donne
     * @dev Triple protection :
     *   - nonReentrant : empeche toute reentrance lors des appels externes
     *   - cycleNAVNonEnCours : empeche deux cycles simultanes (race condition)
     *   - onlyRole(ROLE_GESTIONNAIRE) : seul le gestionnaire habilite peut declencher
     *
     * Atomicite Ethereum : si une etape echoue, toute la transaction est annulee.
     * Propriete ACID garantie : pas d'etat partiel possible.
     *
     * @param idOrdre Identifiant de l'ordre a traiter dans ce cycle
     */
    function executerCycleNAV(uint256 idOrdre)
        external
        nonReentrant
        whenNotPaused
        onlyRole(ROLE_GESTIONNAIRE)
        cycleNAVNonEnCours
        ordreExistant(idOrdre)
    {
        // CHECKS
        Ordre storage ordre = ordres[idOrdre];
        require(
            ordre.statut == StatutOrdre.EN_ATTENTE || ordre.statut == StatutOrdre.VALIDE,
            "FOND: Ordre non executable"
        );

        // EFFECTS : verrouillage du cycle (protection double-execution)
        _cycleNAVEnCours = true;
        compteurCyclesNAV++;
        uint256 idCycle = compteurCyclesNAV;

        CycleNAV storage cycle = cyclesNAV[idCycle];
        cycle.id = idCycle;
        cycle.timestamp = block.timestamp;
        cycle.finalise = false;

        // ----------------------------------------------------------
        // ETAPE 1 : SYNCHRONISATION AVEC LE CYCLE PRECEDENT (C-1)
        // Recupere la NAV precedente, l'etat du registre et les soldes
        // pour assurer la continuite et la coherence inter-cycles.
        // ----------------------------------------------------------
        uint256 navPrecedente;
        if (idCycle > 1) {
            CycleNAV storage cyclePrecedent = cyclesNAV[idCycle - 1];
            require(cyclePrecedent.finalise, "FOND: Cycle precedent non finalise");
            navPrecedente = cyclePrecedent.navParPart;
        } else {
            navPrecedente = VALEUR_PART_INITIALE;
        }

        // ----------------------------------------------------------
        // ETAPE 2 : LOGIQUE D'INVESTISSEMENT VIA LE TOOLBOX
        // Le Toolbox calcule les achats/ventes d'actifs necessaires
        // pour maintenir l'allocation cible apres les nouveaux ordres.
        // Appel VIEW => pas de risque de reentrance.
        // ----------------------------------------------------------
        int256 fluxNet;
        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            fluxNet = int256(ordre.montantEUR);
        } else {
            fluxNet = -int256((ordre.montantEUR * navPrecedente) / PRECISION);
        }

        uint256 valeurPortefeuilleAvant = _obtenirValeurPortefeuille();
        (uint256[] memory achats, uint256[] memory ventes) = toolbox.calculerReequilibrage(
            valeurPortefeuilleAvant, fluxNet
        );

        // Calcul des totaux pour l'evenement de reequilibrage
        uint256 totalAchats = 0;
        uint256 totalVentes = 0;
        for (uint256 k = 0; k < achats.length; k++) totalAchats += achats[k];
        for (uint256 k = 0; k < ventes.length; k++) totalVentes += ventes[k];

        emit PortefeuilleReequilibre(idCycle, valeurPortefeuilleAvant, valeurPortefeuilleAvant + totalAchats - totalVentes, block.timestamp);

        // ----------------------------------------------------------
        // ETAPE 3 : APPLICATION DES FRAIS VIA LE TOOLBOX
        // Structure de frais encodee dans le Toolbox :
        //   typeFrais 0 = souscription, 1 = rachat, 2 = gestion
        // Calcul sur montant brut, NET applique pour le mint/burn.
        // ----------------------------------------------------------
        uint256 frais;
        uint256 montantNet;

        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            frais = toolbox.calculerFrais(ordre.montantEUR, 0);
            montantNet = ordre.montantEUR - frais;
        } else {
            uint256 valeurEURRachat = (ordre.montantEUR * navPrecedente) / PRECISION;
            frais = toolbox.calculerFrais(valeurEURRachat, 1);
            montantNet = valeurEURRachat - frais;
        }

        ordre.fraisAppliques = frais;

        // ----------------------------------------------------------
        // ETAPE 4 : CALCUL DE LA NAV EN TEMPS REEL
        // Formule : NAV/part = (Valeur Portefeuille + Tresorerie) / Nb Parts
        // Precision 18 decimales pour minimiser les erreurs d'arrondi.
        // La tresorerie inclut les nouvelles souscriptions nettes.
        // ----------------------------------------------------------
        uint256 valeurPortefeuille = _obtenirValeurPortefeuille();
        uint256 tresorerieEffective = tresorerie;
        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            tresorerieEffective += montantNet;
        }

        uint256 valeurActifNet = valeurPortefeuille + tresorerieEffective;
        uint256 nombrePartsTotales = totalSupply();
        uint256 navParPart;

        if (nombrePartsTotales == 0) {
            navParPart = VALEUR_PART_INITIALE;
        } else {
            navParPart = (valeurActifNet * PRECISION) / nombrePartsTotales;
        }

        cycle.valeurPortefeuille = valeurPortefeuille;
        cycle.tresorerie = tresorerieEffective;
        cycle.valeurActifNet = valeurActifNet;
        cycle.navParPart = navParPart;
        cycle.nombreParts = nombrePartsTotales;

        emit NAVCalculee(idCycle, navParPart, valeurActifNet, nombrePartsTotales, block.timestamp);

        // ----------------------------------------------------------
        // ETAPE 5 : FINALITE — MINT/BURN ATOMIQUE
        // Simultaneite garantie par l'atomicite Ethereum :
        //   - Souscription : parts mintees SIMULTANEMENT a la reception EUR
        //   - Rachat : parts brulees SIMULTANEMENT au paiement EUR
        // Si l'une ou l'autre echoue, toute la transaction est annulee.
        // ----------------------------------------------------------
        uint256 partsCrees = 0;
        uint256 partsBrulees = 0;

        if (ordre.typeOrdre == TypeOrdre.SOUSCRIPTION) {
            // Calcul : parts = montantNet / navParPart
            partsCrees = (montantNet * PRECISION) / navParPart;
            require(partsCrees > 0, "FOND: Parts resultantes nulles");

            tresorerie += montantNet;

            // MINT atomique — creation de parts pour l'investisseur
            _mint(ordre.investisseur, partsCrees);

            _mettreAJourRegistre(
                ordre.investisseur,
                registreActionnaires[ordre.investisseur].nombreParts,
                registreActionnaires[ordre.investisseur].nombreParts + partsCrees,
                montantNet, idCycle
            );

            cycle.totalSouscriptions = montantNet;

        } else {
            partsBrulees = ordre.montantEUR;

            require(balanceOf(address(this)) >= partsBrulees, "FOND: Parts escrow insuffisantes");
            require(tresorerie >= montantNet, "FOND: Tresorerie insuffisante pour rachat");

            // BURN atomique — destruction des parts escrowees
            _burn(address(this), partsBrulees);
            tresorerie -= montantNet;

            uint256 partsAvant = registreActionnaires[ordre.investisseur].nombreParts;
            _mettreAJourRegistre(
                ordre.investisseur,
                partsAvant,
                partsAvant >= partsBrulees ? partsAvant - partsBrulees : 0,
                0, idCycle
            );

            cycle.totalRachats = montantNet;

            // PAIEMENT EUR en derniere position — pattern CEI respecte
            // Tous les changements d'etat sont termines avant cet appel externe
            tokenEUR.safeTransfer(ordre.investisseur, montantNet);
        }

        // ----------------------------------------------------------
        // SCELLAGE CRYPTOGRAPHIQUE DU CYCLE (tamper-proof)
        // Hash chaine avec le cycle precedent (structure Merkle-like) :
        // toute modification d'un cycle invalide tous les cycles suivants.
        // Une fois cycle.finalise = true, les donnees sont IMMUTABLES.
        // ----------------------------------------------------------
        ordre.navExecution = navParPart;
        ordre.partsMinteesBrulees = partsCrees > 0 ? partsCrees : partsBrulees;
        ordre.statut = StatutOrdre.EXECUTE;

        cycle.ordresTraites.push(idOrdre);

        bytes32 hashPrecedent = idCycle > 1 ? cyclesNAV[idCycle - 1].hashCycle : bytes32(0);
        cycle.hashCycle = keccak256(abi.encodePacked(
            idCycle, navParPart, valeurActifNet, totalSupply(),
            cycle.totalSouscriptions, cycle.totalRachats,
            block.timestamp, hashPrecedent
        ));

        // Verrou d'immuabilite — apres cette ligne, le cycle ne peut plus etre modifie
        cycle.finalise = true;

        navParPartCourante = navParPart;
        cycleNAVCourant = idCycle + 1;

        _retirerDeLaFile(idOrdre);
        _cycleNAVEnCours = false;

        emit OrdreExecute(idOrdre, ordre.investisseur, ordre.typeOrdre,
            navParPart, ordre.partsMinteesBrulees, frais, block.timestamp);
        emit CycleNAVFinalise(idCycle, navParPart, cycle.totalSouscriptions,
            cycle.totalRachats, block.timestamp, cycle.hashCycle);
        _enregistrerAudit(msg.sender, keccak256("CYCLE_NAV_FINALISE"), cycle.hashCycle, idCycle);
    }

    // ============================================================
    // SECTION 4 : GESTION DU PORTEFEUILLE
    // ============================================================

    /// @notice Autorise un actif en portefeuille (liste blanche)
    /// @dev La whitelist empeche l'introduction d'actifs non-vettes
    ///      qui pourraient manipuler la NAV (vecteur d'attaque connu)
    function autoriserActif(address adresseActif) external onlyRole(ROLE_ADMIN) {
        require(adresseActif != address(0), "FOND: Adresse actif nulle");
        require(!estActifAutorise[adresseActif], "FOND: Actif deja autorise");

        estActifAutorise[adresseActif] = true;
        actifsAutorises.push(adresseActif);

        emit ActifAutoriseMisAJour(adresseActif, true);
    }

    /// @notice Retire un actif de la whitelist
    /// @dev Impossible si position ouverte — protege l'integrite comptable
    function desautoriserActif(address adresseActif) external onlyRole(ROLE_ADMIN) {
        require(estActifAutorise[adresseActif], "FOND: Actif non autorise");
        require(portefeuille[adresseActif] == 0, "FOND: Position ouverte sur cet actif");

        estActifAutorise[adresseActif] = false;
        emit ActifAutoriseMisAJour(adresseActif, false);
    }

    /// @notice Enregistre un achat d'actif dans le portefeuille
    /// @dev CEI : verification tresorerie -> deduction tresorerie -> enregistrement
    function enregistrerAchatActif(address adresseActif, uint256 quantite, uint256 coutEUR)
        external nonReentrant onlyRole(ROLE_GESTIONNAIRE) whenNotPaused
    {
        // CHECKS
        require(estActifAutorise[adresseActif], "FOND: Actif non autorise");
        require(quantite > 0, "FOND: Quantite nulle");
        require(coutEUR > 0, "FOND: Cout nul");
        require(tresorerie >= coutEUR, "FOND: Tresorerie insuffisante");

        // EFFECTS
        tresorerie -= coutEUR;
        portefeuille[adresseActif] += quantite;

        _enregistrerAudit(msg.sender, keccak256("ACHAT_ACTIF"),
            keccak256(abi.encodePacked(adresseActif, quantite, coutEUR, block.timestamp)), cycleNAVCourant);
    }

    /// @notice Enregistre une vente d'actif du portefeuille
    function enregistrerVenteActif(address adresseActif, uint256 quantite, uint256 produitEUR)
        external nonReentrant onlyRole(ROLE_GESTIONNAIRE) whenNotPaused
    {
        // CHECKS
        require(estActifAutorise[adresseActif], "FOND: Actif non reconnu");
        require(portefeuille[adresseActif] >= quantite, "FOND: Position insuffisante");
        require(quantite > 0, "FOND: Quantite nulle");

        // EFFECTS
        portefeuille[adresseActif] -= quantite;
        tresorerie += produitEUR;

        _enregistrerAudit(msg.sender, keccak256("VENTE_ACTIF"),
            keccak256(abi.encodePacked(adresseActif, quantite, produitEUR, block.timestamp)), cycleNAVCourant);
    }

    // ============================================================
    // SECTION 5 : FONCTIONS DE CONSULTATION (VIEW)
    // Gratuites pour les appelants externes (pas de modification d'etat)
    // ============================================================

    /// @notice Retourne la NAV complete du fonds en temps reel
    function obtenirNAV() external view returns (
        uint256 valeurActifNet, uint256 navParPart, uint256 nombrePartsTotales
    ) {
        valeurActifNet = _obtenirValeurPortefeuille() + tresorerie;
        nombrePartsTotales = totalSupply();
        navParPart = nombrePartsTotales == 0 ? VALEUR_PART_INITIALE : (valeurActifNet * PRECISION) / nombrePartsTotales;
    }

    /// @notice Retourne les donnees completes d'un actionnaire du registre
    function obtenirDonneesActionnaire(address actionnaire) external view returns (EntreeActionnaire memory) {
        return registreActionnaires[actionnaire];
    }

    /// @notice Retourne les donnees d'un cycle NAV
    function obtenirCycleNAV(uint256 idCycle) external view cycleNAVValide(idCycle) returns (CycleNAV memory) {
        return cyclesNAV[idCycle];
    }

    /// @notice Retourne les donnees d'un ordre
    function obtenirOrdre(uint256 idOrdre) external view ordreExistant(idOrdre) returns (Ordre memory) {
        return ordres[idOrdre];
    }

    /// @notice Retourne la file d'ordres en attente
    function obtenirOrdresEnAttente() external view returns (uint256[] memory) {
        return fileOrdresEnAttente;
    }

    /**
     * @notice Verifie l'integrite cryptographique d'un cycle NAV
     * @dev Recalcule le hash et le compare au hash scelle.
     *      Toute alteration des donnees se traduit par une discordance.
     *      Outil d'audit pour detecter toute falsification on-chain.
     */
    function verifierIntegriteCycle(uint256 idCycle)
        external view cycleNAVValide(idCycle) returns (bool estIntegre)
    {
        CycleNAV storage cycle = cyclesNAV[idCycle];
        require(cycle.finalise, "FOND: Cycle non finalise");

        bytes32 hashPrecedent = idCycle > 1 ? cyclesNAV[idCycle - 1].hashCycle : bytes32(0);

        bytes32 hashRecalcule = keccak256(abi.encodePacked(
            cycle.id, cycle.navParPart, cycle.valeurActifNet, cycle.nombreParts,
            cycle.totalSouscriptions, cycle.totalRachats, cycle.timestamp, hashPrecedent
        ));

        return hashRecalcule == cycle.hashCycle;
    }

    /// @notice Retourne le journal d'audit complet (acces restreint auditeurs)
    function obtenirJournalAudit() external view onlyRole(ROLE_AUDITEUR) returns (EvenementAudit[] memory) {
        return journalAudit;
    }

    /// @notice Retourne la composition du portefeuille avec valorisation
    function obtenirCompositionPortefeuille() external view returns (
        address[] memory actifs, uint256[] memory quantites, uint256[] memory valeurs
    ) {
        uint256 n = actifsAutorises.length;
        actifs = new address[](n);
        quantites = new uint256[](n);
        valeurs = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            actifs[i] = actifsAutorises[i];
            quantites[i] = portefeuille[actifsAutorises[i]];
            if (quantites[i] > 0) {
                valeurs[i] = (quantites[i] * ITokenizedAsset(actifsAutorises[i]).valeurUnitaire()) / PRECISION;
            }
        }
    }

    // ============================================================
    // SECTION 6 : ADMINISTRATION ET GOUVERNANCE
    // ============================================================

    /// @notice Met a jour l'adresse du Toolbox (necessite multisig + timelock recommande)
    function mettreAJourToolbox(address nouvelleAdresse) external onlyRole(ROLE_ADMIN) {
        require(nouvelleAdresse != address(0), "FOND: Adresse nulle");
        require(nouvelleAdresse != address(toolbox), "FOND: Adresse identique");

        address ancienneAdresse = address(toolbox);
        toolbox = IToolbox(nouvelleAdresse);

        emit ToolboxMisAJour(ancienneAdresse, nouvelleAdresse);
        _enregistrerAudit(msg.sender, keccak256("TOOLBOX_MIS_A_JOUR"),
            keccak256(abi.encodePacked(ancienneAdresse, nouvelleAdresse)), cycleNAVCourant);
    }

    /// @notice Suspend le fonds (circuit breaker AMF)
    function suspendreOperations() external onlyRole(ROLE_ADMIN) {
        _pause();
        _enregistrerAudit(msg.sender, keccak256("FONDS_SUSPENDU"), bytes32(block.timestamp), cycleNAVCourant);
    }

    /// @notice Reprend les operations apres suspension
    function reprendreOperations() external onlyRole(ROLE_ADMIN) {
        _unpause();
        _enregistrerAudit(msg.sender, keccak256("FONDS_REPRIS"), bytes32(block.timestamp), cycleNAVCourant);
    }

    /// @notice Depot de tresorerie par le depositaire (amorçage du fonds)
    function deposerTresorerie(uint256 montant)
        external nonReentrant onlyRole(ROLE_DEPOSITAIRE) whenNotPaused
    {
        // CHECKS
        require(montant > 0, "FOND: Montant nul");

        // EFFECTS
        tresorerie += montant;

        // INTERACTIONS
        tokenEUR.safeTransferFrom(msg.sender, address(this), montant);

        _enregistrerAudit(msg.sender, keccak256("DEPOT_TRESORERIE"),
            keccak256(abi.encodePacked(montant, block.timestamp)), cycleNAVCourant);
    }

    // ============================================================
    // SECTION 7 : FONCTIONS INTERNES
    // ============================================================

    /// @dev Obtient la valeur totale du portefeuille via le Toolbox
    ///      Le Toolbox integre les prix de marche + depreciation lineaire des CPs
    function _obtenirValeurPortefeuille() internal view returns (uint256) {
        uint256 n = actifsAutorises.length;
        if (n == 0) return 0;

        address[] memory actifs = new address[](n);
        uint256[] memory quantites = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            actifs[i] = actifsAutorises[i];
            quantites[i] = portefeuille[actifsAutorises[i]];
        }

        return toolbox.evaluerPortefeuille(actifs, quantites);
    }

    /// @dev Met a jour le registre des actionnaires apres mint/burn
    ///      Maintient l'exactitude du registre en temps reel (L214-8 CMF)
    function _mettreAJourRegistre(
        address actionnaire, uint256 partsAvant, uint256 partsApres,
        uint256 montantInvesti, uint256 idCycle
    ) internal {
        EntreeActionnaire storage entree = registreActionnaires[actionnaire];
        entree.nombreParts = partsApres;
        entree.dateDerniereOperation = block.timestamp;

        if (montantInvesti > 0) entree.valeurInvestieEUR += montantInvesti;

        bool cycleDejaPresent = false;
        for (uint256 i = 0; i < entree.historiqueCycles.length; i++) {
            if (entree.historiqueCycles[i] == idCycle) { cycleDejaPresent = true; break; }
        }
        if (!cycleDejaPresent) entree.historiqueCycles.push(idCycle);

        if (partsAvant > 0 && partsApres == 0 && nombreInvestisseursActifs > 0) {
            nombreInvestisseursActifs--;
        } else if (partsAvant == 0 && partsApres > 0) {
            nombreInvestisseursActifs++;
        }

        emit RegistreActionnaireMisAJour(actionnaire, partsAvant, partsApres, idCycle, block.timestamp);
    }

    /// @dev Retrait O(1) d'un ordre de la file (swap-and-pop)
    ///      Evite les decalages couteux en gas pour les grandes files
    function _retirerDeLaFile(uint256 idOrdre) internal {
        uint256 longueur = fileOrdresEnAttente.length;
        for (uint256 i = 0; i < longueur; i++) {
            if (fileOrdresEnAttente[i] == idOrdre) {
                fileOrdresEnAttente[i] = fileOrdresEnAttente[longueur - 1];
                fileOrdresEnAttente.pop();
                return;
            }
        }
    }

    /// @dev Enregistre un evenement dans le journal d'audit (append-only, immuable)
    ///      Conforme ISAE 3402 / SOC 2 — piste d'audit complete et inalterable
    function _enregistrerAudit(
        address acteur, bytes32 typeEvenement, bytes32 hashDonnees, uint256 idCycle
    ) internal {
        journalAudit.push(EvenementAudit({
            timestamp: block.timestamp,
            acteur: acteur,
            typeEvenement: typeEvenement,
            hashDonnees: hashDonnees,
            cycleNAVAssocie: idCycle
        }));
    }

    // ============================================================
    // SECTION 8 : OVERRIDES SOLIDITY (resolution heritage multiple)
    // ============================================================

    /// @dev Override requis : resolution conflit ERC20 vs ERC20Pausable
    ///      ERC20Pausable bloque mint/burn/transfer quand le contrat est en pause
    function _update(address from, address to, uint256 value)
        internal override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }

    /// @dev Restreint les transferts directs de parts entre investisseurs
    ///      Parts non-transferables sauf via mecanismes officiels du fonds
    ///      Conforme UCITS / AIFMD : pas de cession libre de parts d'OPC
    function transfer(address to, uint256 value) public override returns (bool) {
        require(
            msg.sender == address(this) || to == address(this) || hasRole(ROLE_AGENT_TRANSFERT, msg.sender),
            "FOND: Transfert direct de parts non autorise"
        );
        return super.transfer(to, value);
    }

    /// @dev Memes restrictions que transfer pour transferFrom
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        require(
            from == address(this) || to == address(this) || hasRole(ROLE_AGENT_TRANSFERT, msg.sender),
            "FOND: Transfert direct de parts non autorise"
        );
        return super.transferFrom(from, to, value);
    }

    /// @dev Rejette tout ETH envoye directement — flux via token EUR uniquement
    receive() external payable { revert("FOND: ETH non accepte - utiliser token EUR"); }

    /// @dev Rejette tout appel de fonction inconnue
    fallback() external payable { revert("FOND: Fonction inconnue"); }
}
