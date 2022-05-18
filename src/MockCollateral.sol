// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "solmate/tokens/ERC20.sol";

contract MockCollateral is ERC20("Mock Collateral", "MOCK", 18) {
    function mint(address _recipient, uint256 _amount) public {
        _mint(_recipient, _amount);
    }
}