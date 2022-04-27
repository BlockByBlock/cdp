// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "solmate/tokens/ERC20.sol";

error Unauthorized();

contract Contract is ERC20 {
    // todo: mutable owner
    address public immutable owner;
    constructor() ERC20("Good Token", "GUDGOOD", 18) {
        owner = msg.sender;
    }

    // danger
    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _mint(to, amount);
    }
}
