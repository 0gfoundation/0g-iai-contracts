// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockW0G
 * @notice Stand-in for Wrapped 0G on networks that do not already have it.
 *
 * @dev Exists so `MockA0G` has an underlying asset to be an ERC-4626 vault over. On Galileo
 *      the **real** W0G is already deployed, at the same address as on mainnet, so this is
 *      not used there — the deployment record names the real one and the scripts use it.
 *      This is for anvil and the unit fixture.
 *
 *      Wrapping is the usual native-token pattern: send 0G, receive W0G one for one. The
 *      unrestricted `mint` is on top of that, so a test can hand out W0G without first
 *      funding an account with native currency.
 */
contract MockW0G is ERC20 {
    /// @notice Native currency was wrapped.
    event Deposit(address indexed account, uint256 amount);
    /// @notice W0G was unwrapped back to native currency.
    event Withdrawal(address indexed account, uint256 amount);

    constructor() ERC20("Wrapped 0G", "W0G") {}

    /// @notice Wraps the native currency sent with the call, one for one.
    function deposit() public payable {
        _mint(_msgSender(), msg.value);
        emit Deposit(_msgSender(), msg.value);
    }

    /**
     * @notice Burns W0G and returns the same amount of native currency.
     * @param amount Amount to unwrap, in wei.
     */
    function withdraw(uint256 amount) external {
        _burn(_msgSender(), amount);
        emit Withdrawal(_msgSender(), amount);
        (bool ok,) = payable(_msgSender()).call{value: amount}("");
        require(ok, "MockW0G: native transfer failed");
    }

    /**
     * @notice Open faucet. Anyone may mint to anyone; this exists only on test networks.
     * @param to     Recipient.
     * @param amount Amount to mint, in wei.
     *
     * @dev Unbacked, so this contract can owe more native currency than it holds. That is
     *      fine here and would not be on a real wrapper: nothing in the tests unwraps what
     *      it did not wrap.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {
        deposit();
    }
}
