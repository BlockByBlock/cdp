// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "solmate/tokens/ERC20.sol";

contract Contract is ERC20 {
    constructor() ERC20("Good Token", "GUDGOOD", 18) {}

    // danger
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
