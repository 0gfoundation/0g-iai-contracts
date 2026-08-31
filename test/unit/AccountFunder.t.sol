// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";

import {AccountFunder} from "../../script/deploy/AccountFunder.sol";
import {IAIDeployer} from "../../script/deploy/IAIDeployer.sol";
import {MockA0G} from "../../src/mocks/MockA0G.sol";
import {MockA0GOracle} from "../../src/mocks/MockA0GOracle.sol";

/**
 * @title AccountFunderTest
 * @notice Deriving and funding the testnet account set, with no file access.
 *
 * @dev The keys these produce are handed to other people, so "the file looks well-formed" is
 *      not enough — a key that does not control its stated address would only be discovered by
 *      whoever first tried to sign with it.
 */
contract AccountFunderTest is Test, IAIDeployer, AccountFunder {
    /// @dev A published BIP-39 test vector. Deliberately not anvil's stock phrase.
    string internal constant MNEMONIC =
        "legal winner thank year wave sausage worth useful legal winner thank yellow";

    MockA0G internal a0g;

    function setUp() public {
        (, a0g) = _deployMockCollateral(
            MockConfig({initialValue: 1e18, apr: 0.15e18, maxAge: 21 days}), address(this)
        );
        vm.deal(address(this), 1000 ether);
    }

    function test_DerivesKeysThatControlTheirAddresses() public pure {
        (address[] memory addrs, uint256[] memory keys) = _deriveAccounts(MNEMONIC, 8, address(0xdead));

        assertEq(addrs.length, 8);
        assertEq(keys.length, 8);
        for (uint256 i = 0; i < addrs.length; i++) {
            assertEq(vm.addr(keys[i]), addrs[i], "private key does not control its address");
            assertTrue(addrs[i] != address(0));
            for (uint256 j = 0; j < i; j++) {
                assertTrue(addrs[i] != addrs[j], "derivation must not repeat an address");
            }
        }
    }

    /// @dev The same phrase must always give the same set, or a rerun funds different accounts
    ///      than the file that was already handed out.
    function test_DerivationIsReproducible() public pure {
        (address[] memory first,) = _deriveAccounts(MNEMONIC, 4, address(0xdead));
        (address[] memory second,) = _deriveAccounts(MNEMONIC, 4, address(0xdead));
        for (uint256 i = 0; i < 4; i++) {
            assertEq(first[i], second[i]);
        }
    }

    /// @dev The deployer holds DEFAULT_ADMIN and the beacons. Publishing that key alongside the
    ///      test accounts would hand over the deployment with them.
    function test_RefusesToDeriveTheForbiddenAddress() public {
        (address[] memory addrs,) = _deriveAccounts(MNEMONIC, 3, address(0xdead));

        vm.expectRevert(bytes("TEST_MNEMONIC derives the deployer key"));
        this.deriveExternal(MNEMONIC, 3, addrs[1]);
    }

    function test_FundsGasAndCollateral() public {
        (address[] memory addrs,) = _deriveAccounts(MNEMONIC, 5, address(this));

        _fundAccounts(a0g, addrs, 0.5 ether, 1234e18);

        for (uint256 i = 0; i < addrs.length; i++) {
            assertEq(addrs[i].balance, 0.5 ether, "gas");
            assertEq(a0g.balanceOf(addrs[i]), 1234e18, "collateral");
        }
    }

    /// @dev A rerun after a partial failure must top accounts back up without re-sending to the
    ///      ones that are already funded.
    function test_FundingOnlySendsTheShortfall() public {
        (address[] memory addrs,) = _deriveAccounts(MNEMONIC, 5, address(this));
        _fundAccounts(a0g, addrs, 0.5 ether, 1000e18);

        vm.prank(addrs[0]);
        payable(address(0xdead)).transfer(0.2 ether);

        uint256 spentBefore = 1000 ether - address(this).balance;
        _fundAccounts(a0g, addrs, 0.5 ether, 1000e18);

        assertEq(addrs[0].balance, 0.5 ether, "the drained account is topped back up");
        assertEq(
            1000 ether - address(this).balance - spentBefore, 0.2 ether, "only the shortfall was sent"
        );
        // Collateral is minted, not transferred, so a rerun simply mints again.
        assertEq(a0g.balanceOf(addrs[1]), 2000e18);
    }

    /// @dev Batching is where an off-by-one strands the last account of a run.
    function test_SliceCoversEveryAccountExactlyOnce() public pure {
        address[] memory all = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            all[i] = address(uint160(i + 1));
        }

        uint256 seen;
        for (uint256 start = 0; start < 7; start += 3) {
            address[] memory chunk = _slice(all, start, 3);
            for (uint256 i = 0; i < chunk.length; i++) {
                assertEq(chunk[i], all[start + i], "chunk entry is misplaced");
                seen++;
            }
        }
        assertEq(seen, 7, "every account appears exactly once");
        assertEq(_slice(all, 6, 3).length, 1, "the final chunk is short, not padded");
    }

    /// @dev `vm.expectRevert` needs a call frame, and `_deriveAccounts` is internal.
    function deriveExternal(string memory mnemonic, uint256 count, address forbidden) external pure {
        _deriveAccounts(mnemonic, count, forbidden);
    }

    receive() external payable {}
}
