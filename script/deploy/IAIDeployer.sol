// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {IAI} from "../../src/IAI.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";
import {MockW0G} from "../../src/mocks/MockW0G.sol";
import {MockA0GOracle} from "../../src/mocks/MockA0GOracle.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {IIAIVault} from "../../src/interfaces/IIAIVault.sol";
import {IA0G} from "../../src/interfaces/external/IA0G.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {LinearMintCurve} from "../../src/curves/LinearMintCurve.sol";
import {ExponentialMintCurve} from "../../src/curves/ExponentialMintCurve.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
    /// @param curveKind        Which curve to deploy: `"ExponentialMintCurve"` (the default) or
    ///                         `"LinearMintCurve"`.
    /// @param cap              Starting supply ceiling, wei-iAI. Adjustable after launch.
    /// @param cooldownDuration Withdrawal delay in the credit registry.
    struct Config {
        address a0G;
        address foundation;
        string curveKind;
        uint256 cap;
        uint256 cooldownDuration;
        string name;
        string symbol;
    }

    /// @param r0        Marginal price at supply zero, 0G per iAI.
    /// @param anchorCap The supply the slope is derived against, wei-iAI. **Not the vault's
    ///                  cap**, even though a fresh deployment sets both from the same number.
    ///                  The vault's cap is adjustable and drifts away; this one is burned into
    ///                  the curve at construction and records only how the slope was reached.
    ///                  Feeding a moved cap in here derives a different curve from the same
    ///                  published `r0` and `target`, and every number involved still looks
    ///                  plausible.
    /// @param target    0G the curve accounts for at `anchorCap`; together with `r0` and
    ///                  `anchorCap` this fixes the slope.
    ///
    /// @dev Parameters belong to a curve, not to a deployment. This struct is
    ///      `LinearMintCurve`'s; a differently shaped curve brings its own rather than
    ///      widening this one, which is what keeps adding a curve additive.
    struct LinearCurveParams {
        uint256 r0;
        uint256 anchorCap;
        uint256 target;
    }

    /// @param bucketWidth Width of every bucket, wei-iAI.
    /// @param prices      One price per bucket, wei-0G per iAI, in supply order. **Generated,
    ///                    never hand-written**: `script/curve/gen_exponential_table.py` derives
    ///                    them from `bucketWidth` and the three parameters below, and
    ///                    `run.sh check` re-derives them and compares. Nothing about the vault's
    ///                    cap enters into it.
    /// @param base        Marginal price at zero supply the table was derived from. Provenance.
    /// @param exponent    Exponent coefficient the table was derived from, scaled by 1e18. Provenance.
    /// @param target      Supply the exponent is normalised against, wei-iAI. Provenance -- the
    ///                    vault's cap is its own number, and the table's top is what bounds it.
    ///
    /// @dev `ExponentialMintCurve`'s own parameters, kept apart from the linear curve's.
    struct ExponentialCurveParams {
        uint256 bucketWidth;
        uint128[] prices;
        uint256 base;
        uint256 exponent;
        uint256 target;
    }

    /// @param asset        Underlying the mock a0G is a vault over. Zero deploys a `MockW0G`;
    ///                      a network that already has the real W0G names it here instead, so
    ///                      the wrapping hop can be exercised against the actual token.
    /// @param initialValue Starting exchange rate, 0G per a0G scaled by 1e18.
    /// @param apr          Simple annual accrual, scaled by 1e18. Test networks want this far
    ///                     above production so the rate visibly moves within a session.
    /// @param maxAge       Seconds before `getValue()` starts reverting as stale.
    struct MockConfig {
        address asset;
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
        address curve;
    }

    /**
     * @notice Deploys stand-in collateral for a network that has no real a0G.
     * @param c     Oracle parameters, and the underlying to build the vault over.
     * @param owner Account that may pin the rate afterwards, via `setValue` / `setApr`.
     * @return oracle The rate source.
     * @return a0g    The collateral token, already pointing at `oracle` and `asset`.
     * @return asset  The underlying, either `c.asset` or a freshly deployed `MockW0G`.
     *
     * @dev Lives beside the system wiring, and is used by both the script and the test
     *      fixture, so the collateral the tests run against is the collateral a testnet gets.
     *
     *      The underlying comes first: a0G takes it as a constructor argument, and like the
     *      real token it has no setter for it afterwards.
     */
    function _deployMockCollateral(MockConfig memory c, address owner)
        internal
        returns (MockA0GOracle oracle, MockA0G a0g, address asset)
    {
        asset = c.asset == address(0) ? address(new MockW0G()) : c.asset;
        oracle = new MockA0GOracle(c.initialValue, c.apr, c.maxAge, owner);
        a0g = new MockA0G(asset, address(oracle));
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
    function _deployIAISystem(
        Config memory c,
        IMintCurve curve,
        address operator,
        address beaconOwner
    ) internal returns (Deployment memory d) {
        d.iaiImpl = address(new IAI());
        d.iaiBeacon = address(new UpgradeableBeacon(d.iaiImpl, beaconOwner));
        d.iai = address(
            new BeaconProxy(d.iaiBeacon, abi.encodeCall(IAI.initialize, (c.name, c.symbol)))
        );

        // Deployed by the caller, because only the caller knows what shape of curve it is
        // building. It has to exist before the vault either way: the vault takes it as an
        // initializer argument, and it is an immutable value rather than a proxy, so there is
        // nothing to point at it afterwards.
        d.curve = address(curve);

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
                            curve: d.curve,
                            cap: c.cap
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
        _assertWiring(c, d);

        IAIVault vault_ = IAIVault(d.vault);
        CreditRegistry registry_ = CreditRegistry(d.registry);

        // Issuance must come up closed; opening it is an explicit governance action. The
        // registry needs no such gate -- nobody can stake before iAI exists.
        require(vault_.paused(), "vault must deploy paused");
        // Someone must actually be able to open it, or the deployment is bricked.
        require(vault_.hasRole(vault_.PAUSER_ROLE(), operator), "nobody can unpause the vault");
        require(registry_.hasRole(registry_.PAUSER_ROLE(), operator), "nobody can unpause the registry");
        require(vault_.hasRole(0x00, operator), "deployer is not the vault admin");
    }

    /**
     * @param c The parameters the deployment was asked for.
     * @param d The addresses it produced.
     *
     * @dev The half that stays true for the life of the deployment, so it can be re-run against
     *      a live system. Every address is checked to actually hold code first: a run that is
     *      interrupted still writes its deployment file, because the file is written during
     *      simulation, so the record can name a contract that was never deployed. Reading a
     *      value back from such an address returns nothing and would otherwise pass unnoticed.
     */
    function _assertWiring(Config memory c, Deployment memory d) internal view {
        _assertHasCode(d.iai, "IAI");
        _assertHasCode(d.iaiImpl, "IAIImpl");
        _assertHasCode(d.iaiBeacon, "IAIBeacon");
        _assertHasCode(d.vault, "IAIVault");
        _assertHasCode(d.vaultImpl, "IAIVaultImpl");
        _assertHasCode(d.vaultBeacon, "IAIVaultBeacon");
        _assertHasCode(d.registry, "CreditRegistry");
        _assertHasCode(d.registryImpl, "CreditRegistryImpl");
        _assertHasCode(d.registryBeacon, "CreditRegistryBeacon");
        _assertHasCode(c.a0G, "A0G");
        _assertHasCode(d.curve, "MintCurve");

        IAI token = IAI(d.iai);
        IAIVault vault_ = IAIVault(d.vault);
        CreditRegistry registry_ = CreditRegistry(d.registry);

        require(token.hasRole(token.MINTER_BURNER_ROLE(), d.vault), "vault cannot mint");
        require(address(vault_.iai()) == d.iai, "vault points at the wrong token");
        require(address(vault_.a0G()) == c.a0G, "vault points at the wrong collateral");
        require(address(vault_.oracle()) == address(IA0G(c.a0G).oracle()), "oracle not cached");
        require(address(registry_.iai()) == d.iai, "registry points at the wrong token");

        require(address(vault_.curve()) == d.curve, "vault points at the wrong curve");
        require(vault_.cap() == c.cap, "cap mismatch");

        // The vault must actually route to the curve it names. This is not a tautology: it
        // catches an implementation whose pricing ignores the advertised curve. Whether the
        // curve's own maths is right is settled by the conformance suite and golden vectors,
        // not here.
        //
        // Skipped once the cap is reached or has been lowered below the supply -- `quoteMint`
        // reverts there by design, and this check must not make `run.sh check` unusable in
        // exactly the state an operator most needs to inspect.
        uint256 headroom = vault_.remainingCap();
        if (headroom != 0) {
            uint256 probe = headroom < 1e18 ? headroom : 1e18;
            (uint256 quoted,) = vault_.quoteMint(probe);
            require(quoted == IMintCurve(d.curve).cost(vault_.supply(), probe), "vault prices off its curve");
        }
    }

    /**
     * @param p The curve's own parameters.
     * @return The deployed curve.
     *
     * @dev One typed function per curve kind, rather than one function switching on a name.
     *      A name-switched deployer has to accept the union of every curve's parameters, so
     *      each new curve widens a struct every other curve then carries fields it has no use
     *      for — and a caller that fills in the wrong subset gets a curve that constructs
     *      cleanly and prices differently. That is why `_deployExponentialCurve` sits beside
     *      this one rather than inside it.
     */
    function _deployLinearCurve(LinearCurveParams memory p) internal returns (IMintCurve) {
        return new LinearMintCurve(p.r0, p.anchorCap, p.target);
    }

    /**
     * @param p The curve's own parameters, table included.
     * @return The deployed curve.
     */
    function _deployExponentialCurve(ExponentialCurveParams memory p) internal returns (IMintCurve) {
        return new ExponentialMintCurve(p.bucketWidth, p.prices, p.base, p.exponent, p.target);
    }

    /**
     * @param curve The deployed exponential curve to compare.
     * @param p     The parameters and table the record carries for it.
     *
     * @dev The vault cannot tell one table from another, and neither can a verifier reading
     *      the contract's source: the table is constructor data. This is the check that the
     *      curve on chain is the one the record describes, entry by entry. The caller reads
     *      the record; this half only reads the chain.
     */
    function _assertExponentialCurveMatches(address curve, ExponentialCurveParams memory p) internal view {
        ExponentialMintCurve c = ExponentialMintCurve(curve);
        require(c.bucketWidth() == p.bucketWidth, "curve bucket width differs from the record");
        require(c.bucketCount() == p.prices.length, "curve bucket count differs from the record");
        require(c.base() == p.base, "curve base differs from the record");
        require(c.exponent() == p.exponent, "curve exponent differs from the record");
        require(c.target() == p.target, "curve target differs from the record");

        uint128[] memory onChain = c.prices();
        for (uint256 i = 0; i < p.prices.length; i++) {
            require(
                onChain[i] == p.prices[i],
                string.concat("curve price differs from the record at bucket ", Strings.toString(i))
            );
        }
    }

    /**
     * @param a    Address that must be a contract.
     * @param name Key it was read from, so a failure names the entry to fix.
     */
    function _assertHasCode(address a, string memory name) internal view {
        require(a != address(0), string.concat("no address recorded for ", name));
        require(a.code.length != 0, string.concat("no code at the recorded ", name));
    }
}
