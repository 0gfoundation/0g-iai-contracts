// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IIAIVault} from "./interfaces/IIAIVault.sol";
import {IIAI} from "./interfaces/IIAI.sol";
import {IA0G} from "./interfaces/external/IA0G.sol";
import {IA0GOracle} from "./interfaces/external/IA0GOracle.sol";
import {IMintCurve} from "./interfaces/IMintCurve.sol";

/**
 * @title IAIVault
 * @notice Escrows a0G collateral, issues iAI against a rising linear curve, redeems the
 *         original minter at their weighted-average entry rate, and sweeps the collateral's
 *         appreciation to the foundation.
 *
 * @dev Custody and logic live in one contract on purpose. The solvency property — that the
 *      vault always holds at least what it owes — is then a statement about a single
 *      contract's own storage and balance, with no cross-contract atomicity gap and no
 *      "vault trusts controller" indirection to get wrong.
 *
 *      **Two conversions, not one.** The curve prices in 0G *value*; the collateral is a0G,
 *      which is worth a moving amount of 0G. Only the 0G value is recorded. Recording the
 *      a0G amount instead would make the position's worth depend on when it was opened.
 *
 *      **Rounding always favours the vault**: value flowing in rounds up, value flowing out
 *      rounds down. That single rule is what makes the solvency invariant hold across every
 *      interleaving of mint, redeem and harvest, and it also means splitting a mint into
 *      pieces is never cheaper than doing it at once.
 *
 *      **Redemption is never pausable.** `pause()` stops issuance and harvesting; it must
 *      never be able to trap collateral. Redemption also takes no oracle-independent path
 *      around a stale price — that dependency is accepted and documented, not silently
 *      worked around.
 */
contract IAIVault is IIAIVault, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IA0G;

    uint256 private constant WAD = 1e18;

    /// @notice May pause issuance. Deliberately weaker than admin: it can stop, not release.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @notice May settle another address's position on their behalf.
     * @dev Exists because redemption requires holding the tokens *and* owning the position.
     *      A minter who sends their iAI somewhere unrecoverable would otherwise strand their
     *      collateral forever, with no authority able to help. The abuse surface is closed by
     *      construction rather than by trust: the collateral always goes to the position
     *      owner, never to the caller, so the role can force a settlement but can never
     *      take anything.
     */
    bytes32 public constant RESCUE_ROLE = keccak256("RESCUE_ROLE");

    /**
     * @dev Hard bound on the supply the vault will price at, independent of what a curve
     *      claims. `cost` implementations multiply supply-sized quantities outside a
     *      512-bit helper; at `2**127` even a squared term stays inside uint256. Applied
     *      alongside `curve.maxSafeSupply()` so a curve reporting an absurd domain cannot
     *      widen it.
     */
    uint256 private constant ABSOLUTE_SUPPLY_BOUND = 2 ** 127;

    /// @custom:storage-location erc7201:0g.iai.IAIVault
    struct VaultStorage {
        /// The curve in force. Swappable: see `setCurve`.
        IMintCurve curve;
        /// Supply ceiling. Adjustable in both directions: see `setCap`.
        uint256 cap;
        address foundation;
        IIAI iai;
        IA0G a0G;
        IA0GOracle oracle;
        uint256 totalLocked0G;
        mapping(address => Position) positions;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.iai.IAIVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultStorageLocation =
        0xc43d9fb2bb2c47f512fbd0909174d2bc8dc8e1a97639c38f8e1d6ca9884b0600;

    function _s() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VaultStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Wires the vault to its token, collateral and curve.
     * @param p Deployment parameters; see `IIAIVault.InitParams`.
     *
     * @dev Starts **paused**: issuance opens on an explicit governance transaction, which is
     *      also the only launch-timing control the contract needs. Redemption is unaffected.
     *
     *      The oracle address is read from a0G once and cached. Upstream has no setter for
     *      it, so caching costs nothing and removes a hop from every priced call.
     */
    function initialize(InitParams calldata p) external initializer {
        if (p.iai == address(0) || p.a0G == address(0) || p.foundation == address(0)) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        VaultStorage storage $ = _s();
        $.iai = IIAI(p.iai);
        $.a0G = IA0G(p.a0G);
        $.foundation = p.foundation;
        // `_setCurve` validates the cap against the incoming curve's domain, so `_setCap`
        // has nothing left to check here -- it only needs to store the value.
        _setCurve($, IMintCurve(p.curve), p.cap);
        $.cap = p.cap;

        // Emitted from the zero value, so the log stream alone carries the starting curve and
        // ceiling. Without these an indexer would have to read the chain to learn where the
        // later `CurveUpdated` / `CapUpdated` deltas began.
        emit CurveUpdated(address(0), p.curve);
        emit CapUpdated(0, p.cap);

        IA0GOracle o = IA0G(p.a0G).oracle();
        if (address(o) == address(0)) revert ZeroAddress();
        $.oracle = o;

        _pause();
    }

    // -------------------------------------------------------------------------
    // Issuance
    // -------------------------------------------------------------------------

    /**
     * @notice Locks a0G and mints exactly `d` iAI.
     * @param d        Amount of iAI to mint, in wei-iAI. The caller names the output; the
     *                 input follows from the curve and the exchange rate.
     * @param maxA0GIn Maximum a0G the caller is willing to hand over, in wei-a0G. The whole
     *                 slippage bound: both risks the caller faces -- someone minting ahead
     *                 and pushing the curve up, and the a0G rate moving between quote and
     *                 execution -- land on this one number, because it is what actually
     *                 leaves the caller's wallet.
     * @param deadline Latest block timestamp at which the caller still accepts execution,
     *                 in seconds. Bounds how long a signed transaction may sit in the
     *                 mempool while the price moves.
     */
    function mint(uint256 d, uint256 maxA0GIn, uint256 deadline) external nonReentrant whenNotPaused {
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (d == 0) revert ZeroAmount();

        VaultStorage storage $ = _s();

        uint256 s = $.iai.totalSupply();
        uint256 supplyAfter = s + d;
        if (supplyAfter > $.cap) revert CapExceeded(supplyAfter, $.cap);

        uint256 delta0G = $.curve.cost(s, d);
        // A curve returning zero would hand out free iAI: the recipient could claim compute
        // for nothing, and the supply the vault prices against would inflate permanently.
        // Enforced here so it is a property of the vault, not a promise from the curve.
        if (delta0G == 0) revert ZeroAmount();
        uint256 er = $.oracle.getValue();
        uint256 a0GIn = Math.mulDiv(delta0G, WAD, er, Math.Rounding.Ceil);
        if (a0GIn > maxA0GIn) revert ExcessiveInput(a0GIn, maxA0GIn);

        // State first, external calls last.
        Position storage pos = $.positions[_msgSender()];
        pos.locked0G += delta0G;
        pos.iaiOutstanding += d;
        uint256 totalAfter = $.totalLocked0G + delta0G;
        $.totalLocked0G = totalAfter;

        // Payment first, then issuance. Both calls are in the same transaction, so ordering
        // cannot change the outcome of an honest mint -- but it decides who is exposed if a
        // future a0G upgrade ever calls back into this contract: taking the collateral first
        // means the vault is already paid at the moment any such callback could run.
        // a0G is an ERC-4626 share with a plain ERC-20 transfer; `SafeERC20` already reverts
        // unless the full amount moves.
        $.a0G.safeTransferFrom(_msgSender(), address(this), a0GIn);
        $.iai.mint(_msgSender(), d);

        emit Minted(_msgSender(), d, delta0G, a0GIn, er, supplyAfter, totalAfter);
    }

    // -------------------------------------------------------------------------
    // Redemption
    // -------------------------------------------------------------------------

    /**
     * @notice Burns `b` of the caller's iAI and returns the matching slice of their collateral.
     * @param b        Amount of iAI to burn, in wei-iAI. Releases the same fraction of the
     *                 caller's locked 0G, priced at the position's own average.
     * @param deadline Latest block timestamp at which the caller still accepts execution,
     *                 in seconds.
     *
     * @dev Not pausable, by design.
     *
     *      There is no minimum-output bound, and adding one would protect nothing. The
     *      released amount is fixed in 0G; the a0G it converts to only shrinks as a0G
     *      appreciates, so waiting is always worse than executing and there is no adverse
     *      move to be surprised by. `deadline` already bounds the drift a pending
     *      transaction can accumulate.
     *
     *      No harvest is required first: the payout is derived from the position's recorded
     *      0G value rather than from a share of the vault balance, so yield accrued but not
     *      yet swept cannot leave with a redeemer.
     */
    function burn(uint256 b, uint256 deadline) external nonReentrant {
        _settle(_msgSender(), _msgSender(), b, deadline);
    }

    /**
     * @notice Settles `minter`'s position using iAI supplied by the caller.
     * @param minter   Owner of the position to settle, and the address the collateral is
     *                 sent to. Never the caller.
     * @param b        Amount of iAI to burn, in wei-iAI, taken from the caller's balance.
     * @param deadline Latest block timestamp at which the caller still accepts execution,
     *                 in seconds.
     *
     * @dev The caller provides the tokens; **the collateral goes to `minter`**. That
     *      direction is what makes the role safe to hold: it can unwind a position but
     *      cannot redirect a single wei of it.
     */
    function burnFor(address minter, uint256 b, uint256 deadline)
        external
        nonReentrant
        onlyRole(RESCUE_ROLE)
    {
        if (minter == address(0)) revert ZeroAddress();
        _settle(minter, _msgSender(), b, deadline);
    }

    /**
     * @param minter      Position owner; also always the recipient of the collateral.
     * @param tokenSource Address whose iAI is burned. Equals `minter` for a self-redemption.
     * @param b           Amount of iAI to burn, in wei-iAI.
     * @param deadline    Latest block timestamp at which the caller still accepts execution.
     */
    function _settle(address minter, address tokenSource, uint256 b, uint256 deadline) private {
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (b == 0) revert ZeroAmount();

        VaultStorage storage $ = _s();
        Position storage pos = $.positions[minter];
        uint256 outstanding = pos.iaiOutstanding;
        if (b > outstanding) revert BurnExceedsPosition(b, outstanding);

        uint256 s = $.iai.totalSupply();

        // Pro-rata against the position's own average. Floor: releasing less than the exact
        // share keeps the vault over-collateralised, and a full redemption (b == outstanding)
        // still clears the position to exactly zero.
        uint256 unlocked0G = Math.mulDiv(pos.locked0G, b, outstanding, Math.Rounding.Floor);

        uint256 er = $.oracle.getValue();
        uint256 a0GOut = Math.mulDiv(unlocked0G, WAD, er, Math.Rounding.Floor);

        pos.locked0G -= unlocked0G;
        pos.iaiOutstanding = outstanding - b;
        uint256 totalAfter = $.totalLocked0G - unlocked0G;
        $.totalLocked0G = totalAfter;
        uint256 supplyAfter = s - b;

        $.iai.burn(tokenSource, b);
        $.a0G.safeTransfer(minter, a0GOut);

        emit Burned(minter, tokenSource, b, unlocked0G, a0GOut, er, supplyAfter, totalAfter);
    }

    /**
     * @param $        Vault storage.
     * @param newCurve The curve to install.
     * @param capNow   The cap that must remain inside the new curve's safe domain.
     */
    function _setCurve(VaultStorage storage $, IMintCurve newCurve, uint256 capNow) private {
        if (address(newCurve) == address(0)) revert ZeroAddress();
        if (address(newCurve).code.length == 0) revert NotAContract(address(newCurve));
        _requireWithinDomain(newCurve, capNow);
        $.curve = newCurve;
    }

    /**
     * @param $      Vault storage.
     * @param newCap The ceiling to install.
     */
    function _setCap(VaultStorage storage $, uint256 newCap) private {
        // Only a raise can leave the domain: the cap is already inside it, and both setters
        // keep it there. Skipping the check when lowering is not an optimisation -- it is
        // what keeps `setCap(0)` reachable when the curve in force reverts on every call.
        // Otherwise closing issuance would depend on the very contract that has broken, and
        // the only way out would be to first install a working curve.
        if (newCap > $.cap) _requireWithinDomain($.curve, newCap);
        $.cap = newCap;
    }

    /**
     * @param c      Curve the cap must be valid for.
     * @param capNow Proposed or existing cap.
     * @dev Two bounds, both applied. The curve states the supply its own arithmetic is proven
     *      at; the vault applies its own hard bound as well, so a curve reporting an absurd
     *      domain cannot widen it.
     */
    function _requireWithinDomain(IMintCurve c, uint256 capNow) private view {
        uint256 bound = c.maxSafeSupply();
        if (bound > ABSOLUTE_SUPPLY_BOUND) bound = ABSOLUTE_SUPPLY_BOUND;
        if (capNow > bound) revert CapAboveCurveDomain(capNow, bound);
    }

    // -------------------------------------------------------------------------
    // Yield
    // -------------------------------------------------------------------------

    /**
     * @notice Sweeps collateral appreciation to the foundation.
     * @dev Permissionless: it can only move the difference between what the vault holds and
     *      what it owes, so there is nothing to gain by calling it and nothing to gain by
     *      withholding it.
     *
     *      The obligation is ceiled, so the sweep is always a wei or two conservative.
     */
    function harvest() external nonReentrant whenNotPaused returns (uint256 surplus) {
        VaultStorage storage $ = _s();
        uint256 er = $.oracle.getValue();
        uint256 held = $.a0G.balanceOf(address(this));
        uint256 owed = Math.mulDiv($.totalLocked0G, WAD, er, Math.Rounding.Ceil);

        // Guarded rather than assumed: a rate that moves the wrong way must not underflow
        // and brick the sweep.
        surplus = held > owed ? held - owed : 0;
        if (surplus != 0) {
            address to = $.foundation;
            $.a0G.safeTransfer(to, surplus);
            emit Harvested(to, surplus, er, $.totalLocked0G);
        }
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @inheritdoc IIAIVault
    function setFoundation(address newFoundation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFoundation == address(0)) revert ZeroAddress();
        VaultStorage storage $ = _s();
        emit FoundationUpdated($.foundation, newFoundation);
        $.foundation = newFoundation;
    }

    /**
     * @inheritdoc IIAIVault
     * @dev Deliberately does **not** read the outgoing curve. A curve that reverts, runs out
     *      of gas, or has no code would otherwise be unreplaceable and issuance would be dead
     *      permanently -- the one situation this function exists to escape.
     *
     *      Nothing already minted is repriced: positions record an absolute 0G amount and
     *      redemption never consults a curve. What changes is the price of future mints.
     */
    function setCurve(IMintCurve newCurve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _s();
        IMintCurve previous = $.curve;
        _setCurve($, newCurve, $.cap);
        emit CurveUpdated(address(previous), address(newCurve));
    }

    /**
     * @inheritdoc IIAIVault
     * @dev A cap below the current supply is allowed, and so is zero. That is how the system
     *      is wound down: minting stops of its own accord because `supply + d` can no longer
     *      fit, while redemption -- which never looks at the cap -- keeps working. Adding a
     *      `newCap >= supply` guard here is the obvious instinct and would defeat the entire
     *      point.
     *
     *      Note that `harvest` is not cap-gated either, so lowering the cap alone does not
     *      stop yield being swept. `pause()` is the lever that stops everything except exit.
     */
    function setCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _s();
        uint256 previous = $.cap;
        _setCap($, newCap);
        emit CapUpdated(previous, newCap);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @inheritdoc IIAIVault
    function quoteMint(uint256 d) external view returns (uint256 delta0G, uint256 a0GIn) {
        VaultStorage storage $ = _s();
        uint256 s = $.iai.totalSupply();
        // Fails exactly where `mint` would, with the same error, so a caller cannot be handed
        // a price for an amount that can never be issued.
        uint256 supplyAfter = s + d;
        if (supplyAfter > $.cap) revert CapExceeded(supplyAfter, $.cap);
        delta0G = $.curve.cost(s, d);
        a0GIn = Math.mulDiv(delta0G, WAD, $.oracle.getValue(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IIAIVault
    function quoteBurn(address minter, uint256 b) external view returns (uint256 unlocked0G, uint256 a0GOut) {
        VaultStorage storage $ = _s();
        Position storage pos = $.positions[minter];
        uint256 outstanding = pos.iaiOutstanding;
        // Fails exactly where `burn` would, with the same error. Left unguarded the ratio
        // exceeds one and the quote reports releasing more 0G than the position ever locked --
        // a number no `burn` can produce, handed to a caller with no way to tell it is
        // impossible. Clamping instead would answer a question that was not asked.
        if (b > outstanding) revert BurnExceedsPosition(b, outstanding);
        if (outstanding == 0) return (0, 0);
        unlocked0G = Math.mulDiv(pos.locked0G, b, outstanding, Math.Rounding.Floor);
        a0GOut = Math.mulDiv(unlocked0G, WAD, $.oracle.getValue(), Math.Rounding.Floor);
    }

    /**
     * @inheritdoc IIAIVault
     * @dev Convenience for a "spend all of it" flow. Quoting is not pricing -- the result is
     *      fed back into `mint`, which re-prices from the curve.
     */
    function quoteMintForA0G(uint256 a0GAmount) external view returns (uint256 d) {
        VaultStorage storage $ = _s();
        // The oracle is read first on purpose: a stale feed must make this revert like every
        // other priced path, so an early return for a full cap would silently exempt it.
        uint256 delta = Math.mulDiv(a0GAmount, $.oracle.getValue(), WAD, Math.Rounding.Floor);

        uint256 s = $.iai.totalSupply();
        uint256 cap_ = $.cap;
        // Saturating: once the cap is below the supply there is no headroom, and a plain
        // subtraction would panic instead of answering zero.
        uint256 headroom = cap_ > s ? cap_ - s : 0;
        if (headroom == 0) return 0;

        // Clamp the value *before* solving. The root solver squares an intermediate, so a
        // caller holding an absurd balance would otherwise overflow it -- and this function
        // promises to clamp, never to revert.
        uint256 forAllOfIt = $.curve.cost(s, headroom);
        if (delta > forAllOfIt) return headroom;

        d = $.curve.quoteForValue(s, delta);
        if (d > headroom) d = headroom;
    }

    function positionOf(address account)
        external
        view
        returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)
    {
        Position storage pos = _s().positions[account];
        locked0G = pos.locked0G;
        iaiOutstanding = pos.iaiOutstanding;
        avgRate = iaiOutstanding == 0 ? 0 : Math.mulDiv(locked0G, WAD, iaiOutstanding);
    }

    function exchangeRate() external view returns (uint256) {
        return _s().oracle.getValue();
    }

    /// @inheritdoc IIAIVault
    function remainingCap() public view returns (uint256) {
        VaultStorage storage $ = _s();
        uint256 s = $.iai.totalSupply();
        uint256 cap_ = $.cap;
        return cap_ > s ? cap_ - s : 0;
    }

    /// @inheritdoc IIAIVault
    function curve() external view returns (IMintCurve) {
        return _s().curve;
    }

    function pendingSurplus() external view returns (uint256) {
        VaultStorage storage $ = _s();
        uint256 held = $.a0G.balanceOf(address(this));
        uint256 owed = Math.mulDiv($.totalLocked0G, WAD, $.oracle.getValue(), Math.Rounding.Ceil);
        return held > owed ? held - owed : 0;
    }

    function iai() external view returns (IIAI) {
        return _s().iai;
    }

    function a0G() external view returns (IA0G) {
        return _s().a0G;
    }

    function oracle() external view returns (IA0GOracle) {
        return _s().oracle;
    }

    function foundation() external view returns (address) {
        return _s().foundation;
    }

    function cap() external view returns (uint256) {
        return _s().cap;
    }

    function totalLocked0G() external view returns (uint256) {
        return _s().totalLocked0G;
    }

    function supply() external view returns (uint256) {
        return _s().iai.totalSupply();
    }
}
