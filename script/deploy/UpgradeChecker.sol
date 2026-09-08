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
        // Pricing. The curve address is the whole of it now: pricing lives outside the
        // beacon, so replacing this address is the only way a vault upgrade can reprice.
        // Not snapshotting it would leave the rehearsal blind to exactly that.
        address curve;
        uint256 cap;
        // Wiring.
        address iai;
        address a0G;
        address oracle;
        address foundation;
        address registryIai;
        // Live accounting. Every 0G in here is someone's redeemable collateral.
        uint256 totalLocked0G;
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
        s.cap = vault.cap();

        s.iai = address(vault.iai());
        s.a0G = address(vault.a0G());
        s.oracle = address(vault.oracle());
        s.foundation = vault.foundation();
        s.registryIai = address(registry.iai());

        s.totalLocked0G = vault.totalLocked0G();
        s.supply = vault.supply();
        s.tokenSupply = token.totalSupply();
        s.paused = vault.paused();
        s.totalStaked = registry.totalStaked();
        s.cooldownDuration = registry.cooldownDuration();

        // Probe only within the headroom. A full or lowered cap makes `quoteMint` revert,
        // and an upgrade rehearsal has to stay runnable in that state.
        s.quotesAvailable = vault.remainingCap() >= 100e18;
        if (s.quotesAvailable) {
            (s.quote1,) = vault.quoteMint(1e18);
            (s.quote100,) = vault.quoteMint(100e18);
        }

        s.accounts = accounts;
        s.locked = new uint256[](accounts.length);
        s.outstanding = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            (s.locked[i], s.outstanding[i],) = vault.positionOf(accounts[i]);
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
        _eq(after_.cap, before_.cap, "cap");

        _eqAddr(after_.iai, before_.iai, "iai");
        _eqAddr(after_.a0G, before_.a0G, "a0G");
        _eqAddr(after_.oracle, before_.oracle, "oracle");
        _eqAddr(after_.foundation, before_.foundation, "foundation");
        _eqAddr(after_.registryIai, before_.registryIai, "registryIai");

        _eq(after_.totalLocked0G, before_.totalLocked0G, "totalLocked0G");
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
     *      Silent when there is no headroom: `quoteMint` reverts at or past the cap.
     */
    function _assertPricingMatchesCurve(IAIVault vault) internal view {
        uint256 headroom = vault.remainingCap();
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
