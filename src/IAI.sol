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
 *      The cap is enforced here as well as in the vault. The vault's own supply accounting
 *      is the primary bound; this is a second, independent one that survives a bug there.
 */
contract IAI is IIAI, ERC20Upgradeable, AccessControlUpgradeable {
    /// @notice Held only by the vault. Granted at deployment, never to an EOA.
    bytes32 public constant MINTER_BURNER_ROLE = keccak256("MINTER_BURNER_ROLE");

    /// @custom:storage-location erc7201:0g.iai.IAI
    struct IAIStorage {
        uint256 cap;
    }

    // keccak256(abi.encode(uint256(keccak256("0g.iai.IAI")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IAIStorageLocation =
        0xa82bb8f0bd2e715f19257d1c2af6490407305a1f43c97209bb7c823bfb50a800;

    function _getIAIStorage() private pure returns (IAIStorage storage $) {
        assembly {
            $.slot := IAIStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // The implementation sits behind a beacon, which does not protect it from being
        // initialized directly. Lock it down at construction.
        _disableInitializers();
    }

    /**
     * @param name_   Token name.
     * @param symbol_ Token symbol.
     * @param cap_    Hard supply ceiling in wei-iAI. Immutable thereafter.
     * @dev Admin is the deployer; it is expected to be handed to a multisig before launch.
     */
    function initialize(string memory name_, string memory symbol_, uint256 cap_) external initializer {
        if (cap_ == 0) revert ZeroCap();

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _getIAIStorage().cap = cap_;
    }

    /// @inheritdoc IIAI
    function cap() public view returns (uint256) {
        return _getIAIStorage().cap;
    }

    /// @inheritdoc IIAI
    function mint(address to, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        uint256 supplyAfter = totalSupply() + amount;
        uint256 cap_ = _getIAIStorage().cap;
        if (supplyAfter > cap_) revert CapExceeded(supplyAfter, cap_);
        _mint(to, amount);
    }

    /// @inheritdoc IIAI
    function burn(address from, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        _burn(from, amount);
    }
}
