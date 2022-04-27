// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import "forge-std/Test.sol";

import "../Contract.sol";

contract ContractTest is DSTest {
    Contract a;
    Vm private vm = Vm(HEVM_ADDRESS);

    function setUp() public {
        a = new Contract();
    }

    function testTokenMint() public {
        assertEq(a.balanceOf(address(this)), 0);
        a.mint(address(this), 1e18);
        assertGt(a.balanceOf(address(this)), 0);
    }

    function testTokenMintAsNotOwner() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(address(1));
        a.mint(address(1), 1e18);
        assertEq(a.balanceOf(address(1)), 0);
    }
}
