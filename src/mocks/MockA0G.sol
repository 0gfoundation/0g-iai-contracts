// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IA0G} from "../interfaces/external/IA0G.sol";
import {IA0GOracle} from "../interfaces/external/IA0GOracle.sol";

/**
 * @title MockA0G
 * @notice Stand-in for a0G on networks where the real one is not deployed.
 *
 * @dev Shaped after the real token, Mellow's `SourceCore`: an ERC-4626 vault over W0G whose
 *      **share price comes from the oracle rather than from what it holds**. `SourceCore`
 *      inherits OpenZeppelin's ERC-4626 and overrides exactly one conversion input:
 *
 *          totalAssets() = totalSupply() * oracle.getValue() / 1e18
 *
 *      Everything else — `convertToShares`, `convertToAssets`, `previewDeposit`, `deposit` —
 *      is OpenZeppelin's, so it all follows from that one number. This contract does the
 *      same, which is why it inherits ERC-4626 instead of hand-rolling the arithmetic: a
 *      hand-rolled conversion would be *less* faithful, missing the virtual-share offset the
 *      real token inherits along with everything else.
 *
 *      Deriving the price from holdings instead would break an identity that holds on
 *      mainnet — `oracle.getValue()`, `convertToAssets(1e18)` and `totalAssets/totalSupply`
 *      are all the same number there, because W0G is one-for-one with 0G. A frontend sizing a
 *      deposit off `previewDeposit` would then get an amount the vault values differently.
 *
 *      One consequence of inheriting ERC-4626 rather than pricing by hand: an **empty** vault
 *      quotes one for one whatever the oracle says, because the first deposit is valued
 *      against a virtual share. That is inherited, not chosen, and the real token did the same
 *      at its own genesis. On a testnet it is reachable only between deploying this and
 *      funding the test accounts, since funding mints supply.
 *
 *      **Not modelled: redemption.** The real token reverts in `_withdraw`, so ERC-4626's
 *      `withdraw` and `redeem` do not work there either — but it *is* redeemable, through
 *      `requestWithdrawal` and an epoch-based withdrawal queue. iAI never redeems a0G, so
 *      none of that is reproduced here. Do not read the revert below as "a0G cannot be
 *      redeemed"; it means "this mock does not model how".
 *
 *      `faucetMint` and `batchMint` are unrestricted, so on a testnet this doubles as the
 *      faucet. They mint shares with no assets behind them, which is only self-consistent
 *      because `totalAssets()` is derived from supply rather than from the balance held —
 *      as it is on mainnet.
 */
contract MockA0G is IA0G, ERC4626 {
    IA0GOracle private immutable _oracle;

    /**
     * @param asset_  Underlying the vault is denominated in. W0G in every real deployment.
     * @param oracle_ Exchange-rate source. Fixed at construction, matching the real token.
     */
    constructor(address asset_, address oracle_)
        ERC20("Mock Ascend Staked 0G", "a0G")
        ERC4626(IERC20(asset_))
    {
        _oracle = IA0GOracle(oracle_);
    }

    /// @inheritdoc IA0G
    function oracle() external view returns (IA0GOracle) {
        return _oracle;
    }

    /**
     * @inheritdoc ERC4626
     * @dev The one override that matters, and the same one `SourceCore` makes. Every other
     *      conversion in ERC-4626 is expressed in terms of this, so overriding it here puts
     *      the oracle in charge of the whole vault.
     */
    function totalAssets() public view override returns (uint256) {
        return Math.mulDiv(totalSupply(), _oracle.getValue(), 1e18);
    }

    /**
     * @notice Open faucet. Anyone may mint to anyone; this exists only on test networks.
     * @param to     Recipient.
     * @param amount Amount of shares to mint, in wei.
     *
     * @dev Named `faucetMint` rather than `mint` because ERC-4626 already defines
     *      `mint(uint256 shares, address receiver)`. Two functions called `mint` with the
     *      arguments the other way round is the kind of thing that reads fine and gets
     *      called wrong, and it makes clients that dispatch on name alone ambiguous.
     */
    function faucetMint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Mints the same amount to many addresses, so funding a test cohort is a few
     *         transactions rather than one per account.
     * @param recipients Addresses to credit.
     * @param amount     Amount minted to each, in wei.
     */
    function batchMint(address[] calldata recipients, uint256 amount) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], amount);
        }
    }

    /**
     * @inheritdoc ERC4626
     * @dev `SourceCore` closes this path by overriding `_withdraw`, which both of ERC-4626's
     *      exits funnel through. Doing that here makes the `return` at the end of each of
     *      those library functions unreachable, and the compiler says so -- two warnings in
     *      an otherwise clean build, which is how the next real warning gets missed. Closing
     *      the two exits directly is the same behaviour with nothing left dangling.
     */
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("MockA0G: withdrawal queue not modelled");
    }

    /// @inheritdoc ERC4626
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("MockA0G: withdrawal queue not modelled");
    }
}
