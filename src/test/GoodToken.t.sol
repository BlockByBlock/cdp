// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import "forge-std/Test.sol";

import "../GoodToken.sol";

contract GoodTokenTest is DSTest {
    GoodToken goodToken;
    Vm private vm = Vm(HEVM_ADDRESS);

    function setUp() public {
        goodToken = new GoodToken();
        vm.warp(72 hours);
    }

    function testTokenMint() public {
        assertEq(goodToken.balanceOf(address(this)), 0);
        goodToken.mint(address(this), 1e18);
        assertGt(goodToken.balanceOf(address(this)), 0);
    }

    function testTokenMintAsNotOwner() public {
        vm.expectRevert('Ownable: caller is not the owner');
        vm.prank(address(2));
        goodToken.mint(address(2), 1e18);
        assertEq(goodToken.balanceOf(address(2)), 0);
    }
}
