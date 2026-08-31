// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAI} from "../../src/IAI.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";
import {MockA0GOracle} from "../../src/mocks/MockA0GOracle.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IA0G} from "../../src/interfaces/external/IA0G.sol";
import {MintCurve} from "../../src/libraries/MintCurve.sol";

/**
 * @title IAIDeployer
 * @notice The one and only description of how the iAI system is wired together.
 *
 * @dev Both the deployment script and the test fixture inherit this and call
 *      `_deployIAISystem`. That is the point: a fixture that re-implemented the wiring
 *      would leave the script itself untested, and the two would drift apart silently —
 *      the tests could keep passing against a topology that the script no longer produces.
 *
 *      **This must be an internal function on an inherited contract, not a deployed helper.**
 *      `BeaconProxy` delegatecalls `initialize` during construction, so `msg.sender` inside
 *      `initialize` is whoever executed the `new`. Calling out to a separate deployer
 *      contract would hand `DEFAULT_ADMIN_ROLE` to that contract instead of to the
 *      deploying account. Inheriting keeps the creations in the caller's own frame, which
 *      is the deployer EOA under `vm.broadcast` and the test contract under `forge test`.
 */
abstract contract IAIDeployer {
    /// @param a0G              Collateral token. The live a0G on mainnet, a mock elsewhere.
    /// @param foundation       Recipient of harvested yield.
    /// @param r0               Marginal price at supply zero, 0G per iAI.
    /// @param cap              Hard supply ceiling, wei-iAI.
    /// @param target           Total 0G locked at full supply; fixes the slope.
    /// @param cooldownDuration Withdrawal delay in the credit registry.
    struct Config {
        address a0G;
        address foundation;
        uint256 r0;
        uint256 cap;
        uint256 target;
        uint256 cooldownDuration;
        string name;
        string symbol;
    }

    /// @param initialValue Starting exchange rate, 0G per a0G scaled by 1e18.
    /// @param apr          Simple annual accrual, scaled by 1e18. Test networks want this far
    ///                     above production so the rate visibly moves within a session.
    /// @param maxAge       Seconds before `getValue()` starts reverting as stale.
    struct MockConfig {
        uint256 initialValue;
        uint256 apr;
        uint256 maxAge;
    }

    struct Deployment {
        address iai;
        address iaiImpl;
        address iaiBeacon;
        address vault;
        address vaultImpl;
        address vaultBeacon;
        address registry;
        address registryImpl;
        address registryBeacon;
        uint256 slope;
    }

    /**
     * @notice Deploys stand-in collateral for a network that has no real a0G.
     * @param c     Oracle parameters.
     * @param owner Account that may pin the rate afterwards, via `setValue` / `setApr`.
     * @return oracle The rate source.
     * @return a0g    The collateral token, already pointing at `oracle`.
     *
     * @dev Lives beside the system wiring, and is used by both the script and the test
     *      fixture, so the collateral the tests run against is the collateral a testnet gets.
     */
    function _deployMockCollateral(MockConfig memory c, address owner)
        internal
        returns (MockA0GOracle oracle, MockA0G a0g)
    {
        oracle = new MockA0GOracle(c.initialValue, c.apr, c.maxAge, owner);
        a0g = new MockA0G(address(oracle));
    }

    /**
     * @param c            Parameters, normally read from the deployment JSON.
     * @param operator     The account actually executing this deployment. Each `initialize`
     *                     grants `DEFAULT_ADMIN_ROLE` to its own `msg.sender`, and the
     *                     post-deploy grants and checks below must name that same account.
     * @param beaconOwner  Holds the upgrade key for all three beacons. Separate beacons per
     *                     contract so one upgrade cannot reach the others.
     *
     * @dev Initializer calldata rides in each proxy's constructor so deployment and
     *      initialization are a single transaction. Split across two, anyone could
     *      initialize the proxy first and own the curve.
     *
     *      `operator` is a parameter rather than `msg.sender` because under `vm.broadcast`
     *      the two differ: Solidity sees this contract as `msg.sender`, while the proxies
     *      are actually created by the broadcasting key, so that key is what `initialize`
     *      records as admin. Reading `msg.sender` here would grant `PAUSER_ROLE` to an
     *      address that holds nothing and leave the real admin without it.
     */
    function _deployIAISystem(Config memory c, address operator, address beaconOwner)
        internal
        returns (Deployment memory d)
    {
        d.iaiImpl = address(new IAI());
        d.iaiBeacon = address(new UpgradeableBeacon(d.iaiImpl, beaconOwner));
        d.iai = address(
            new BeaconProxy(d.iaiBeacon, abi.encodeCall(IAI.initialize, (c.name, c.symbol, c.cap)))
        );

        d.vaultImpl = address(new IAIVault());
        d.vaultBeacon = address(new UpgradeableBeacon(d.vaultImpl, beaconOwner));
        d.vault = address(
            new BeaconProxy(
                d.vaultBeacon,
                abi.encodeCall(
                    IAIVault.initialize,
                    (
                        IIAIVault.InitParams({
                            iai: d.iai,
                            a0G: c.a0G,
                            foundation: c.foundation,
                            r0: c.r0,
                            cap: c.cap,
                            target: c.target
                        })
                    )
                )
            )
        );

        d.registryImpl = address(new CreditRegistry());
        d.registryBeacon = address(new UpgradeableBeacon(d.registryImpl, beaconOwner));
        d.registry = address(
            new BeaconProxy(
                d.registryBeacon,
                abi.encodeCall(CreditRegistry.initialize, (d.iai, c.cooldownDuration))
            )
        );

        // The vault is the only issuer of iAI; nothing else ever holds this role.
        IAI(d.iai).grantRole(IAI(d.iai).MINTER_BURNER_ROLE(), d.vault);

        // The vault deploys paused, and `DEFAULT_ADMIN_ROLE` does not implicitly carry any
        // other role. Without this grant the system would ship permanently closed with
        // nobody able to open it. The deployer holds it until governance takes over.
        IAIVault(d.vault).grantRole(IAIVault(d.vault).PAUSER_ROLE(), operator);
        CreditRegistry(d.registry).grantRole(CreditRegistry(d.registry).PAUSER_ROLE(), operator);

        d.slope = IAIVault(d.vault).slope();
        _assertDeploymentSane(c, d, operator);
    }

    /**
     * @param c        The parameters the deployment was asked for.
     * @param d        The addresses it produced.
     * @param operator The account that executed it, and therefore the one `initialize`
     *                 recorded as admin.
     *
     * @dev Runs on every deployment, including inside the test fixture, so a wiring mistake
     *      surfaces in CI rather than on a network.
     */
    function _assertDeploymentSane(Config memory c, Deployment memory d, address operator) internal view {
        IAI token = IAI(d.iai);
        IAIVault vault_ = IAIVault(d.vault);
        CreditRegistry registry_ = CreditRegistry(d.registry);

        require(token.hasRole(token.MINTER_BURNER_ROLE(), d.vault), "vault cannot mint");
        require(token.cap() == c.cap, "cap mismatch");
        require(address(vault_.iai()) == d.iai, "vault points at the wrong token");
        require(address(vault_.a0G()) == c.a0G, "vault points at the wrong collateral");
        require(address(vault_.oracle()) == address(IA0G(c.a0G).oracle()), "oracle not cached");
        require(address(registry_.iai()) == d.iai, "registry points at the wrong token");

        // The slope must be the derived one, not anything a caller supplied.
        require(vault_.slope() == MintCurve.deriveSlope(c.r0, c.cap, c.target), "slope not derived");
        // Full supply must lock the intended collateral, up to the flooring of the slope.
        uint256 atCap = vault_.lockedAt(c.cap);
        require(atCap <= c.target && c.target - atCap < 1e12, "curve does not reach the target");

        // Issuance must come up closed; opening it is an explicit governance action. The
        // registry needs no such gate -- nobody can stake before iAI exists.
        require(vault_.paused(), "vault must deploy paused");
        // Someone must actually be able to open it, or the deployment is bricked.
        require(vault_.hasRole(vault_.PAUSER_ROLE(), operator), "nobody can unpause the vault");
        require(registry_.hasRole(registry_.PAUSER_ROLE(), operator), "nobody can unpause the registry");
        require(vault_.hasRole(0x00, operator), "deployer is not the vault admin");
    }
}
