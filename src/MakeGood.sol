// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "solmate/tokens/ERC721.sol";
import "solmate/auth/Owned.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "solmate/utils/SafeTransferLib.sol";

import "./PriceConsumerV3.sol";

/**
 * @title MakeGood
 * @notice Make GoodToken
 * @author BlockByBlock
 **/
contract MakeGood is ERC721, Owned, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    string public baseURI;
    uint256 public vaultCount;
    uint256 public tokenPeg;
    uint256 public treasury;
    uint256 public closingFee;
    uint256 public openingFee;
    uint256 public debtRatio;
    uint256 public gainRatio;
    uint256 public minimumCollateralPercentage;

    address public stabilityPool;

    mapping(uint256 => uint256) public vaultCollateral;
    mapping(uint256 => uint256) public vaultDebt;

    event CreateVault(uint256 vaultID, address creator);
    event DestroyVault(uint256 vaultID);
    event DepositCollateral(uint256 vaultID, uint256 amount);
    event WithdrawCollateral(uint256 vaultID, uint256 amount);
    event BorrowToken(uint256 vaultID, uint256 amount);
    event PayBackToken(uint256 vaultID, uint256 amount, uint256 closingFee);
    event LiquidateVault(uint256 vaultID, address owner, address buyer, uint256 debtRepaid, uint256 collateralLiquidated, uint256 closingFee);

    ERC20 public immutable collateral;
    ERC20 public immutable goodToken;
    PriceConsumerV3 public ethOracleFeed;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        address _collateral,
        address _goodToken
    ) ERC721(_name, _symbol) Owned(msg.sender) {
        baseURI = _baseURI;
        collateral = ERC20(_collateral);
        goodToken = ERC20(_goodToken);

        closingFee = 50; // 0.5%
        openingFee = 0; // 0.0%

        tokenPeg = 100000000; // $1

        debtRatio = 2; // 1/2, pay back 50%
        gainRatio = 1100;// /10 so 1.1
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
     * @notice utility to convert uint256 to string for vaultID
     * @param value uint256
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // From Openzeppelin's implementation - MIT licence
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/Strings.sol#L15-L35

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @notice NFT URI
     * @param vaultID ID of Vault
     */
    function tokenURI(uint256 vaultID) public view virtual override returns (string memory) {
        require(_ownerOf[vaultID] != address(0), "ERC721Metadata: URI query for nonexistent token");
        return bytes(baseURI).length > 0 ? string(abi.encodePacked(baseURI, toString(vaultID))) : "";
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
            collateral.safeTransfer(_ownerOf[vaultID], vaultCollateral[vaultID]);
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
        collateral.safeTransfer(msg.sender, amount);

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
        goodToken.safeTransfer(msg.sender, amount);

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
        goodToken.safeTransferFrom(msg.sender, address(this), amount);

        vaultDebt[vaultID] = vaultDebt[vaultID] - amount;
        vaultCollateral[vaultID] = vaultCollateral[vaultID] - _closingFee;
        vaultCollateral[treasury] = vaultCollateral[treasury] + _closingFee;

        emit PayBackToken(vaultID, amount, _closingFee);
    }

    /**
     * @notice Get collateral percentage
     * @param vaultID Vault ID
     */
    function checkCollateralPercentage(uint256 vaultID) public view returns (uint256) {
        require(_ownerOf[vaultID] != address(0), "Vault does not exist");

        if (vaultCollateral[vaultID] == 0 || vaultDebt[vaultID] == 0) {
            return 0;
        }
        (uint256 collateralValueTimes100, uint256 debtValue) = calculateCollateralProperties(
            vaultCollateral[vaultID],
            vaultDebt[vaultID]
        );

        collateralValueTimes100 = collateralValueTimes100 * (10**10);

        return collateralValueTimes100 / debtValue;
    }

    /**
     * @notice check vault liquidation
     * @param vaultID Vault ID
     * @return true if vault can be liquidated
     */
    function checkLiquidation(uint256 vaultID) public view returns (bool) {
        require(_ownerOf[vaultID] != address(0), "Vault does not exist");

        if (vaultCollateral[vaultID] == 0 || vaultDebt[vaultID] == 0) {
            return false;
        }

        (uint256 collateralValueTimes100, uint256 debtValue) = calculateCollateralProperties(
            vaultCollateral[vaultID],
            vaultDebt[vaultID]
        );

        collateralValueTimes100 = collateralValueTimes100 * (10**10);

        uint256 collateralPercentage = collateralValueTimes100 / debtValue;

        if (collateralPercentage < minimumCollateralPercentage) {
            return true;
        } else {
            return false;
        }
    }

    /**
     * @notice check cost
     * @param vaultID Vault ID
     * @return half debt
     */
    function checkCost(uint256 vaultID) public view returns (uint256) {
        if (vaultCollateral[vaultID] == 0 || vaultDebt[vaultID] == 0 || !checkLiquidation(vaultID)) {
            return 0;
        }

        // collateralValueTimes100, debtValue
        (, uint256 debtValue) = calculateCollateralProperties(vaultCollateral[vaultID], vaultDebt[vaultID]);

        if (debtValue == 0) {
            return 0;
        }

        // uint256 collateralPercentage = collateralValueTimes100 / debtValue;

        debtValue = debtValue / (10**8);
        uint256 halfDebt = debtValue / debtRatio;

        return (halfDebt);
    }

    /**
     * @notice check extract for rewards e.g. matic
     * @param vaultID Vault ID
     * @return extractable
     */
    function checkExtract(uint256 vaultID) public view returns (uint256) {
        if (vaultCollateral[vaultID] == 0 || !checkLiquidation(vaultID)) {
            return 0;
        }

        // collateralValueTimes100, debtValue
        (, uint256 debtValue) = calculateCollateralProperties(
            vaultCollateral[vaultID],
            vaultDebt[vaultID]
        );

        uint256 halfDebt = debtValue / debtRatio;

        if (halfDebt == 0) {
            return 0;
        }
        return (halfDebt * gainRatio) / 1000 / getEthPriceSource() / 10000000000;
    }

    /**
     * @notice liquidate vault
     * @param vaultID Vault ID
     */
    function liquidateVault(uint256 vaultID) external {
        require(_ownerOf[vaultID] != address(0), "Vault does not exist");
        require(stabilityPool==address(0) || msg.sender ==  stabilityPool, "liquidation is disabled for public");

        (uint256 collateralValueTimes100, uint256 debtValue) = calculateCollateralProperties(vaultCollateral[vaultID], vaultDebt[vaultID]);
        
        collateralValueTimes100 = collateralValueTimes100 * (10 ** 10);

        uint256 collateralPercentage = collateralValueTimes100 / debtValue;

        require(collateralPercentage < minimumCollateralPercentage, "Vault is not below minimum collateral percentage");

        debtValue = debtValue / (10 ** 8);

        uint256 halfDebt = debtValue / debtRatio; 

        require(goodToken.balanceOf(msg.sender) >= halfDebt, "Token balance too low to pay off outstanding debt");

        goodToken.safeTransferFrom(msg.sender, address(this), halfDebt);

        // uint256 maticExtract = checkExtract(vaultID);

        vaultDebt[vaultID] = vaultDebt[vaultID] - halfDebt; // we paid back half of its debt.

        uint256 _closingFee = (halfDebt * closingFee * getTokenPriceSource()) / (getEthPriceSource() * 10000) / 1000000000;

        vaultCollateral[vaultID]=vaultCollateral[vaultID] - _closingFee;
        vaultCollateral[treasury]=vaultCollateral[treasury] + _closingFee;

        // deduct the amount from the vault's collateral
        // vaultCollateral[vaultID] = vaultCollateral[vaultID].sub(maticExtract);
        vaultCollateral[vaultID] = vaultCollateral[vaultID] - 0;

        // let liquidator take the collateral
        // maticDebt[msg.sender] = maticDebt[msg.sender] + maticExtract;

        // emit LiquidateVault(vaultID, ownerOf(vaultID), msg.sender, halfDebt, maticExtract, _closingFee);
        emit LiquidateVault(vaultID, ownerOf(vaultID), msg.sender, halfDebt, 0, _closingFee);
    }
}
