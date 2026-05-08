// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";
import {IAccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/IAccessControlUpgradeable.sol";

import {LibErrors} from "./library/LibErrors.sol";
import {LibModifiers} from "./library/LibModifiers.sol";

/**
 * @title Euro eXchange Token
 * @author Caceis Bank
 *
 * @notice ERC-20 stablecoin backed by fiat reserves, designed for regulated financial
 *         infrastructure on Ethereum.
 *
 * @dev ## Architecture
 *
 *      This contract is the **implementation** in a Transparent Proxy setup
 *      (OpenZeppelin TransparentUpgradeableProxy + ProxyAdmin). It must never be
 *      used directly — all interactions go through the proxy address.
 *
 *      Upgrade authority is held exclusively by the ProxyAdmin contract, which
 *      is itself managed by specific governance rules to prevent unilateral upgrades.
 *
 * @dev ## Inheritance chain
 *
 *      Initializable
 *        └─ ERC20Upgradeable              (ERC-20 base, storage-safe)
 *             └─ ERC20PermitUpgradeable   (EIP-2612 gasless allowances via EIP-712)
 *      PausableUpgradeable                (circuit-breaker for all transfers)
 *      AccessControlEnumerableUpgradeable (role-based permissions + member enumeration)
 *      ERC2771ContextUpgradeable          (EIP-2771 meta-transaction support)
 *
 *      All parent contracts use the upgradeable variants from OZ v4.9.x, which
 *      replace constructors with `__X_init()` initializers and use unstructured
 *      storage to avoid slot collisions across upgrades.
 *
 * @dev ## Role model
 *
 *      | Role                | Capability                                      |
 *      |---------------------|-------------------------------------------------|
 *      | DEFAULT_ADMIN_ROLE  | Grant / revoke all roles (OZ standard)          |
 *      | PAUSER_ROLE         | Pause and unpause all token transfers           |
 *      | MINTER_ROLE         | Mint new tokens to any non-blacklisted address  |
 *      | BURNER_ROLE         | Burn tokens from any non-blacklisted address    |
 *      | RESCUER_ROLE        | Recover ERC-20 tokens accidentally sent here    |
 *      | BLACKLIST_ADMIN_ROLE| Add / remove addresses from the blacklist       |
 *
 *      Roles are represented as `keccak256` hashes of their name string.
 *      `AccessControlEnumerableUpgradeable` allows on-chain enumeration of role
 *      members, which is required by the last-member protection on `renounceRole`
 *      and `revokeRole`.
 *
 *      At deployment, only `DEFAULT_ADMIN_ROLE` is granted to `admin`.
 *      All other operational roles must be granted explicitly afterwards via
 *      `grantRole`, typically through a multi-sig governance process.
 *
 * @dev ## Transfer control flow
 *
 *      Every token movement (transfer, transferFrom, mint, burn) is routed through
 *      `_beforeTokenTransfer`. The hook enforces two invariants in order:
 *        1. Contract must not be paused.
 *        2. Neither sender nor recipient may be blacklisted
 *           (address(0) is excluded to allow mint/burn to pass through).
 *
 *      Exception: `seizeBlacklistedFunds` intentionally bypasses the sender blacklist
 *      check by setting `_seizureInProgress = true` before calling `_transfer`. This
 *      is the only authorised code path that sets that flag, and it is gated by
 *      `BLACKLIST_ADMIN_ROLE` plus an explicit `isBlacklisted(from)` pre-condition.
 *      The pause check and the recipient blacklist check are NOT bypassed.
 *
 * @dev ## Gasless operations (EIP-2612 / EIP-712)
 *
 *      `ERC20PermitUpgradeable` adds `permit(owner, spender, value, deadline, v, r, s)`,
 *      which lets a token holder sign an off-chain EIP-712 message authorising a
 *      spender without submitting an `approve` transaction. The domain separator
 *      binds the signature to this contract's address and the current chain ID,
 *      preventing replay attacks across deployments or chains.
 *
 *      Note: `approve` and `permit` do NOT check the blacklist. An allowance can
 *      therefore be created for or by a blacklisted address; however, the
 *      subsequent `transferFrom` will be blocked by `_beforeTokenTransfer`.
 *      This behaviour is intentional and documented.
 *
 * @dev ## Meta-transactions (EIP-2771)
 *
 *      `ERC2771ContextUpgradeable` (OZ v4.9.4) allows a trusted forwarder to relay
 *      transactions on behalf of users, enabling gasless UX (fee sponsoring). When a
 *      call arrives from the trusted forwarder, the actual sender is extracted from the
 *      last 20 bytes of calldata rather than `msg.sender`.
 *
 *      In OZ v4.9.4 the trusted forwarder is stored as an `immutable` variable, meaning
 *      it is baked into the **implementation bytecode** at deployment time rather than
 *      written to storage. This is fully compatible with the Transparent Proxy pattern:
 *      when the proxy `delegatecall`s the implementation, the immutable is read directly
 *      from the implementation's code, not from the proxy's storage. The forwarder
 *      therefore cannot be changed after deployment; a forwarder rotation requires
 *      deploying a new implementation and upgrading the proxy.
 *
 *      The forwarder address is passed to the constructor at implementation deployment
 *      time. `initialize()` does not need to handle it.
 *
 *      `_msgSender()`, `_msgData()`, and `_contextSuffixLength()` are overridden to
 *      resolve the compiler ambiguity between `ContextUpgradeable` and
 *      `ERC2771ContextUpgradeable` in the multiple-inheritance graph.
 *
 * @dev ## Decimals
 *
 *      This token uses 6 decimal places, overriding the OZ default of 18.
 *      All `amount` parameters throughout this contract are expressed in this
 *      smallest unit (1e-6 of one token).
 *
 * @dev ## Storage layout & upgrade safety
 *
 *      Three custom storage variables are declared:
 *        - `_blacklisted`       (1 slot) — blacklist mapping
 *        - `_contractURI`       (1 slot) — on-chain product metadata URI
 *        - `_seizureInProgress` (1 slot) — transient seizure guard flag
 *      The trusted forwarder is stored as an `immutable` in the OZ v4.9.4 implementation
 *      and does NOT occupy a storage slot in this contract.
 *      A `__gap[47]` array reserves 47 additional slots (total 50), leaving room
 *      for future state variables without disturbing the inherited storage layout.
 *      Any new variable added in a future version MUST consume a slot from `__gap`
 *      by reducing its size accordingly (e.g. `__gap[46]`).
 *
 * @dev ## Last-role protection
 *
 *      Both `renounceRole` and `revokeRole` are overridden to prevent any role from
 *      becoming empty. If the operation would remove the last remaining holder of a
 *      given role, the transaction reverts with `CannotRenounceLastRole`.
 *      This guards against accidental loss of administrative control whether triggered
 *      voluntarily (renounce) or by an admin acting on a peer (revoke).
 *
 */
contract EURXT is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    PausableUpgradeable,
    AccessControlEnumerableUpgradeable,
    ERC2771ContextUpgradeable
{
    // =========================================================
    // Roles
    // =========================================================

    /// @notice Role required to pause and unpause all token transfers.
    /// @dev keccak256("PAUSER_ROLE"). Holders act as emergency circuit-breakers.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role required to mint new tokens.
    /// @dev keccak256("MINTER_ROLE"). Should be granted only to the
    ///      custodian / treasury contract that manages reserve backing.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role required to burn tokens on behalf of any address.
    /// @dev keccak256("BURNER_ROLE"). Used for redemptions: the burn agent
    ///      destroys on-chain tokens after verifying fiat withdrawal.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Role required to rescue ERC-20 tokens accidentally sent to this contract.
    /// @dev keccak256("RESCUER_ROLE"). Cannot recover the token itself
    ///      (guarded by `InvalidTokenAddress`).
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @notice Role required to blacklist or unblacklist addresses.
    /// @dev keccak256("BLACKLIST_ADMIN_ROLE"). Blacklisting blocks an address
    ///      from sending, receiving, minting, and burning tokens, and enables
    ///      forced seizure of their balance via `seizeBlacklistedFunds`.
    bytes32 public constant BLACKLIST_ADMIN_ROLE =
        keccak256("BLACKLIST_ADMIN_ROLE");

    // =========================================================
    // Supply cap
    // =========================================================

    /// @notice Maximum number of tokens that can ever be in circulation.
    /// @dev 5 billion tokens expressed in the smallest unit (6 decimals).
    ///      5_000_000_000 × 1_000_000 = 5_000_000_000_000_000
    uint256 public constant MAX_SUPPLY = 5_000_000_000 * 10 ** 6;

    // =========================================================
    // Storage
    // =========================================================

    /// @dev Maps an address to its blacklist status.
    ///      Blacklisted addresses cannot be the sender or recipient of any
    ///      token movement, including mint and burn operations.
    mapping(address => bool) private _blacklisted;

    /// @dev On-chain product metadata URI (ERC-7572 / contractURI convention).
    ///      Points to a JSON document describing the token: issuer name, asset
    ///      description, regulatory contact, prospectus link, etc.
    string private _contractURI;

    /// @dev Seizure guard flag, set to `true` for the duration of a
    ///      `seizeBlacklistedFunds` call and reset to `false` immediately after.
    ///
    ///      Purpose: `_beforeTokenTransfer` normally blocks any transfer whose sender
    ///      is blacklisted. During a regulatory seizure the source address is, by
    ///      definition, blacklisted. Setting this flag allows `_beforeTokenTransfer`
    ///      to skip the *sender* blacklist check for that single internal `_transfer`
    ///      call, without removing the address from the blacklist and without bypassing
    ///      either the pause check or the *recipient* blacklist check.
    ///
    ///      Reentrancy safety: `ERC20Upgradeable._transfer` performs no external calls,
    ///      so there is no callback vector between the `true` and `false` assignments.
    ///      The flag therefore behaves as a call-stack-scoped boolean rather than a
    ///      persistent mutex.
    bool private _seizureInProgress;

    /**
     * @dev Storage gap for future upgrades.
     *      This contract occupies 3 custom slots:
     *        - `_blacklisted`       (mapping, 1 slot)
     *        - `_contractURI`       (string,  1 slot)
     *        - `_seizureInProgress` (bool,    1 slot)
     *      The gap reserves 47 additional slots to reach a total of 50,
     *      keeping the storage layout compatible with future implementation versions.
     *
     *      Convention: when adding a new state variable `foo` in a future upgrade,
     *      declare it here and reduce `__gap` by the corresponding number of slots:
     *
     *        uint256 public foo;        // 1 slot consumed
     *        uint256[46] private __gap; // was [47]
     */
    uint256[47] private __gap;

    // =========================================================
    // Events
    // =========================================================

    /// @notice Emitted when an address is added to the blacklist.
    /// @param account The address that was blacklisted.
    event Blacklisted(address indexed account);

    /// @notice Emitted when an address is removed from the blacklist.
    /// @param account The address that was unblacklisted.
    event UnBlacklisted(address indexed account);

    /// @notice Emitted when tokens are forcibly seized from a blacklisted address.
    /// @param from    The blacklisted address whose tokens were seized.
    /// @param to      The destination address that received the seized tokens.
    /// @param amount  The number of tokens seized.
    event BlacklistedFundsSeized(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when the contract URI is updated.
    /// @param newURI The new metadata URI.
    event ContractURIUpdated(string newURI);

    // =========================================================
    // Constructor
    // =========================================================

    /**
     * @dev Sets the trusted forwarder and permanently locks the implementation
     *      against direct initialization.
     *
     *      In a Transparent Proxy setup the implementation contract is deployed
     *      standalone and must never be initialized directly, as an attacker
     *      could call `initialize` on the bare implementation and take control
     *      of it (though this does not affect the proxy state).
     *
     *      In OZ v4.9.4, `ERC2771ContextUpgradeable` stores the forwarder as an
     *      `immutable`, which means it is baked into the implementation bytecode at
     *      compile time. When the proxy `delegatecall`s this implementation, the
     *      immutable is read directly from the implementation's code segment and is
     *      therefore correctly available at runtime without occupying a storage slot.
     *      This is the canonical OZ v4.9.4 pattern for ERC-2771 + Transparent Proxy.
     *
     *      Consequence: the forwarder cannot be rotated without deploying a new
     *      implementation. This is an accepted trade-off for the OZ v4.9.x release line.
     *
     *      `_disableInitializers()` sets the initializer version to `type(uint8).max`,
     *      permanently blocking any future call to `initializer`-guarded functions
     *      on this specific deployment.
     *
     * @param trustedForwarder_ Address of the EIP-2771 trusted forwarder.
     *                          Stored as an immutable in the implementation bytecode.
     *                          Must not be address(0).
     *
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        if (trustedForwarder_ == address(0)) revert LibErrors.ZeroAddress();
        _disableInitializers();
    }

    // =========================================================
    // Initializer
    // =========================================================

    /**
     * @notice Initializes the token and grants the initial admin role.
     *
     * @dev Replaces the constructor for upgradeable contracts. Must be called
     *      exactly once, immediately after proxy deployment, via the proxy address.
     *
     *      Pre-conditions:
     *        1. `admin` must not be address(0).
     *
     *      Initialization order follows OZ recommendations:
     *        1. ERC-20 base — name ("Euro eXchange Token") and symbol ("EURXT")
     *           are hardcoded literals; decimals are fixed at 6, see `decimals()`.
     *        2. ERC-20 Permit — EIP-712 domain separator bound to the token name
     *           and the current chain ID.
     *        3. Pausable — sets paused = false.
     *        4. AccessControl — no-op but required for __gap alignment.
     *
     *      The trusted forwarder is NOT initialized here. In OZ v4.9.4,
     *      `ERC2771ContextUpgradeable` stores it as an `immutable` set at construction
     *      time (see constructor). No init call is required or available.
     *
     *      Only `DEFAULT_ADMIN_ROLE` is granted to `admin` at deployment.
     *      All other operational roles (PAUSER_ROLE, MINTER_ROLE, BURNER_ROLE,
     *      RESCUER_ROLE, BLACKLIST_ADMIN_ROLE) must be granted explicitly afterwards
     *      via `grantRole`. In production, `admin` MUST be a Gnosis Safe or equivalent
     *      multi-sig to enforce n-of-m approval for sensitive operations.
     *
     * @param admin Address receiving DEFAULT_ADMIN_ROLE. Must not be address(0).
     *
     * @custom:throws LibErrors.ZeroAddress if `admin` is address(0).
     */
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert LibErrors.ZeroAddress();

        __ERC20_init("Euro eXchange Token", "EURXT");
        __ERC20Permit_init("Euro eXchange Token");
        __Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // =========================================================
    // ERC-20 metadata overrides
    // =========================================================

    /**
     * @notice Returns the number of decimals used to represent token amounts.
     *
     * @dev Overrides the OZ default of 18 to use 6 decimal places, matching the
     *      convention of major fiat-backed stablecoins (USDC, USDT, EURC).
     *      With 6 decimals, the smallest representable unit is 0.000001 of one token.
     *      For example, 1 EURXT is represented on-chain as 1_000_000.
     *
     *      All `amount` parameters in `mint`, `burn`, `transfer`,
     *      `seizeBlacklistedFunds`, and `rescueERC20` are expressed in this unit.
     *
     * @return 6
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // =========================================================
    // Mint / Burn
    // =========================================================

    /**
     * @notice Mints `amount` tokens and assigns them to `to`.
     *
     * @dev Increases total supply. The operation is gated by three pre-conditions
     *      checked before the OZ `_mint` call:
     *        1. `to` must not be the zero address (prevents supply inflation with no owner).
     *        2. `to` must not be blacklisted (compliance requirement).
     *        3. `amount` must be non-zero (no-op protection).
     *        4. `totalSupply() + amount` must not exceed `MAX_SUPPLY`.
     *
     *      `_mint` internally calls `_beforeTokenTransfer(address(0), to, amount)`,
     *      which re-checks pause and blacklist state as a second line of defence.
     *
     * @param to     Recipient address. Must be non-zero and non-blacklisted.
     * @param amount Number of tokens to mint, expressed in the smallest unit (6 decimals).
     *               Pass 1_000_000 to mint exactly 1 token.
     *
     * @custom:access Restricted to `MINTER_ROLE`.
     * @custom:emits  {Transfer} with `from` = address(0) (OZ ERC-20 standard).
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        LibModifiers.checkNonZero(to);
        if (_blacklisted[to]) revert LibErrors.Blacklisted(to);
        LibModifiers.checkNonZeroAmount(amount);

        if (totalSupply() + amount > MAX_SUPPLY)
            revert LibErrors.SupplyCapExceeded(
                totalSupply() + amount,
                MAX_SUPPLY
            );

        _mint(to, amount);
    }

    /**
     * @notice Burns `amount` tokens from address `from`, reducing total supply.
     *
     * @dev Used for fiat redemptions: the burn agent destroys on-chain tokens
     *      after the corresponding fiat withdrawal has been verified off-chain.
     *
     *      Pre-conditions:
     *        1. `from` must not be the zero address.
     *        2. `from` must not be blacklisted (a compliance freeze also blocks
     *           redemptions until the blacklist is lifted).
     *        3. `amount` must be non-zero.
     *
     *      `_burn` internally calls `_beforeTokenTransfer(from, address(0), amount)`,
     *      which re-checks pause and blacklist state.
     *
     * @param from   Address whose tokens will be destroyed.
     * @param amount Number of tokens to burn, expressed in the smallest unit (6 decimals).
     *               Pass 1_000_000 to burn exactly 1 token.
     *
     * @custom:access Restricted to `BURNER_ROLE`.
     * @custom:emits  {Transfer} with `to` = address(0) (OZ ERC-20 standard).
     */
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        LibModifiers.checkNonZero(from);
        if (_blacklisted[from]) revert LibErrors.Blacklisted(from);
        LibModifiers.checkNonZeroAmount(amount);
        _burn(from, amount);
    }

    // =========================================================
    // Pause
    // =========================================================

    /**
     * @notice Pauses all token transfers, mints, and burns.
     *
     * @dev Sets the internal `_paused` flag to `true`. Every subsequent call to
     *      `_beforeTokenTransfer` will revert with `LibErrors.TokenPaused` until
     *      `unpause` is called.
     *
     *      Intended for emergency scenarios (exploit response, regulatory freeze,
     *      infrastructure incident). Should require multi-sig approval in production.
     *
     *      Note: the pause also blocks `seizeBlacklistedFunds`. This is intentional —
     *      the PAUSER_ROLE retains full freeze authority even over seizure operations.
     *
     * @custom:access Restricted to `PAUSER_ROLE`.
     * @custom:emits  {Paused} (OZ Pausable standard).
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes all token transfers, mints, and burns.
     *
     * @dev Clears the `_paused` flag. Reverts if the contract is not currently paused.
     *
     * @custom:access Restricted to `PAUSER_ROLE`.
     * @custom:emits  {Unpaused} (OZ Pausable standard).
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================
    // Role management — last-member protection
    // =========================================================

    /**
     * @notice Allows a role member to voluntarily relinquish their role,
     *         unless they are the last remaining holder of that role.
     *
     * @dev Overrides `AccessControlUpgradeable.renounceRole` to add a last-member
     *      guard. Without this protection, the sole DEFAULT_ADMIN_ROLE holder could
     *      accidentally call `renounceRole`, permanently locking the contract with
     *      no way to grant or revoke any role.
     *
     *      The guard uses `getRoleMemberCount(role)` from
     *      `AccessControlEnumerableUpgradeable`, which maintains an on-chain
     *      EnumerableSet of members per role. If the count is 1 or less, the
     *      transaction reverts with `CannotRenounceLastRole`.
     *
     *      If `account` does not hold `role`, the function returns early without
     *      reverting (no-op), consistent with the OZ base behaviour for non-members.
     *
     *      Note: this override lists both `AccessControlUpgradeable` and
     *      `IAccessControlUpgradeable` because both declare `renounceRole`
     *      in the inheritance graph visible to the compiler.
     *
     * @param role    The `bytes32` identifier of the role to renounce.
     * @param account The address renouncing the role. Must equal `msg.sender`
     *                (enforced by the OZ base implementation).
     *
     * @custom:throws LibErrors.CannotRenounceLastRole if `getRoleMemberCount(role) <= 1`.
     * @custom:emits  {RoleRevoked} on success (OZ AccessControl standard).
     */
    function renounceRole(
        bytes32 role,
        address account
    ) public override(AccessControlUpgradeable, IAccessControlUpgradeable) {
        if (!hasRole(role, account)) return;
        if (getRoleMemberCount(role) <= 1) {
            revert LibErrors.CannotRenounceLastRole(role);
        }
        super.renounceRole(role, account);
    }

    /**
     * @notice Revokes `role` from `account`, unless `account` is the last
     *         remaining holder of that role.
     *
     * @dev Overrides `AccessControlUpgradeable.revokeRole` to apply the same
     *      last-member guard as `renounceRole`. Without this override an admin
     *      could call `revokeRole` to remove the sole holder of any role —
     *      including DEFAULT_ADMIN_ROLE — permanently bricking the contract.
     *
     *      The guard uses `getRoleMemberCount(role)` from
     *      `AccessControlEnumerableUpgradeable`. If the count is 1 or less, the
     *      transaction reverts with `CannotRenounceLastRole` (same error as
     *      `renounceRole`, as both represent the same invariant violation).
     *
     *      If `account` does not hold `role`, the function returns early without
     *      reverting (no-op), consistent with the OZ base behaviour for non-members.
     *
     *      Note: this override lists both `AccessControlUpgradeable` and
     *      `IAccessControlUpgradeable` because both declare `revokeRole`
     *      in the inheritance graph visible to the compiler.
     *
     * @param role    The `bytes32` identifier of the role to revoke.
     * @param account The address being revoked. The caller must hold the admin
     *                role for `role` (enforced by the OZ base implementation).
     *
     * @custom:throws LibErrors.CannotRenounceLastRole if `getRoleMemberCount(role) <= 1`.
     * @custom:emits  {RoleRevoked} on success (OZ AccessControl standard).
     */
    function revokeRole(
        bytes32 role,
        address account
    ) public override(AccessControlUpgradeable, IAccessControlUpgradeable) {
        if (!hasRole(role, account)) return;
        if (getRoleMemberCount(role) <= 1) {
            revert LibErrors.CannotRenounceLastRole(role);
        }
        super.revokeRole(role, account);
    }

    // =========================================================
    // Rescue
    // =========================================================

    /**
     * @notice Recovers ERC-20 tokens accidentally sent to this contract's address.
     *
     * @dev Token contracts sometimes receive ERC-20 deposits by mistake (e.g. a user
     *      copies the wrong address). This function allows a designated rescuer to
     *      retrieve those tokens and forward them to a safe destination.
     *
     *      Safety guards:
     *        - `to` must be non-zero (no burning via rescue).
     *        - `token` must be non-zero.
     *        - `token` must not be `address(this)`: rescuing the native token
     *          would allow the RESCUER_ROLE to drain the circulating supply,
     *          which is outside the scope of this function.
     *        - `amount` must be non-zero.
     *
     *      Uses `SafeERC20.safeTransfer` to handle tokens that do not return a
     *      boolean on `transfer` (non-standard ERC-20 implementations).
     *
     * @param token  Address of the ERC-20 token to recover. Must not be this contract.
     * @param to     Destination address for the recovered tokens.
     * @param amount Amount of tokens to transfer, in the rescued token's own smallest unit.
     *
     * @custom:access Restricted to `RESCUER_ROLE`.
     */
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(RESCUER_ROLE) {
        LibModifiers.checkNonZero(to);
        LibModifiers.checkNonZero(token);
        if (token == address(this)) revert LibErrors.InvalidTokenAddress(token);
        if (amount == 0) revert LibErrors.RescueAmountZero();

        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    // =========================================================
    // Blacklist
    // =========================================================

    /**
     * @notice Returns whether `account` is currently blacklisted.
     *
     * @dev Pure storage read. Used off-chain (compliance dashboards, front-ends)
     *      and on-chain by mint/burn guards and `_beforeTokenTransfer`.
     *
     * @param account Address to query.
     * @return True if `account` is blacklisted, false otherwise.
     */
    function isBlacklisted(address account) public view returns (bool) {
        return _blacklisted[account];
    }

    /**
     * @notice Adds `account` to the blacklist, blocking all token operations.
     *
     * @dev Once blacklisted, an address cannot send, receive, mint, or burn tokens.
     *      The block is enforced at three layers:
     *        1. Explicit checks in `mint` and `burn`.
     *        2. `_beforeTokenTransfer` hook for all ERC-20 movements.
     *        3. (Allowances created via `approve`/`permit` are NOT blocked at
     *           creation time — only the subsequent `transferFrom` is blocked.)
     *
     *      Reverts if `account` is already blacklisted to prevent redundant events
     *      and to surface accidental double-calls.
     *
     * @param account Address to blacklist. Must be non-zero and not already blacklisted.
     *
     * @custom:access Restricted to `BLACKLIST_ADMIN_ROLE`.
     * @custom:emits  {Blacklisted}.
     */
    function blacklist(
        address account
    ) external onlyRole(BLACKLIST_ADMIN_ROLE) {
        LibModifiers.checkNonZero(account);
        if (_blacklisted[account]) revert LibErrors.AlreadyBlacklisted(account);
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Removes `account` from the blacklist, restoring normal token operations.
     *
     * @dev Reverts if `account` is not currently blacklisted, ensuring idempotency
     *      is handled explicitly rather than silently.
     *
     * @param account Address to unblacklist. Must be currently blacklisted.
     *
     * @custom:access Restricted to `BLACKLIST_ADMIN_ROLE`.
     * @custom:emits  {UnBlacklisted}.
     */
    function unblacklist(
        address account
    ) external onlyRole(BLACKLIST_ADMIN_ROLE) {
        LibModifiers.checkNonZero(account);
        if (!_blacklisted[account]) revert LibErrors.NotBlacklisted(account);
        _blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /**
     * @notice Forcibly transfers tokens held by a blacklisted address to a safe destination.
     *
     * @dev Implements the regulatory seizure / asset recovery use case: once an address
     *      has been blacklisted (e.g. following a court order, sanction, or fraud detection),
     *      its funds can be moved to a compliant destination without requiring any action
     *      from the blacklisted party.
     *
     *      Because `_beforeTokenTransfer` blocks any movement involving a blacklisted sender,
     *      this function sets `_seizureInProgress = true` before calling `_transfer` and
     *      resets it to `false` immediately after. This instructs `_beforeTokenTransfer`
     *      to skip the sender blacklist check for that single call. The blacklisted address
     *      is NOT removed from the blacklist at any point: it remains blacklisted throughout
     *      and after the seizure.
     *
     *      What IS bypassed:     sender blacklist check only.
     *      What is NOT bypassed: pause check, recipient blacklist check.
     *
     *      Reentrancy safety: `ERC20Upgradeable._transfer` performs no external calls,
     *      so no reentrant path can observe or exploit the `_seizureInProgress = true`
     *      window.
     *
     *      Pre-conditions:
     *        1. `from` must currently be blacklisted — seizure is only meaningful in
     *           that context and guards against misuse of this privileged function.
     *        2. `to` must be non-zero and must not itself be blacklisted.
     *        3. `amount` must be non-zero and must not exceed `from`'s balance.
     *
     * @param from   Blacklisted address whose tokens are to be seized.
     * @param to     Destination address. Must be non-zero and non-blacklisted.
     * @param amount Number of tokens to seize, in the smallest unit (6 decimals).
     *               Must be > 0 and <= balanceOf(from).
     *
     * @custom:access Restricted to `BLACKLIST_ADMIN_ROLE`.
     * @custom:emits  {Transfer} from `from` to `to` (OZ ERC-20 standard).
     * @custom:emits  {BlacklistedFundsSeized}.
     */
    function seizeBlacklistedFunds(
        address from,
        address to,
        uint256 amount
    ) external onlyRole(BLACKLIST_ADMIN_ROLE) {
        if (!_blacklisted[from]) revert LibErrors.NotBlacklisted(from);
        LibModifiers.checkNonZero(to);
        if (_blacklisted[to]) revert LibErrors.Blacklisted(to);
        LibModifiers.checkNonZeroAmount(amount);
        if (amount > balanceOf(from))
            revert LibErrors.InsufficientBalance(from, amount);

        _seizureInProgress = true;
        _transfer(from, to, amount);
        _seizureInProgress = false;

        emit BlacklistedFundsSeized(from, to, amount);
    }

    // =========================================================
    // Contract metadata (ERC-7572 / contractURI convention)
    // =========================================================

    /**
     * @notice Updates the on-chain metadata URI for this token.
     *
     * @dev Stores a URI pointing to a JSON document that describes the token from
     *      an issuer and regulatory perspective. Typical fields include: legal name
     *      of the issuer, asset description, regulatory contact, prospectus or
     *      offering document link, and ISIN / LEI identifiers where applicable.
     *
     *      This follows the `contractURI()` convention popularised by OpenSea and
     *      formalised in ERC-7572. No on-chain validation is performed on the URI
     *      format: the caller is responsible for ensuring it resolves to a valid,
     *      publicly accessible JSON document.
     *
     *      Emits `ContractURIUpdated` so that off-chain indexers (block explorers,
     *      compliance dashboards) can detect and refresh cached metadata.
     *
     * @param newURI The new metadata URI. May be an HTTPS URL or an IPFS CID URI
     *               (e.g. "ipfs://Qm..."). An empty string effectively clears the URI.
     *
     * @custom:access Restricted to `DEFAULT_ADMIN_ROLE`.
     * @custom:emits  {ContractURIUpdated}.
     */
    function setContractURI(
        string calldata newURI
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _contractURI = newURI;
        emit ContractURIUpdated(newURI);
    }

    /**
     * @notice Returns the on-chain metadata URI for this token.
     *
     * @dev Implements the `contractURI()` convention (ERC-7572). Returns an empty
     *      string if no URI has been set yet.
     *
     * @return The metadata URI string, or an empty string if unset.
     */
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    // =========================================================
    // Internal hooks
    // =========================================================

    /**
     * @notice Central control point invoked before every token movement.
     *
     * @dev This hook is called by `_transfer`, `_mint`, and `_burn` in
     *      `ERC20Upgradeable` before any balance update. Centralising access
     *      control here ensures no standard code path can bypass the pause or
     *      blacklist checks.
     *
     *      Enforcement order:
     *        1. **Pause check** — reverts with `LibErrors.TokenPaused` if the
     *           contract is paused. Applied unconditionally to all callers,
     *           including seizure operations.
     *        2. **Sender blacklist** — skipped when `from == address(0)` (mint).
     *           Also skipped when `_seizureInProgress == true`, which is set
     *           exclusively by `seizeBlacklistedFunds` to allow a controlled
     *           transfer out of a blacklisted address. In all other cases, a
     *           blacklisted sender causes a revert with `LibErrors.Blacklisted`.
     *        3. **Recipient blacklist** — skipped when `to == address(0)` (burn).
     *           Never bypassed, including during seizure.
     *
     *      The `super._beforeTokenTransfer` call propagates the hook to
     *      `ERC20Upgradeable` (which does nothing by default in OZ v4) and is
     *      included for correctness in case of future library updates.
     *
     * @param from   Token sender. address(0) for mints.
     * @param to     Token recipient. address(0) for burns.
     * @param amount Amount of tokens being moved (unused here, passed to super).
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        LibModifiers.checkNotPaused(paused());

        if (!_seizureInProgress) {
            if (from != address(0) && _blacklisted[from]) {
                revert LibErrors.Blacklisted(from);
            }
        }

        if (to != address(0) && _blacklisted[to]) {
            revert LibErrors.Blacklisted(to);
        }

        super._beforeTokenTransfer(from, to, amount);
    }

    // =========================================================
    // ERC-2771 context overrides
    // =========================================================

    /**
     * @notice Returns the effective sender of the current call.
     *
     * @dev Overrides both `ContextUpgradeable` and `ERC2771ContextUpgradeable` to
     *      resolve the compiler ambiguity introduced by multiple inheritance.
     *      When the call originates from the trusted forwarder, the actual sender
     *      is extracted from the last 20 bytes of calldata (EIP-2771 convention).
     *      For direct calls, returns `msg.sender` as usual.
     *
     *      All access control checks in this contract rely on `_msgSender()` rather
     *      than `msg.sender` directly, ensuring meta-transactions are correctly
     *      authenticated throughout.
     */
    function _msgSender()
        internal
        view
        override(ERC2771ContextUpgradeable, ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Returns the effective calldata of the current call.
     *
     * @dev Overrides both `ContextUpgradeable` and `ERC2771ContextUpgradeable` to
     *      resolve the compiler ambiguity. When called via the trusted forwarder,
     *      the appended sender address (last 20 bytes) is stripped from the returned
     *      calldata slice, exposing only the original payload.
     */
    function _msgData()
        internal
        view
        override(ERC2771ContextUpgradeable, ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Returns the number of bytes appended to calldata by the trusted forwarder.
     *
     * @dev Overrides both `ContextUpgradeable` and `ERC2771ContextUpgradeable` to
     *      resolve the compiler ambiguity. Returns 20 when called via the trusted
     *      forwarder (the size of an appended `address`), and 0 otherwise.
     *      Used internally by `_msgSender` and `_msgData` to correctly slice calldata.
     */
    function _contextSuffixLength()
        internal
        view
        override(ERC2771ContextUpgradeable, ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    // =========================================================
    // ERC-165 interface detection
    // =========================================================

    /**
     * @notice Returns true if this contract implements the interface defined by `interfaceId`.
     *
     * @dev Implements ERC-165 interface detection.
     *
     *      Explicitly registers the following interfaces:
     *        - `IERC20Upgradeable`         — standard ERC-20 functions
     *        - `IERC20MetadataUpgradeable` — name(), symbol(), decimals()
     *        - `IERC20PermitUpgradeable`   — EIP-2612 permit()
     *        - `IAccessControlUpgradeable` — hasRole(), grantRole(), etc.
     *
     *      Falls back to `super.supportsInterface` which resolves:
     *        - `AccessControlEnumerableUpgradeable` (IAccessControlEnumerable)
     *        - `ERC165Upgradeable` (ERC-165 itself, interfaceId = 0x01ffc9a7)
     *
     * @param interfaceId The 4-byte interface selector to query.
     * @return True if the interface is supported.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IERC20Upgradeable).interfaceId ||
            interfaceId == type(IERC20MetadataUpgradeable).interfaceId ||
            interfaceId == type(IERC20PermitUpgradeable).interfaceId ||
            interfaceId == type(IAccessControlUpgradeable).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}