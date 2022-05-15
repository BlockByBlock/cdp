// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "solmate/tokens/ERC20.sol";
import "solmate/auth/Owned.sol";

/**
 * @title GoodToken
 * @notice Basic ERC20 implementation
 * @author BlockByBlock
 **/
contract GoodToken is ERC20, Owned {
    struct Minting {
        uint256 time;
        uint256 amount;
    }

    Minting public lastMint;
    uint256 private constant MINTING_PERIOD = 24 hours;
    uint256 private constant MINTING_INCREASE = 15000;
    uint256 private constant MINTING_PRECISION = 1e5;
    constructor() ERC20("Good Token", "GUDGOOD", 18) Owned(msg.sender) {}

    /**
     * @dev Mint tokens
     * @param to The recipient of the tokens
     * @param amount The amount of tokens being mintede
     **/
    function mint(address to, uint256 amount) external onlyOwner {
        // Limits the amount minted per period to a convergence function, with the period duration restarting on every mint
        uint256 totalMintedAmount = uint256(lastMint.time < (block.timestamp - MINTING_PERIOD) ? 0 : lastMint.amount) + amount;
        require(totalSupply == 0 || totalSupply * (MINTING_INCREASE) / MINTING_PRECISION >= totalMintedAmount);

        lastMint.time = block.timestamp;
        lastMint.amount = totalMintedAmount;

        _mint(to, amount);
    }

    /**
     * @dev Burn tokens
     * @param amount The amount of tokens to burn
     **/
    function burn(uint256 amount) external {
        require(amount <= balanceOf[msg.sender], "MIM: not enough");
        _burn(msg.sender, amount);
    }
}
