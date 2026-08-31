// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";

/**
 * @title JsonUtils
 * @notice Locates the per-network deployment file and creates it on first use.
 *
 * @dev One file per (task, chain), at `deployments/<task>-<chainId>.json`. The same file
 *      holds both the hand-written input parameters and the addresses a run produces, so a
 *      deployment is reproducible from the artifact it wrote.
 *
 *      Network selection is implicit in `--rpc-url`: whatever chain is dialled decides the
 *      filename. There is no `--network` flag to get out of sync with the RPC.
 */
contract JsonUtils is Script {
    /// @dev Per-instance override of the deployment directory, taking precedence over
    ///      `DEPLOYMENT_PATH`. Tests need it: `vm.setEnv` writes the *process* environment,
    ///      which forge's parallel test contracts all share, so one suite's redirect would
    ///      silently become another's. On the command line `DEPLOYMENT_PATH` is still the
    ///      way to redirect, and leaving this unset changes nothing.
    string private deploymentDirOverride;

    function setDeploymentDir(string memory dir) public {
        deploymentDirOverride = dir;
    }

    function loadOrInitJson(string memory task) internal returns (string memory json, string memory path) {
        return loadOrInitJsonWithChainId(task, block.chainid);
    }

    function loadOrInitJsonWithChainId(string memory task, uint256 chainId)
        internal
        returns (string memory json, string memory path)
    {
        path = deploymentPath(task, chainId);

        try vm.readFile(path) returns (string memory content) {
            json = content;
        } catch {
            json = "{}";
            vm.writeJson(json, path);
        }
    }

    /**
     * @notice Where a task's artifact lives, for the chain currently being dialled.
     * @param task Artifact name, e.g. `"iai"` or `"test-accounts"`.
     * @return Absolute path to `<dir>/<task>-<chainId>.json`.
     */
    function deploymentPath(string memory task) internal view returns (string memory) {
        return deploymentPath(task, block.chainid);
    }

    /**
     * @param task    Artifact name, e.g. `"iai"`.
     * @param chainId Chain the artifact belongs to; part of the filename.
     * @return Absolute path to `<dir>/<task>-<chainId>.json`.
     */
    function deploymentPath(string memory task, uint256 chainId) internal view returns (string memory) {
        string memory dir = deploymentDirOverride;
        if (bytes(dir).length == 0) {
            dir = vm.envOr("DEPLOYMENT_PATH", string(""));
        }
        if (bytes(dir).length == 0) {
            dir = string.concat(vm.projectRoot(), "/deployments");
        }
        return string.concat(dir, "/", task, "-", vm.toString(chainId), ".json");
    }
}
