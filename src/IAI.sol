// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IIAI} from "./interfaces/IIAI.sol";

/**
 * @title IAI
 * @notice The Infinite AI token. Every unit in existence has 0G collateral locked behind
 *         it in the vault, and the vault is the only contract that can create or destroy one.
 *
 * @dev Deliberately minimal. Two properties carry weight:
 *
 *      1. **No self-burn.** `ERC20Burnable` is not inherited and there is no allowance-based
 *         burn path. A holder burning their own tokens would desynchronise `totalSupply()`
 *         from the vault's own supply counter — and since redeeming collateral requires
 *         handing the matching tokens back, it would also strand that holder's collateral
 *         permanently. The only burner is the vault, acting on a redemption.
 *
 *      2. **Freely transferable, no hooks.** The compute entitlement is a bearer right:
 *         whoever holds and stakes a token earns it. Collateral redemption is the opposite
 *         — name-bound to the original minter. Keeping transfer unrestricted is what makes
 *         that separation real rather than nominal.
 *
 *      **The supply cap lives in the vault, not here.** It has to: the cap is now
 *      governance-adjustable in both directions, and a second immutable copy in the token
 *      would either block a raise or drift out of agreement. What that gives up is a bound
 *      on `DEFAULT_ADMIN_ROLE` here -- it can grant `MINTER_BURNER_ROLE` to anything, and
 *      nothing in this contract limits what that mints. Since the role now has no other use,
 *      renouncing it or moving it behind a timelock costs nothing and is the mitigation.
 */
contract IAI is IIAI, ERC20Upgradeable, AccessControlUpgradeable {
    /// @notice Held only by the vault. Granted at deployment, never to an EOA.
    bytes32 public constant MINTER_BURNER_ROLE = keccak256("MINTER_BURNER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // The implementation sits behind a beacon, which does not protect it from being
        // initialized directly. Lock it down at construction.
        _disableInitializers();
    }

    /**
     * @param name_   Token name.
     * @param symbol_ Token symbol.
     * @dev Admin is the deployer; it is expected to be handed to a multisig before launch.
     */
    function initialize(string memory name_, string memory symbol_) external initializer {
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @inheritdoc IIAI
    function mint(address to, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IIAI
    function burn(address from, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        _burn(from, amount);
    }
}
