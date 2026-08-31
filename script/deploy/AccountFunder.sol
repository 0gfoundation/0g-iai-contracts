// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";

import {MockA0G} from "../../src/mocks/MockA0G.sol";

/**
 * @title AccountFunder
 * @notice Deriving and funding a batch of test accounts, with no file access.
 *
 * @dev Separated from the script so the parts that touch a chain can be tested on their own.
 *      Writing the key file is the caller's job.
 */
abstract contract AccountFunder is Script {
    /// @dev Native transfers are ~21k each; 200 sits well inside a block at any 0G gas limit.
    uint256 internal constant GAS_BATCH = 200;
    /// @dev Minting only writes a balance slot, so batches can be larger.
    uint256 internal constant MINT_BATCH = 500;

    /**
     * @param mnemonic  BIP-39 phrase to derive from. The same phrase always yields the same set.
     * @param count     How many accounts to derive, starting at index 0.
     * @param forbidden An address the set must not contain -- in practice the deployer, whose
     *                  key would otherwise be published along with the test accounts.
     * @return addrs Derived addresses, in derivation order.
     * @return keys  Their private keys, same order.
     */
    function _deriveAccounts(string memory mnemonic, uint256 count, address forbidden)
        internal
        pure
        returns (address[] memory addrs, uint256[] memory keys)
    {
        addrs = new address[](count);
        keys = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            keys[i] = vm.deriveKey(mnemonic, uint32(i));
            addrs[i] = vm.addr(keys[i]);
            // The deployer holds DEFAULT_ADMIN and the beacons. The key file gets handed to
            // whoever is testing, so publishing that key would hand over the deployment with
            // it. Common with the stock anvil mnemonic, hence the check.
            require(addrs[i] != forbidden, "TEST_MNEMONIC derives the deployer key");
        }
    }

    /**
     * @param a0g     Mock collateral to mint from.
     * @param addrs   Accounts to fund.
     * @param gasEach Native balance each account is topped **up to**, in wei.
     * @param a0GEach Mock a0G minted to each account, in wei.
     *
     * @dev Native gas has to be transferred one account at a time out of the caller's own
     *      balance, while a0G can be minted in batches; both are chunked, because a thousand
     *      transfers do not fit in one block. Accounts already at `gasEach` are skipped, so a
     *      rerun after a partial failure costs only what it still needs to send.
     */
    function _fundAccounts(MockA0G a0g, address[] memory addrs, uint256 gasEach, uint256 a0GEach)
        internal
    {
        uint256 count = addrs.length;
        for (uint256 start = 0; start < count; start += MINT_BATCH) {
            a0g.batchMint(_slice(addrs, start, MINT_BATCH), a0GEach);
        }
        for (uint256 i = 0; i < count; i++) {
            if (addrs[i].balance < gasEach) payable(addrs[i]).transfer(gasEach - addrs[i].balance);
        }
    }

    /**
     * @param all   Source array.
     * @param start First index to take.
     * @param size  Maximum number of entries; the result is shorter at the end of `all`.
     * @return out The selected entries.
     */
    function _slice(address[] memory all, uint256 start, uint256 size)
        internal
        pure
        returns (address[] memory out)
    {
        uint256 end = start + size > all.length ? all.length : start + size;
        out = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = all[i];
        }
    }
}
