// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";

/**
 * @title UpgradeChecker
 * @notice What an upgrade must leave untouched, captured in memory and compared in memory.
 *
 * @dev Separated from the script so a test can capture, upgrade and compare inside a single
 *      process with no file access. The script keeps the file half, which it needs only
 *      because `snapshot()` and `postUpgradeCheck()` are two separate `forge script`
 *      invocations and have to hand state across a process boundary.
 *
 *      This is where upgrade safety is established, deliberately off-chain. A guard a contract
 *      computes about itself is only sound while it reads the right storage slots -- exactly
 *      what is in doubt when a layout has shifted -- so it would report "fine" in the one case
 *      it exists to catch.
 */
abstract contract UpgradeChecker {
    /**
     * @dev Flat on purpose: it maps one-for-one onto the snapshot file, and every field is
     *      something an upgrade has no business changing.
     */
    struct Snapshot {
        // Pricing, and the supply ceiling with it. The curve address is the whole of it:
        // pricing lives outside the beacon and the vault reads its ceiling off the curve, so
        // replacing this address is the only way a vault upgrade can reprice or re-cap. Not
        // snapshotting it would leave the rehearsal blind to exactly that.
        address curve;
        // The ceiling as the vault reports it. Derived from the curve, not stored, and
        // compared anyway: an upgrade whose `_cap` regressed -- a wrong clamp, or a vault that
        // stopped reading the curve -- leaves the address alone and moves this. Unavailable
        // while the curve in force cannot answer `maxSafeSupply()`; the flag is compared first.
        bool ceilingAvailable;
        uint256 cap;
        // The split of collateral appreciation, and how much history it has. An upgrade that
        // moved either would silently redirect every future wei of yield -- the same class of
        // change as repointing the curve, and just as invisible in the accounting totals.
        uint256 harvestShare;
        uint256 epoch;
        // Wiring.
        address iai;
        address a0G;
        address oracle;
        address foundation;
        address registryIai;
        // Live accounting. Every 0G in here is someone's redeemable collateral. The two
        // halves are carried alongside the combined figure because value moved between them
        // leaves the combined figure untouched.
        uint256 totalLocked0G;
        uint256 totalClaim0G;
        uint256 totalClaimA0G;
        uint256 supply;
        uint256 tokenSupply;
        bool paused;
        uint256 totalStaked;
        uint256 cooldownDuration;
        // Pricing quoted through the proxy rather than recomputed, so a change in how the
        // contract reaches the answer is caught even when the inputs match. Unavailable once
        // the cap is reached or has been lowered below the supply -- `quoteMint` reverts
        // there by design -- so the flag is compared before the figures.
        bool quotesAvailable;
        uint256 quote1;
        uint256 quote100;
        // Real positions, when any were named. These are the balances an upgrade would strand.
        address[] accounts;
        uint256[] locked;
        uint256[] outstanding;
        uint256[] claim0G;
        uint256[] claimA0G;
    }

    /**
     * @param vault    The vault proxy to read.
     * @param token    The iAI proxy.
     * @param registry The credit registry proxy.
     * @param accounts Positions to include. On a live deployment, pass the largest holders.
     * @return s Everything the upgrade must preserve.
     */
    function _capture(IAIVault vault, IAI token, CreditRegistry registry, address[] memory accounts)
        internal
        view
        returns (Snapshot memory s)
    {
        s.curve = address(vault.curve());
        // A curve that reverts takes `cap()` down with it, and an upgrade rehearsed from that
        // state -- the state an operator is most likely to be upgrading out of -- has to stay
        // runnable. Recorded as unavailable rather than failing the capture.
        try vault.cap() returns (uint256 ceiling) {
            s.ceilingAvailable = true;
            s.cap = ceiling;
        } catch {}
        s.harvestShare = vault.harvestShare();
        s.epoch = vault.currentEpoch();

        s.iai = address(vault.iai());
        s.a0G = address(vault.a0G());
        s.oracle = address(vault.oracle());
        s.foundation = vault.foundation();
        s.registryIai = address(registry.iai());

        s.totalLocked0G = vault.totalLocked0G();
        s.totalClaim0G = vault.totalClaim0G();
        s.totalClaimA0G = vault.totalClaimA0G();
        s.supply = vault.supply();
        s.tokenSupply = token.totalSupply();
        s.paused = vault.paused();
        s.totalStaked = registry.totalStaked();
        s.cooldownDuration = registry.cooldownDuration();

        // Probe only within the headroom. A full ceiling, or one swapped in below the supply,
        // makes `quoteMint` revert, and an upgrade rehearsal has to stay runnable in that state.
        s.quotesAvailable = s.ceilingAvailable && vault.remainingCap() >= 100e18;
        if (s.quotesAvailable) {
            (s.quote1,) = vault.quoteMint(1e18);
            (s.quote100,) = vault.quoteMint(100e18);
        }

        s.accounts = accounts;
        s.locked = new uint256[](accounts.length);
        s.outstanding = new uint256[](accounts.length);
        s.claim0G = new uint256[](accounts.length);
        s.claimA0G = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            (s.locked[i], s.outstanding[i],) = vault.positionOf(accounts[i]);
            (s.claim0G[i], s.claimA0G[i],) = vault.positionClaims(accounts[i]);
        }
    }

    /**
     * @param before_ The snapshot taken before the upgrade.
     * @param after_  The snapshot taken after it.
     *
     * @dev Reverts naming the first field that moved.
     */
    function _assertUnchanged(Snapshot memory before_, Snapshot memory after_) internal pure {
        _eqAddr(after_.curve, before_.curve, "curve");
        require(after_.ceilingAvailable == before_.ceilingAvailable, "changed across upgrade: ceilingAvailable");
        _eq(after_.cap, before_.cap, "cap");
        _eq(after_.harvestShare, before_.harvestShare, "harvestShare");
        _eq(after_.epoch, before_.epoch, "epoch");

        _eqAddr(after_.iai, before_.iai, "iai");
        _eqAddr(after_.a0G, before_.a0G, "a0G");
        _eqAddr(after_.oracle, before_.oracle, "oracle");
        _eqAddr(after_.foundation, before_.foundation, "foundation");
        _eqAddr(after_.registryIai, before_.registryIai, "registryIai");

        _eq(after_.totalLocked0G, before_.totalLocked0G, "totalLocked0G");
        _eq(after_.totalClaim0G, before_.totalClaim0G, "totalClaim0G");
        _eq(after_.totalClaimA0G, before_.totalClaimA0G, "totalClaimA0G");
        _eq(after_.supply, before_.supply, "supply");
        _eq(after_.tokenSupply, before_.tokenSupply, "tokenSupply");
        require(after_.paused == before_.paused, "changed across upgrade: paused");
        _eq(after_.totalStaked, before_.totalStaked, "totalStaked");
        _eq(after_.cooldownDuration, before_.cooldownDuration, "cooldownDuration");

        require(
            after_.quotesAvailable == before_.quotesAvailable, "changed across upgrade: quotesAvailable"
        );
        if (before_.quotesAvailable) {
            _eq(after_.quote1, before_.quote1, "quote1");
            _eq(after_.quote100, before_.quote100, "quote100");
        }

        _eq(after_.accounts.length, before_.accounts.length, "accounts.length");
        for (uint256 i = 0; i < before_.accounts.length; i++) {
            _eqAddr(after_.accounts[i], before_.accounts[i], "accounts[i]");
            _eq(after_.locked[i], before_.locked[i], "position.locked0G");
            _eq(after_.outstanding[i], before_.outstanding[i], "position.iaiOutstanding");
            _eq(after_.claim0G[i], before_.claim0G[i], "position.claim0G");
            _eq(after_.claimA0G[i], before_.claimA0G[i], "position.claimA0G");
        }
    }

    /**
     * @param vault The vault to check.
     * @dev Checks that the vault routes to the curve it advertises -- an implementation that
     *      priced off something else would pass every field comparison above. It does **not**
     *      re-derive the curve's own maths: reading the parameters back out of the curve and
     *      recomputing would be the curve grading its own work. That belongs to the curve's
     *      conformance suite and golden vectors.
     *
     *      Silent when there is no headroom: `quoteMint` reverts at or past the ceiling.
     */
    function _assertPricingMatchesCurve(IAIVault vault) internal view {
        uint256 headroom;
        // Silent, too, while the curve in force cannot say where it ends: there is no price
        // to compare, and the rehearsal must not die on the state it is rehearsing out of.
        try vault.remainingCap() returns (uint256 h) {
            headroom = h;
        } catch {
            return;
        }
        if (headroom == 0) return;
        uint256 probe = headroom < 1e18 ? headroom : 1e18;
        (uint256 quoted,) = vault.quoteMint(probe);
        require(
            quoted == vault.curve().cost(vault.supply(), probe), "pricing diverged from the curve"
        );
    }

    /**
     * @param beacon  The beacon whose implementation is being replaced.
     * @param newImpl The implementation to point it at.
     * @dev Each contract has its own beacon, so this can only ever move one of them.
     */
    function _pointBeaconAt(address beacon, address newImpl) internal {
        UpgradeableBeacon(beacon).upgradeTo(newImpl);
    }

    function _eq(uint256 actual, uint256 expected, string memory field) private pure {
        require(actual == expected, string.concat("changed across upgrade: ", field));
    }

    function _eqAddr(address actual, address expected, string memory field) private pure {
        require(actual == expected, string.concat("changed across upgrade: ", field));
    }
}
