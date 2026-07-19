// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only token that makes a callback during transferFrom.
contract ReentrantERC20 is ERC20 {
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackEnabled;
    bool public lastCallbackSuccess;
    bytes public lastCallbackResult;

    constructor() ERC20("Reentrant Token", "REENT") { }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configureCallback(address target, bytes calldata data, bool enabled) external {
        callbackTarget = target;
        callbackData = data;
        callbackEnabled = enabled;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (callbackEnabled) {
            (lastCallbackSuccess, lastCallbackResult) = callbackTarget.call(callbackData);
        }

        return super.transferFrom(from, to, value);
    }
}
