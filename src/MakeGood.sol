// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "solmate/tokens/ERC721.sol";

/**
 * @title MakeGood
 * @notice Make GoodToken
 * @author BlockByBlock
 **/
contract MakeGood is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;
    string public baseURI;
    uint256 public vaultCount;

    mapping(uint256 => uint256) public vaultCollateral;
    mapping(uint256 => uint256) public vaultDebt;

    event CreateVault(uint256 vaultID, address creator);
    event DestroyVault(uint256 vaultID);

    IERC20 public immutable collateral;

    IERC20 public immutable goodToken;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        IERC20 _collateral,
        IERC20 _goodToken
    ) ERC721(_name, _symbol) {
        baseURI = _baseURI;
        collateral = _collateral;
        goodToken = _goodToken;
    }

    /**
     * @notice check if sender is vault owner
     * @param vaultID vault ID
     */
    modifier onlyVaultOwner(uint256 vaultID) {
        require(_ownerOf[vaultID] == msg.sender, "Vault not owned by you");
        _;
    }

    /**
     * @notice NFT URI
     * @param vaultID ID of Vault
     */
    function tokenURI(uint256 vaultID) public view virtual override returns (string memory) {
        require(_ownerOf[vaultID] != address(0), "ERC721Metadata: URI query for nonexistent token");
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, vaultID.toString())) : "";
    }

    /**
     * @notice Create a vault (NFT)
     * @return vault Id
     */
    function createVault() external returns (uint256) {
        uint256 id = vaultCount;
        vaultCount = vaultCount + 1;

        assert(vaultCount >= id);

        _mint(msg.sender, id);

        emit CreateVault(id, msg.sender);

        return id;
    }

    /**
     * @notice Destroy a vault (NFT)
     * @param vaultID vault ID
     */
    function destroyVault(uint256 vaultID) external onlyVaultOwner(vaultID) nonReentrant {
        require(vaultDebt[vaultID] == 0, "Vault has outstanding debt");

        if(vaultCollateral[vaultID] != 0) {
            // withdraw leftover collateral
            collateral.transfer(_ownerOf[vaultID], vaultCollateral[vaultID]);
        }

        _burn(vaultID);

        delete vaultCollateral[vaultID];
        delete vaultDebt[vaultID];

        emit DestroyVault(vaultID);
    }
}
