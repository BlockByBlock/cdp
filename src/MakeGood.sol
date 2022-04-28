// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/Strings.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "solmate/tokens/ERC721.sol";

import "./PriceConsumerV3.sol";

/**
 * @title MakeGood
 * @notice Make GoodToken
 * @author BlockByBlock
 **/
contract MakeGood is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;

    string public baseURI;
    uint256 public vaultCount;
    uint256 public tokenPeg;
    uint256 public treasury;
    uint256 public closingFee;
    uint256 public openingFee;
    uint256 public minimumCollateralPercentage;

    mapping(uint256 => uint256) public vaultCollateral;
    mapping(uint256 => uint256) public vaultDebt;

    event CreateVault(uint256 vaultID, address creator);
    event DestroyVault(uint256 vaultID);
    event DepositCollateral(uint256 vaultID, uint256 amount);
    event WithdrawCollateral(uint256 vaultID, uint256 amount);
    event BorrowToken(uint256 vaultID, uint256 amount);
    event PayBackToken(uint256 vaultID, uint256 amount, uint256 closingFee);

    IERC20 public immutable collateral;
    IERC20 public immutable goodToken;
    PriceConsumerV3 public ethOracleFeed;

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

        closingFee = 50; // 0.5%
        openingFee = 0; // 0.0%
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
     * @notice the max debt that can be borrowed as good token from the maker
     */
    function getDebtCeiling() public view returns (uint256) {
        return goodToken.balanceOf(address(this));
    }

    /**
     * @notice NFT URI
     * @param vaultID ID of Vault
     */
    function tokenURI(uint256 vaultID) public view virtual override returns (string memory) {
        require(_ownerOf[vaultID] != address(0), "ERC721Metadata: URI query for nonexistent token");
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, vaultID.toString())) : "";
    }

    function getTokenPriceSource() public view returns (uint256) {
        return tokenPeg;
    }

    function getEthPriceSource() public view returns (uint256) {
        int256 price = ethOracleFeed.getLatestPrice();
        return uint256(price); // brings it back to 18.
    }

    function calculateCollateralProperties(uint256 _collateral, uint256 _debt) private view returns (uint256, uint256) {
        assert(getEthPriceSource() != 0);
        assert(getTokenPriceSource() != 0);

        uint256 collateralValue = _collateral * getEthPriceSource();

        assert(collateralValue >= _collateral);

        uint256 debtValue = _debt * getTokenPriceSource();

        assert(debtValue >= _debt);

        uint256 collateralValueTimes100 = collateralValue * 100;

        assert(collateralValueTimes100 > collateralValue);

        return (collateralValueTimes100, debtValue);
    }

    function isValidCollateral(uint256 _collateral, uint256 debt) private view returns (bool) {
        (uint256 collateralValueTimes100, uint256 debtValue) = calculateCollateralProperties(_collateral, debt);

        uint256 collateralPercentage = (collateralValueTimes100 * (10**10)) / debtValue;

        return collateralPercentage >= minimumCollateralPercentage;
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

        if (vaultCollateral[vaultID] != 0) {
            // withdraw leftover collateral
            collateral.transfer(_ownerOf[vaultID], vaultCollateral[vaultID]);
        }

        _burn(vaultID);

        delete vaultCollateral[vaultID];
        delete vaultDebt[vaultID];

        emit DestroyVault(vaultID);
    }

    /**
     * @notice Deposit collateral into vault
     * @param vaultID vault ID
     * @param amount amount of collateral
     */
    function depositCollateral(uint256 vaultID, uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);

        uint256 newCollateralAmt = vaultCollateral[vaultID] + amount;

        assert(newCollateralAmt >= vaultCollateral[vaultID]);

        vaultCollateral[vaultID] = newCollateralAmt;

        emit DepositCollateral(vaultID, amount);
    }

    /**
     * @notice Withdraw collateral from vault
     * @param vaultID vault ID
     * @param amount amount of collateral
     */
    function withdrawCollateral(uint256 vaultID, uint256 amount) external onlyVaultOwner(vaultID) nonReentrant {
        require(vaultCollateral[vaultID] >= amount, "Vault does not have enough collateral");

        uint256 newCollateralAmt = vaultCollateral[vaultID] - amount;

        if (vaultDebt[vaultID] != 0) {
            require(
                isValidCollateral(newCollateralAmt, vaultDebt[vaultID]),
                "Withdrawal would put vault below minimum collateral percentage"
            );
        }

        vaultCollateral[vaultID] = newCollateralAmt;
        collateral.transfer(msg.sender, amount);

        emit WithdrawCollateral(vaultID, amount);
    }

    /**
     * @notice borrow good token
     * @param vaultID Vault ID
     * @param amount Amount of good token to borrow
     */
    function borrowToken(uint256 vaultID, uint256 amount) external onlyVaultOwner(vaultID) {
        require(amount > 0, "Must borrow non-zero amount");
        require(amount <= getDebtCeiling(), "borrowToken: Cannot mint over available supply.");

        uint256 newDebt = vaultDebt[vaultID] + amount;

        assert(newDebt > vaultDebt[vaultID]);

        require(
            isValidCollateral(vaultCollateral[vaultID], newDebt),
            "Borrow would put vault below minimum collateral percentage"
        );

        vaultDebt[vaultID] = newDebt;

        // goodToken
        goodToken.transfer(msg.sender, amount);

        emit BorrowToken(vaultID, amount);
    }

    /**
     * @notice repay good token
     * @param vaultID Vault ID
     * @param amount Amount of good token to repay
     */
    function payBackToken(uint256 vaultID, uint256 amount) external {
        require(goodToken.balanceOf(msg.sender) >= amount, "Token balance too low");
        require(vaultDebt[vaultID] >= amount, "Vault debt less than amount to pay back");

        uint256 _closingFee = (amount * closingFee * getTokenPriceSource()) /
            (getEthPriceSource() * 10000) /
            1000000000;

        //mai
        goodToken.transferFrom(msg.sender, address(this), amount);

        vaultDebt[vaultID] = vaultDebt[vaultID] - amount;
        vaultCollateral[vaultID] = vaultCollateral[vaultID] - _closingFee;
        vaultCollateral[treasury] = vaultCollateral[treasury] + _closingFee;

        emit PayBackToken(vaultID, amount, _closingFee);
    }
}
