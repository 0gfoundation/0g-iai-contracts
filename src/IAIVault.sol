// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EpochMath} from "./EpochMath.sol";
import {IIAIVault} from "./interfaces/IIAIVault.sol";
import {IIAI} from "./interfaces/IIAI.sol";
import {IA0G} from "./interfaces/external/IA0G.sol";
import {IA0GOracle} from "./interfaces/external/IA0GOracle.sol";
import {IMintCurve} from "./interfaces/IMintCurve.sol";

/**
 * @title IAIVault
 * @notice Escrows a0G collateral, issues iAI against a rising curve, redeems the original
 *         minter at their weighted-average entry rate, and sweeps an adjustable share of the
 *         collateral's appreciation to the foundation.
 *
 * @dev Custody and logic live in one contract on purpose. The solvency property — that the
 *      vault always holds at least what it owes — is then a statement about a single
 *      contract's own storage and balance, with no cross-contract atomicity gap and no
 *      "vault trusts controller" indirection to get wrong.
 *
 *      **Two conversions, not one.** The curve prices in 0G *value*; the collateral is a0G,
 *      which is worth a moving amount of 0G.
 *
 *      **A claim is recorded in both denominations, and the proportion is the split.** A
 *      0G-denominated claim redeems for fewer a0G as a0G appreciates, leaving that
 *      appreciation for the foundation; a share-denominated one comes back as deposited and
 *      keeps it. Recording a mint wholly in 0G hands the foundation everything, wholly in
 *      shares hands the minter everything, and there is no third denomination -- so the
 *      proportion between the two *is* the split, and `harvestShare` is exactly that
 *      proportion. `EpochMath` carries the arithmetic, including why governance can change
 *      the split without repricing what has already been earned.
 *
 *      **The obligation is a function of recorded claims and nothing else.** `harvest` moves
 *      the balance down to that obligation rather than accruing anything, which is what makes
 *      calling it twice in a row harmless. Deriving the obligation from the balance instead
 *      would make each sweep take a cut of what the last one left, and repeated calls would
 *      drain a surplus that is only partly the foundation's.
 *
 *      **Rounding always favours the vault**: value flowing in rounds up, value flowing out
 *      rounds down. That single rule is what makes the solvency invariant hold across every
 *      interleaving of mint, redeem and harvest, and it also means splitting a mint into
 *      pieces is never cheaper than doing it at once.
 *
 *      **Redemption is never pausable.** `pause()` stops harvesting, and stops issuance for
 *      everyone but a holder of `PAUSE_EXEMPT_MINTER_ROLE`; it must never be able to trap
 *      collateral. Redemption also takes no oracle-independent path around a stale price —
 *      that dependency is accepted and documented, not silently worked around.
 */
contract IAIVault is IIAIVault, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IA0G;

    uint256 private constant WAD = 1e18;

    /// @notice May close and reopen issuance -- and with it `harvest`, which is `pause`-gated
    ///         too, so this role can also withhold the foundation's sweep. It cannot move
    ///         funds, reprice or grant anything, which is what lets it be a lighter key than
    ///         admin; the point of a lighter key is that closing has to be fast.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @notice May mint while issuance is paused. Grants no other power at all.
     * @dev The exempt mint is the *same* mint: same curve, same cap check, same slippage and
     *      deadline bounds, same position accounting, and both the collateral and the iAI still
     *      move on the caller. The only thing the role removes is the pause gate, and only on
     *      `mint` -- `harvest` stays closed while paused, and `burn` was never gated at all.
     *
     *      It exists because the vault deploys paused and the only two states it had were
     *      "closed to everyone" and "open to everyone". Admitting one nominated address
     *      otherwise means unpausing and re-pausing around the transaction, which opens the
     *      base of the curve to everyone for the width of a block.
     *
     *      Held by nobody at deployment, so it opens as an explicit act of governance -- and is
     *      meant to be revoked once the operation it was granted for is done. What it costs:
     *      `pause()` is the response to an a0G exchange-rate move, and
     *      while this role is held that response no longer stops issuance at a manipulated
     *      rate, so revoking it is part of that response rather than a follow-up to it. The
     *      curve's ceiling still binds a holder, because that check sits inside `mint`; but
     *      the ceiling moves only with the curve, so it is no substitute for the revocation.
     */
    bytes32 public constant PAUSE_EXEMPT_MINTER_ROLE = keccak256("PAUSE_EXEMPT_MINTER_ROLE");

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
        /// The curve in force, and with it the supply ceiling: the vault keeps no cap of its
        /// own and reads `curve.maxSafeSupply()` instead. Swappable: see `setCurve`.
        IMintCurve curve;
        address foundation;
        IIAI iai;
        IA0G a0G;
        IA0GOracle oracle;
        /// Sum of the 0G-denominated half of every claim.
        uint256 totalClaim0G;
        /// Sum of the share-denominated half of every claim.
        uint256 totalClaimA0G;
        /// History of the harvest share, one entry per change. Never pruned: a position that
        /// has sat untouched since any past epoch is restated from the entry after it.
        EpochMath.Epoch[] epochs;
        /// Never read directly. `_settled` is the only way in, because a position may be
        /// several harvest-share changes behind and its stored numbers are then stale. A read
        /// that skipped it would price a redemption against a split no longer in force, and
        /// nothing would revert.
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
        _setCurve($, IMintCurve(p.curve));

        // Emitted from the zero address, so the log stream alone carries the starting curve
        // -- and with it the starting ceiling, which is the curve's. Without this an indexer
        // would have to read the chain to learn where the later `CurveUpdated` deltas began.
        emit CurveUpdated(address(0), p.curve);

        IA0GOracle o = IA0G(p.a0G).oracle();
        if (address(o) == address(0)) revert ZeroAddress();
        $.oracle = o;

        // The genesis rate anchors the monotonicity check on every later change and is never
        // applied to a position -- no position can predate it -- so a live oracle is required
        // here for the sake of that anchor rather than for any arithmetic on day one.
        uint256 er = o.getValue();
        $.epochs.push(EpochMath.genesis(er, p.harvestShare));
        emit HarvestShareUpdated(0, 0, p.harvestShare, er, EpochMath.RAY);

        _pause();
    }

    /**
     * @dev `whenNotPaused` for issuance only, with one exemption. Named for issuance rather
     *      than for pausing so nobody reaches for it to gate something else: it sits on `mint`
     *      and on nothing else. Redemption carries no pause modifier of any kind and must not
     *      acquire one.
     *
     *      `paused()` is tested first on purpose. While issuance is open the conjunction
     *      short-circuits before any role lookup, so an ordinary mint costs what it always did.
     *
     *      Reverts with OpenZeppelin's own `EnforcedPause` rather than a new error: for
     *      everyone without the role the behaviour is unchanged, and it should decode
     *      unchanged too.
     */
    modifier whenIssuanceOpen() {
        if (paused() && !hasRole(PAUSE_EXEMPT_MINTER_ROLE, _msgSender())) revert EnforcedPause();
        _;
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
     *
     * @dev Gated by `whenIssuanceOpen`, not `whenNotPaused`: while paused, a holder of
     *      `PAUSE_EXEMPT_MINTER_ROLE` still gets through here and everyone else still gets
     *      `EnforcedPause`. Nothing below that line knows the difference, which is the point --
     *      an exempt mint is priced, capped, bounded and recorded by exactly this code.
     */
    function mint(uint256 d, uint256 maxA0GIn, uint256 deadline) external nonReentrant whenIssuanceOpen {
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (d == 0) revert ZeroAmount();

        VaultStorage storage $ = _s();

        uint256 s = $.iai.totalSupply();
        uint256 supplyAfter = s + d;
        uint256 cap_ = _cap($);
        if (supplyAfter > cap_) revert CapExceeded(supplyAfter, cap_);

        uint256 delta0G = $.curve.cost(s, d);
        // A curve returning zero would hand out free iAI: the recipient could claim compute
        // for nothing, and the supply the vault prices against would inflate permanently.
        // Enforced here so it is a property of the vault, not a promise from the curve.
        if (delta0G == 0) revert ZeroAmount();
        uint256 er = $.oracle.getValue();
        uint256 a0GIn = Math.mulDiv(delta0G, WAD, er, Math.Rounding.Ceil);
        if (a0GIn > maxA0GIn) revert ExcessiveInput(a0GIn, maxA0GIn);

        // State first, external calls last.
        Position memory pos = _settled($, _msgSender());
        // The split is consumed here and nowhere else. That is what makes a later change of
        // share an act on the future only: the position carries its own history in its two
        // halves, and no settlement reads the share again.
        (uint256 claim0G, uint256 claimA0G) = EpochMath.split(delta0G, a0GIn, $.epochs[pos.epoch].share);
        pos.claim0G += claim0G;
        pos.claimA0G += claimA0G;
        // `supplyAfter` is bounded by `_cap`, itself clamped to `ABSOLUTE_SUPPLY_BOUND`, so
        // the narrowing cannot lose a bit.
        pos.iaiOutstanding += uint128(d);
        $.positions[_msgSender()] = pos;

        uint256 total0GAfter = $.totalClaim0G + claim0G;
        uint256 totalA0GAfter = $.totalClaimA0G + claimA0G;
        $.totalClaim0G = total0GAfter;
        $.totalClaimA0G = totalA0GAfter;
        uint256 totalAfter = EpochMath.value0G(total0GAfter, totalA0GAfter, er);

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
        _settle(b, deadline);
    }

    /**
     * @param b        Amount of iAI to burn, in wei-iAI.
     * @param deadline Latest block timestamp at which the caller still accepts execution.
     *
     * @dev Reads the position owner from `_msgSender()` rather than taking it as a parameter.
     *      An address threaded through here is exactly what made an on-behalf variant a
     *      two-line addition, so not having one is structural rather than a convention.
     */
    function _settle(uint256 b, uint256 deadline) private {
        address minter = _msgSender();
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        if (b == 0) revert ZeroAmount();

        VaultStorage storage $ = _s();
        Position memory pos = _settled($, minter);
        uint256 outstanding = pos.iaiOutstanding;
        if (b > outstanding) revert BurnExceedsPosition(b, outstanding);

        uint256 s = $.iai.totalSupply();

        // Pro-rata against the position's own blend, both halves alike. Floor: releasing less
        // than the exact share keeps the vault over-collateralised, and a full redemption
        // (b == outstanding) still clears the position to exactly zero.
        uint256 unlocked0G = Math.mulDiv(pos.claim0G, b, outstanding, Math.Rounding.Floor);
        uint256 unlockedA0G = Math.mulDiv(pos.claimA0G, b, outstanding, Math.Rounding.Floor);

        uint256 er = $.oracle.getValue();
        uint256 a0GOut = EpochMath.payout(unlocked0G, unlockedA0G, er);

        pos.claim0G -= unlocked0G;
        pos.claimA0G -= unlockedA0G;
        pos.iaiOutstanding = uint128(outstanding - b);
        $.positions[minter] = pos;

        // Cannot underflow: the totals are rounded up where a position is rounded down, so
        // they stay at or above the sum of the positions they stand for.
        uint256 total0GAfter = $.totalClaim0G - unlocked0G;
        uint256 totalA0GAfter = $.totalClaimA0G - unlockedA0G;
        $.totalClaim0G = total0GAfter;
        $.totalClaimA0G = totalA0GAfter;
        uint256 supplyAfter = s - b;

        $.iai.burn(minter, b);
        $.a0G.safeTransfer(minter, a0GOut);

        emit Burned(
            minter,
            b,
            EpochMath.value0G(unlocked0G, unlockedA0G, er),
            a0GOut,
            er,
            supplyAfter,
            EpochMath.value0G(total0GAfter, totalA0GAfter, er)
        );
    }

    /**
     * @param $        Vault storage.
     * @param newCurve The curve to install.
     *
     * @dev The one call made to the incoming curve is `maxSafeSupply()`, and only to see that
     *      it answers: a contract that reverts here would revert in every `mint` and quote,
     *      so it is refused now rather than discovered later. Its *value* is not judged. A
     *      ceiling below the live supply is legal and simply closes issuance until the next
     *      swap, which is how burn-only mode is entered; the vault applies its own hard bound
     *      at the point of use, so an absurd figure cannot widen the domain either.
     */
    function _setCurve(VaultStorage storage $, IMintCurve newCurve) private {
        if (address(newCurve) == address(0)) revert ZeroAddress();
        if (address(newCurve).code.length == 0) revert NotAContract(address(newCurve));
        newCurve.maxSafeSupply();
        $.curve = newCurve;
    }

    /**
     * @notice Reads a position, brought up to date with every harvest-share change it missed.
     * @param $       Vault storage.
     * @param account Position owner.
     * @return The position as it stands under the epoch now in force.
     *
     * @dev **The only way to read a position.** Bypassing it would settle a redemption against
     *      a split that is no longer in force, silently and without reverting, which is why
     *      the mapping itself is documented as off limits.
     *
     *      Reads no oracle: every rate it needs was recorded when the corresponding change was
     *      made. Redemption therefore gains no new dependency on a live feed, and a position
     *      that has sat through any number of changes still costs the same to settle.
     *
     *      Leaves the totals alone. They were restated in full at the moment of each change --
     *      the transform is linear, so restating the sum and restating each position give the
     *      same answer -- and adjusting them here would count this position twice.
     */
    function _settled(VaultStorage storage $, address account) private view returns (Position memory) {
        Position memory pos = $.positions[account];
        uint256 n = $.epochs.length - 1;
        if (pos.epoch == n) return pos;

        (pos.claim0G, pos.claimA0G) =
            EpochMath.sync(pos.claim0G, pos.claimA0G, $.epochs[pos.epoch + 1], $.epochs[n]);
        pos.epoch = uint64(n);
        return pos;
    }

    /**
     * @notice The supply ceiling in force: the curve's, clamped to the vault's hard bound.
     * @param $ Vault storage.
     * @return The highest supply `mint` will take the token to, in wei-iAI.
     *
     * @dev Not stored. A mirrored `cap` field would be one more number able to disagree with
     *      the curve, and it was removed for that reason; the ceiling is read from the curve
     *      each time it is needed, one `STATICCALL`. Two bounds, both applied: the curve
     *      states how far it permits issuance, and the vault's own bound is where its
     *      arithmetic -- the `uint128` narrowing of a position, a squared supply in the
     *      linear curve -- is proven, so a curve reporting an absurd figure cannot widen it.
     *
     *      Reverts if the curve does. That is the right outcome for every caller: a `mint`
     *      or quote against a curve that cannot answer has no correct price, and `burn`
     *      never comes here.
     */
    function _cap(VaultStorage storage $) private view returns (uint256) {
        uint256 bound = $.curve.maxSafeSupply();
        return bound > ABSOLUTE_SUPPLY_BOUND ? ABSOLUTE_SUPPLY_BOUND : bound;
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
        uint256 total0G = $.totalClaim0G;
        uint256 totalA0G = $.totalClaimA0G;
        uint256 owed = EpochMath.owed(total0G, totalA0G, er);

        // Guarded rather than assumed: a rate that moves the wrong way must not underflow
        // and brick the sweep.
        surplus = held > owed ? held - owed : 0;
        if (surplus != 0) {
            address to = $.foundation;
            $.a0G.safeTransfer(to, surplus);
            emit Harvested(to, surplus, er, EpochMath.value0G(total0G, totalA0G, er));
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
     *      redemption never consults a curve. What changes is the price of future mints --
     *      and the ceiling, which is the incoming curve's `maxSafeSupply()`. A curve whose
     *      ceiling sits below the live supply is accepted: `mint` then refuses everything
     *      while redemption, staking and the sweep carry on, which is the supported way to
     *      close issuance to everyone at once. Adding a `maxSafeSupply() >= supply` guard
     *      here is the obvious instinct and would remove exactly that.
     */
    function setCurve(IMintCurve newCurve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _s();
        IMintCurve previous = $.curve;
        _setCurve($, newCurve);
        emit CurveUpdated(address(previous), address(newCurve));
    }

    /**
     * @inheritdoc IIAIVault
     * @dev Value-neutral at the instant it runs: every position is restated by value at the
     *      current rate, and the obligation the sweep is measured against comes out unchanged
     *      to within the rounding.
     *
     *      **That is not the same as the change being free.** Until it is made, a minter keeps
     *      `1 - share` of the appreciation of the a0G they deposited; afterwards, of the
     *      appreciation of what their position is now worth, which is less -- the foundation
     *      has already taken its part -- and that part becomes shares which compound for the
     *      foundation. Re-issuing the *same* share therefore still moves a little future yield
     *      across. Restating at a change rather than accruing continuously is what keeps that
     *      out of reach of anyone who can call a permissionless function; it does not remove
     *      it, and this role can still ratchet by acting often. Deliberate, and recorded.
     *
     *      The totals move here, in one step. Positions are left for `_settled` to catch up
     *      whenever each is next touched; by linearity the two agree.
     */
    function setHarvestShare(uint256 newShare) external onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _s();
        uint256 er = $.oracle.getValue();

        uint256 previous = $.epochs[$.epochs.length - 1].share;
        EpochMath.Epoch memory opened = EpochMath.next($.epochs[$.epochs.length - 1], er, newShare);
        $.epochs.push(opened);

        // Rounded up where a position rounds down, so the totals stay at or above the sum of
        // the positions they stand for. The gap is a wei per position per change, is claimable
        // by nobody, and shows up only as a sweep a few wei short.
        ($.totalClaim0G, $.totalClaimA0G) =
            EpochMath.resplitTotals($.totalClaim0G, $.totalClaimA0G, er, newShare);

        emit HarvestShareUpdated($.epochs.length - 1, previous, newShare, er, opened.cumG);
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
        // Fails exactly where `mint` would, with the same errors and in the same order, so a
        // caller cannot be handed a price for an amount that can never be issued. The
        // zero-cost case is unreachable with a curve that honours the interface, and is
        // mirrored here anyway: `mint` refuses it, so a quote must not display it.
        if (d == 0) revert ZeroAmount();

        VaultStorage storage $ = _s();
        uint256 s = $.iai.totalSupply();
        uint256 supplyAfter = s + d;
        uint256 cap_ = _cap($);
        if (supplyAfter > cap_) revert CapExceeded(supplyAfter, cap_);
        delta0G = $.curve.cost(s, d);
        if (delta0G == 0) revert ZeroAmount();
        a0GIn = Math.mulDiv(delta0G, WAD, $.oracle.getValue(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IIAIVault
    function quoteBurn(address minter, uint256 b) external view returns (uint256 unlocked0G, uint256 a0GOut) {
        VaultStorage storage $ = _s();
        Position memory pos = _settled($, minter);
        uint256 outstanding = pos.iaiOutstanding;
        // Fails exactly where `burn` would, with the same error. Left unguarded the ratio
        // exceeds one and the quote reports releasing more 0G than the position ever locked --
        // a number no `burn` can produce, handed to a caller with no way to tell it is
        // impossible. Clamping instead would answer a question that was not asked.
        if (b > outstanding) revert BurnExceedsPosition(b, outstanding);
        // The one place this does *not* mirror `burn`: a zero amount is answered rather than
        // refused, so a caller polling an empty position gets zeroes instead of a revert.
        if (outstanding == 0) return (0, 0);

        uint256 released0G = Math.mulDiv(pos.claim0G, b, outstanding, Math.Rounding.Floor);
        uint256 releasedA0G = Math.mulDiv(pos.claimA0G, b, outstanding, Math.Rounding.Floor);
        uint256 er = $.oracle.getValue();

        unlocked0G = EpochMath.value0G(released0G, releasedA0G, er);
        a0GOut = EpochMath.payout(released0G, releasedA0G, er);
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
        uint256 cap_ = _cap($);
        // Saturating: once the ceiling is below the supply there is no headroom, and a plain
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

    /// @inheritdoc IIAIVault
    function positionOf(address account)
        external
        view
        returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)
    {
        VaultStorage storage $ = _s();
        Position memory pos = _settled($, account);
        iaiOutstanding = pos.iaiOutstanding;
        if (iaiOutstanding == 0) return (0, 0, 0);

        locked0G = EpochMath.value0G(pos.claim0G, pos.claimA0G, $.oracle.getValue());
        avgRate = Math.mulDiv(locked0G, WAD, iaiOutstanding);
    }

    function exchangeRate() external view returns (uint256) {
        return _s().oracle.getValue();
    }

    /// @inheritdoc IIAIVault
    function remainingCap() public view returns (uint256) {
        VaultStorage storage $ = _s();
        uint256 s = $.iai.totalSupply();
        uint256 cap_ = _cap($);
        return cap_ > s ? cap_ - s : 0;
    }

    /// @inheritdoc IIAIVault
    function curve() external view returns (IMintCurve) {
        return _s().curve;
    }

    /// @inheritdoc IIAIVault
    function pendingSurplus() external view returns (uint256) {
        VaultStorage storage $ = _s();
        uint256 held = $.a0G.balanceOf(address(this));
        uint256 owed = EpochMath.owed($.totalClaim0G, $.totalClaimA0G, $.oracle.getValue());
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

    /// @inheritdoc IIAIVault
    function cap() external view returns (uint256) {
        return _cap(_s());
    }

    /**
     * @inheritdoc IIAIVault
     * @dev Reads the oracle, because half the obligation is denominated in a0G and has no 0G
     *      value without one. While the feed is stale, `totalClaim0G` and `totalClaimA0G` are
     *      still readable and still say what the vault owes.
     */
    function totalLocked0G() external view returns (uint256) {
        VaultStorage storage $ = _s();
        return EpochMath.value0G($.totalClaim0G, $.totalClaimA0G, $.oracle.getValue());
    }

    /// @inheritdoc IIAIVault
    function harvestShare() external view returns (uint256) {
        VaultStorage storage $ = _s();
        return $.epochs[$.epochs.length - 1].share;
    }

    /// @inheritdoc IIAIVault
    function currentEpoch() external view returns (uint256) {
        return _s().epochs.length - 1;
    }

    /// @inheritdoc IIAIVault
    function epochAt(uint256 index) external view returns (EpochMath.Epoch memory) {
        return _s().epochs[index];
    }

    /// @inheritdoc IIAIVault
    function totalClaim0G() external view returns (uint256) {
        return _s().totalClaim0G;
    }

    /// @inheritdoc IIAIVault
    function totalClaimA0G() external view returns (uint256) {
        return _s().totalClaimA0G;
    }

    /// @inheritdoc IIAIVault
    function positionClaims(address account)
        external
        view
        returns (uint256 claim0G, uint256 claimA0G, uint256 epoch)
    {
        Position memory pos = _settled(_s(), account);
        return (pos.claim0G, pos.claimA0G, pos.epoch);
    }

    function supply() external view returns (uint256) {
        return _s().iai.totalSupply();
    }
}
