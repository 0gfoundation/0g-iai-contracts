// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {JsonUtils} from "./Utils.s.sol";
import {Constants} from "./Constants.s.sol";
import {IAIDeployer} from "./IAIDeployer.sol";
import {IAI} from "../../src/IAI.sol";
import {IAIVault} from "../../src/IAIVault.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {IMintCurve} from "../../src/interfaces/IMintCurve.sol";
import {IA0G} from "../../src/interfaces/external/IA0G.sol";

/**
 * @title IAIScript
 * @notice Deploys the iAI system and records it, plus the handful of operational calls that
 *         are needed after launch.
 *
 * @dev The wiring itself lives in `IAIDeployer`, which the test fixture also inherits, so
 *      the topology this script produces is the one every test runs against.
 *
 *      Parameters come from `deployments/iai-<chainId>.json`; the resulting addresses are
 *      written back to the same file. Secrets only ever come from the environment.
 */
contract IAIScript is Script, JsonUtils, Constants, IAIDeployer {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        (string memory json, string memory path) = loadOrInitJson("iai");

        Config memory c = Config({
            a0G: vm.parseJsonAddress(json, ".A0G"),
            foundation: vm.parseJsonAddress(json, ".Foundation"),
            curveKind: vm.parseJsonString(json, ".MintCurveKind"),
            cap: vm.parseJsonUint(json, ".Cap"),
            cooldownDuration: vm.parseJsonUint(json, ".CooldownDuration"),
            name: vm.parseJsonString(json, ".Name"),
            symbol: vm.parseJsonString(json, ".Symbol")
        });

        vm.startBroadcast(pk);
        Deployment memory d = _deployIAISystem(c, _curveOfKind(json, c.curveKind), deployer, deployer);
        vm.stopBroadcast();

        console.log("network        ", networkName());
        console.log("iAI            ", d.iai);
        console.log("IAIVault       ", d.vault);
        console.log("CreditRegistry ", d.registry);
        console.log("curve          ", d.curve, c.curveKind);
        console.log("");
        console.log("Issuance is PAUSED. Open it with --sig 'unpause()' when ready.");
        console.log("DEFAULT_ADMIN and the beacon owner are the deployer; hand them to the");
        console.log("multisig before launch.");

        // Seed with the file as it stands so nothing already recorded is lost -- the mock
        // addresses, and any notes the operator keeps alongside them.
        string memory obj = "iai";
        vm.serializeJson(obj, json);

        // Echo the inputs so a rerun of this script cannot silently drop them.
        vm.serializeAddress(obj, "A0G", c.a0G);
        vm.serializeAddress(obj, "Foundation", c.foundation);
        vm.serializeString(obj, "MintCurveKind", c.curveKind);
        // `Cap` is echoed because `setCap` rewrites it; the curve's own parameters under
        // `CurveParams` are never written by any script, and seeding the object from the file
        // above already carries them through untouched.
        vm.serializeString(obj, "Cap", vm.toString(c.cap));
        vm.serializeString(obj, "CooldownDuration", vm.toString(c.cooldownDuration));
        vm.serializeString(obj, "Name", c.name);
        vm.serializeString(obj, "Symbol", c.symbol);

        vm.serializeAddress(obj, "IAIImpl", d.iaiImpl);
        vm.serializeAddress(obj, "IAIBeacon", d.iaiBeacon);
        vm.serializeAddress(obj, "IAI", d.iai);
        vm.serializeAddress(obj, "IAIVaultImpl", d.vaultImpl);
        vm.serializeAddress(obj, "IAIVaultBeacon", d.vaultBeacon);
        vm.serializeAddress(obj, "IAIVault", d.vault);
        vm.serializeAddress(obj, "CreditRegistryImpl", d.registryImpl);
        vm.serializeAddress(obj, "CreditRegistryBeacon", d.registryBeacon);
        vm.serializeAddress(obj, "CreditRegistry", d.registry);

        // The active curve, the same address under its own kind, and the running list of
        // every curve this record has named -- the kind key holds only the newest of its
        // kind, so without the list a redeploy would drop an address that historical mints
        // were priced by and that is still live on chain.
        vm.serializeAddress(obj, c.curveKind, d.curve);
        vm.serializeAddress(obj, "MintCurveHistory", _appendCurve(json, d.curve));
        // Only the last `serialize` call returns the completed document.
        string memory finalJson = vm.serializeAddress(obj, "MintCurve", d.curve);

        vm.writeJson(finalJson, path);
    }

    // --- operational entrypoints ---

    /// @notice Opens issuance and staking. Deliberately a separate, explicit transaction.
    function unpause() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).unpause();
        // The registry deploys open, so it is only unpaused here if something closed it.
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));
        if (registry.paused()) registry.unpause();
        vm.stopBroadcast();
    }

    function pause() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).pause();
        CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry")).pause();
        vm.stopBroadcast();
    }

    function harvest() public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        uint256 swept = IAIVault(vm.parseJsonAddress(json, ".IAIVault")).harvest();
        vm.stopBroadcast();
        console.log("swept a0G      ", swept);
    }

    /**
     * @notice Changes the unstaking delay on a live deployment. `DEFAULT_ADMIN_ROLE`.
     * @param newDuration New delay in seconds.
     *
     * @dev Also rewrites `CooldownDuration` in the deployment record, so the file keeps
     *      describing the chain. Applies to withdrawals started after this call; anything
     *      already cooling down keeps the end time it was given.
     */
    function setCooldownDuration(uint256 newDuration) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry")).setCooldownDuration(newDuration);
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.writeJson(vm.serializeString(o, "CooldownDuration", vm.toString(newDuration)), path);
        console.log("cooldownDuration", newDuration);
    }

    /**
     * @notice Deploys a curve of the given kind from the parameters in the record, and records
     *         its address under that kind. Does **not** put it into service.
     * @param kind Curve contract name, e.g. `"LinearMintCurve"`.
     *
     * @dev Two steps on purpose: deploy, read the address back, then switch. A curve is an
     *      immutable value, so several may coexist in one record and the active one is
     *      whichever `MintCurve` names.
     */
    function deployCurve(string memory kind) public {
        (string memory json, string memory path) = loadOrInitJson("iai");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address deployed = address(_curveOfKind(json, kind));
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.serializeAddress(o, kind, deployed);
        vm.writeJson(vm.serializeAddress(o, "MintCurveHistory", _appendCurve(json, deployed)), path);

        console.log("deployed       ", kind, deployed);
        console.log("Not yet in service. Switch with --sig 'setCurve(string)' when ready.");
    }

    /**
     * @param json The record as it stands.
     * @param kind Curve contract name, e.g. `"LinearMintCurve"`.
     * @return The freshly deployed curve.
     *
     * @dev The only place that knows a curve kind's name maps to a particular parameter
     *      shape, and it lives in the script half because that is the half that reads files.
     *      Each kind owns its own block under `CurveParams`, so its parameters are read with
     *      the keys and the types that kind actually has -- a second curve adds a branch here
     *      and a block in the record, and touches neither the other curve's parameters nor
     *      the system deployer.
     */
    function _curveOfKind(string memory json, string memory kind) private returns (IMintCurve) {
        string memory at = string.concat(".CurveParams.", kind, ".");

        if (keccak256(bytes(kind)) == keccak256(bytes("LinearMintCurve"))) {
            return _deployLinearCurve(
                LinearCurveParams({
                    r0: vm.parseJsonUint(json, string.concat(at, "R0")),
                    anchorCap: vm.parseJsonUint(json, string.concat(at, "AnchorCap")),
                    target: vm.parseJsonUint(json, string.concat(at, "Target"))
                })
            );
        }
        if (keccak256(bytes(kind)) == keccak256(bytes(EXPONENTIAL))) {
            return _deployExponentialCurve(_exponentialParamsOf(json));
        }
        revert(string.concat("unknown curve kind: ", kind));
    }

    string private constant EXPONENTIAL = "ExponentialMintCurve";

    /**
     * @param json The record as it stands.
     * @return p The exponential curve's block, table included.
     *
     * @dev Shared by `deployCurve` and `checkDeployment`, so the two cannot read the table
     *      differently. The record stores every integer as a decimal string and forge coerces
     *      those when parsing, the same way `Cap` is read; a value that does not fit the
     *      contract's `uint128` entries is refused here rather than truncated.
     */
    function _exponentialParamsOf(
        string memory json
    ) private pure returns (ExponentialCurveParams memory p) {
        string memory at = string.concat(".CurveParams.", EXPONENTIAL, ".");
        uint256[] memory raw = vm.parseJsonUintArray(json, string.concat(at, "Prices"));
        uint128[] memory prices = new uint128[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            require(raw[i] <= type(uint128).max, "ExponentialMintCurve price does not fit uint128");
            prices[i] = uint128(raw[i]);
        }
        p = ExponentialCurveParams({
            bucketWidth: vm.parseJsonUint(json, string.concat(at, "BucketWidth")),
            prices: prices,
            base: vm.parseJsonUint(json, string.concat(at, "Base")),
            exponent: vm.parseJsonUint(json, string.concat(at, "Exponent")),
            target: vm.parseJsonUint(json, string.concat(at, "Target"))
        });
    }

    /**
     * @param json     The record as it stands.
     * @param deployed The curve just deployed.
     * @return Every curve this record has ever named, with `deployed` appended.
     *
     * @dev The kind key holds only the newest curve of its kind, and `MintCurve` only the
     *      active one, so without this a redeploy of the same kind would drop an address that
     *      is still needed: reconciling historical mints means knowing which curve priced
     *      them, and that curve is still live on chain whether or not the record names it.
     */
    function _appendCurve(string memory json, address deployed)
        private
        pure
        returns (address[] memory)
    {
        address[] memory history;
        try vm.parseJsonAddressArray(json, ".MintCurveHistory") returns (address[] memory a) {
            history = a;
        } catch {
            history = new address[](0);
        }

        // A record written before this list existed has an incumbent curve and no history.
        // Appending only the newcomer would drop the incumbent the moment `setCurve` moves
        // `MintCurve` off it -- and that curve priced positions that are still open, so its
        // address is still needed to reconcile them. Adopt it before appending.
        if (history.length == 0) {
            try vm.parseJsonAddress(json, ".MintCurve") returns (address incumbent) {
                if (incumbent != address(0)) history = _append(history, incumbent);
            } catch {}
        }

        return _append(history, deployed);
    }

    /**
     * @param list  Addresses recorded so far.
     * @param entry Address to add.
     * @return The list with `entry` at the end, or unchanged if it is already present --
     *         re-running a script must not record the same curve twice.
     */
    function _append(address[] memory list, address entry) private pure returns (address[] memory) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == entry) return list;
        }
        address[] memory next = new address[](list.length + 1);
        for (uint256 i = 0; i < list.length; i++) {
            next[i] = list[i];
        }
        next[list.length] = entry;
        return next;
    }

    /**
     * @notice Puts an already-deployed curve into service, by kind. `DEFAULT_ADMIN_ROLE`.
     * @param kind Curve contract name, which must already be recorded by `deployCurve`.
     *
     * @dev Prices only future mints. Everything already minted keeps its own price, because
     *      positions record an absolute 0G amount and redemption never consults a curve.
     */
    function setCurve(string memory kind) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        address target = vm.parseJsonAddress(json, string.concat(".", kind));
        require(target != address(0), "no curve recorded under that kind -- run deployCurve first");

        // Pre-flight, before anything is broadcast: the exponential kind key must be the curve
        // the record's table describes. After `genCurve` without `deployCurve` the key still
        // names the previous table, and switching to it would spend a governance transaction on
        // a curve the very next `check` refuses.
        if (keccak256(bytes(kind)) == keccak256(bytes(EXPONENTIAL))) {
            _assertHasCode(target, EXPONENTIAL);
            _assertExponentialCurveMatches(target, _exponentialParamsOf(json));
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setCurve(IMintCurve(target));
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.serializeString(o, "MintCurveKind", kind);
        vm.writeJson(vm.serializeAddress(o, "MintCurve", target), path);

        console.log("now pricing on ", kind, target);
    }

    /**
     * @notice Moves the supply ceiling. `DEFAULT_ADMIN_ROLE`.
     * @param newCap New ceiling in wei-iAI. Below the current supply this closes issuance
     *               while leaving redemption working.
     */
    function setCap(uint256 newCap) public {
        (string memory json, string memory path) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setCap(newCap);
        vm.stopBroadcast();

        string memory o = "iai";
        vm.serializeJson(o, json);
        vm.writeJson(vm.serializeString(o, "Cap", vm.toString(newCap)), path);
        console.log("cap            ", newCap);
    }

    function setFoundation(address newFoundation) public {
        (string memory json,) = loadOrInitJson("iai");
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        IAIVault(vm.parseJsonAddress(json, ".IAIVault")).setFoundation(newFoundation);
        vm.stopBroadcast();
    }

    /**
     * @notice Lets one address mint while issuance is paused. `DEFAULT_ADMIN_ROLE`.
     * @param account Address to admit.
     *
     * @dev Deliberately not part of any deployment path, and the holder is deliberately not
     *      written into the deployment record: the grant is a governance transaction of its
     *      own, and so is the revoke meant to follow it. Nothing reads the holder back from
     *      disk, so there is no copy of it to go stale or to be mistaken for policy. Read the
     *      chain with `pausedMintExemption` instead.
     */
    function grantPausedMintExemption(address account) public {
        (string memory json,) = loadOrInitJson("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        // Hoisted out of the broadcast: a view call in an argument position is the mistake this
        // repository has paid for three times, and it belongs in neither a script nor a test.
        bytes32 role = vault.PAUSE_EXEMPT_MINTER_ROLE();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        vault.grantRole(role, account);
        vm.stopBroadcast();

        console.log("granted to     ", account);
    }

    /**
     * @notice Takes that permission back. `DEFAULT_ADMIN_ROLE`.
     * @param account Address to close out.
     */
    function revokePausedMintExemption(address account) public {
        (string memory json,) = loadOrInitJson("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        bytes32 role = vault.PAUSE_EXEMPT_MINTER_ROLE();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        vault.revokeRole(role, account);
        vm.stopBroadcast();

        console.log("revoked from   ", account);
    }

    /**
     * @notice Read-only. Whether `account` may mint right now, and why.
     * @param account Address to read.
     *
     * @dev Prints both halves because either alone is misleading: paused with the exemption is
     *      open for this address, and unpaused without it is open for everyone.
     */
    function pausedMintExemption(address account) public view {
        (string memory json,) = loadOrInitJsonView("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));

        console.log("network        ", networkName());
        console.log("account        ", account);
        console.log("paused (vault) ", vault.paused());
        console.log("may mint paused", vault.hasRole(vault.PAUSE_EXEMPT_MINTER_ROLE(), account));
    }

    /**
     * @notice Read-only. What minting `d` iAI costs at the current supply and rate.
     * @param d Amount of iAI, in wei-iAI.
     *
     * @dev Works while paused -- quoting is not gated -- so it is the right way to size
     *      `maxA0GIn` before a mint of either kind. Widen the printed figure before using it.
     */
    function quoteMint(uint256 d) public view {
        (string memory json,) = loadOrInitJsonView("iai");
        (uint256 delta0G, uint256 a0GIn) = IAIVault(vm.parseJsonAddress(json, ".IAIVault")).quoteMint(d);

        console.log("iAI out        ", d);
        console.log("0G value       ", delta0G);
        console.log("a0G in         ", a0GIn);
    }

    /**
     * @notice Mints `d` iAI to the broadcasting key, approving the collateral first.
     * @param d        Amount of iAI to mint, in wei-iAI.
     * @param maxA0GIn Most a0G the caller accepts spending, in wei-a0G. Take it from
     *                 `quoteMint` and widen it.
     *
     * @dev Mints to itself, because `mint` always does: the position belongs to whoever sends
     *      the transaction, so this is only usable from the key that should hold it.
     *
     *      Approves `maxA0GIn` rather than the quote. The quote is read during simulation, and
     *      a rate move before inclusion would otherwise turn a mint the caller still accepts
     *      into a failed transfer.
     */
    function mint(uint256 d, uint256 maxA0GIn) public {
        (string memory json,) = loadOrInitJson("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IA0G a0G = vault.a0G();
        bool wasPaused = vault.paused();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        a0G.approve(address(vault), maxA0GIn);
        // An hour is long enough to survive a slow inclusion and short enough that a stuck
        // transaction expires rather than landing at a price nobody looked at.
        vault.mint(d, maxA0GIn, block.timestamp + 1 hours);
        vm.stopBroadcast();

        console.log("minted         ", d);
        console.log("while paused   ", wasPaused);
        console.log("supply         ", vault.supply());
    }

    /**
     * @notice Re-checks the recorded deployment against the chain. Read-only.
     *
     * @dev Worth running after every deployment, because the record is written during
     *      simulation: a run interrupted partway -- this chain's RPC intermittently answers
     *      `eth_getTransactionReceipt` with null and forge gives up after a few retries --
     *      still leaves a file naming contracts that were never deployed. Nothing later
     *      notices, because reading from an address with no code simply returns nothing.
     */
    function checkDeployment() public view {
        (string memory json,) = loadOrInitJsonView("iai");

        Config memory c = Config({
            a0G: vm.parseJsonAddress(json, ".A0G"),
            foundation: vm.parseJsonAddress(json, ".Foundation"),
            curveKind: vm.parseJsonString(json, ".MintCurveKind"),
            cap: vm.parseJsonUint(json, ".Cap"),
            cooldownDuration: vm.parseJsonUint(json, ".CooldownDuration"),
            name: vm.parseJsonString(json, ".Name"),
            symbol: vm.parseJsonString(json, ".Symbol")
        });
        Deployment memory d = Deployment({
            iai: vm.parseJsonAddress(json, ".IAI"),
            iaiImpl: vm.parseJsonAddress(json, ".IAIImpl"),
            iaiBeacon: vm.parseJsonAddress(json, ".IAIBeacon"),
            vault: vm.parseJsonAddress(json, ".IAIVault"),
            vaultImpl: vm.parseJsonAddress(json, ".IAIVaultImpl"),
            vaultBeacon: vm.parseJsonAddress(json, ".IAIVaultBeacon"),
            registry: vm.parseJsonAddress(json, ".CreditRegistry"),
            registryImpl: vm.parseJsonAddress(json, ".CreditRegistryImpl"),
            registryBeacon: vm.parseJsonAddress(json, ".CreditRegistryBeacon"),
            curve: vm.parseJsonAddress(json, ".MintCurve")
        });

        _assertWiring(c, d);

        // The exponential curve is a table, and a table can only be checked entry by entry.
        // Compared against the *kind key*, not `MintCurve`: the active curve may legitimately
        // be an older one, while the kind key is by definition the newest curve built from the
        // parameters beside it.
        //
        // **How loud a disagreement is depends on whether that curve is pricing anything.**
        // When the exponential kind is in force, the record no longer describes the table every
        // mint is charged against, and the check has to fail; both the parameter block and the
        // address are required for the same reason. When some other curve is in force, the only
        // thing out of step is a dormant contract, and `genCurve` deliberately leaves the record
        // ahead of the chain until `deployCurve` catches it up -- failing there would refuse a
        // healthy deployment in the middle of the documented procedure, which is the exact shape
        // of failure the two-step window was built to avoid.
        bool inForce = keccak256(bytes(c.curveKind)) == keccak256(bytes(EXPONENTIAL));
        bool hasBlock = vm.keyExistsJson(json, string.concat(".CurveParams.", EXPONENTIAL));
        bool hasKey = vm.keyExistsJson(json, string.concat(".", EXPONENTIAL));
        if (inForce) {
            require(hasBlock, "MintCurveKind is ExponentialMintCurve but the record has no CurveParams block -- run genCurve");
            require(hasKey, "MintCurveKind is ExponentialMintCurve but no ExponentialMintCurve address is recorded");
        }
        if (hasBlock && hasKey) {
            // An interrupted run records an address that was never deployed, and a hand edit can
            // leave a zero; both are named as the record entry to fix rather than failing on an
            // empty return from `bucketWidth()`. That much holds whichever curve is in force.
            address newest = vm.parseJsonAddress(json, string.concat(".", EXPONENTIAL));
            _assertHasCode(newest, EXPONENTIAL);

            string memory mismatch = _exponentialCurveMismatch(newest, _exponentialParamsOf(json));
            if (bytes(mismatch).length != 0) {
                require(!inForce, mismatch);
                console.log("WARNING        ", mismatch);
                console.log("                the ExponentialMintCurve is not in force, so nothing is mispriced;");
                console.log("                'deployCurve ExponentialMintCurve' catches the chain up to the record.");
            }
        }

        console.log("network        ", networkName());
        console.log("every recorded address holds code and the wiring matches the file.");
    }

    /// @notice Read-only snapshot. Run without `--broadcast`.
    function status() public view {
        (string memory json,) = loadOrInitJsonView("iai");
        IAIVault vault = IAIVault(vm.parseJsonAddress(json, ".IAIVault"));
        IAI token = IAI(vm.parseJsonAddress(json, ".IAI"));
        CreditRegistry registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));

        console.log("network        ", networkName());
        console.log("paused (vault) ", vault.paused());
        console.log("supply         ", token.totalSupply());
        console.log("cap            ", vault.cap());
        console.log("remainingCap   ", vault.remainingCap());
        console.log("curve          ", address(vault.curve()));
        console.log("totalLocked0G  ", vault.totalLocked0G());
        console.log("exchangeRate   ", vault.exchangeRate());
        console.log("pendingSurplus ", vault.pendingSurplus());
        console.log("foundation     ", vault.foundation());
        console.log("totalStaked    ", registry.totalStaked());
    }

    /**
     * @param task Artifact name to read.
     * @return The file's contents and its path.
     * @dev `status` is `view`, so it cannot use the writing variant of the JSON loader.
     */
    function loadOrInitJsonView(string memory task) internal view returns (string memory, string memory) {
        string memory path = deploymentPath(task);
        return (vm.readFile(path), path);
    }
}
