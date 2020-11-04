pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

interface IUniswapOracle {
    function update() external;
    function consult(address token, uint amountIn) external view returns (uint amountOut);
}

interface IFedShare {
    function burn(address from, uint256 amount) external;
    function mint(address to, uint256 amount) external;
}

contract FedCash is ERC20UpgradeSafe, OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe {
    using SafeMath for uint256;

    uint256 constant public MAX_RESERVE_RATIO = 100 * 10 ** 9;
    uint256 private constant DECIMALS = 9;
    uint256 public lastRefreshReserve;
    uint256 public minimumRefreshTime;

    address public share;            
    uint256 public shareDecimals;

    AggregatorV3Interface internal ethPrice;

    address public fedCashOracle;
    address public fedShareOracle;

    uint256 private constant MAX_SUPPLY = ~uint128(0);
    uint256 public minimumReserveRate;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    uint256 private _totalSupply;
    mapping(address => uint256) private _cashBalances;
    mapping (address => mapping (address => uint256)) private _allowedFedCash;

    address public wethAddress;
    address public gov;
    address public pendingGov;
    uint256 public reserveRatio;

    mapping (address => bool) public acceptedCollateral;
    address[] collateralArray;

    modifier sync() {
        updateOracles();

        if (block.timestamp - lastRefreshReserve >= minimumRefreshTime) {
            IUniswapOracle(fedShareOracle).update();
            IUniswapOracle(fedCashOracle).update();
            if (getFedCashOracle() > 1 * 10 ** 9) {
                setReserveRatio(reserveRatio.sub(5 * 10 ** 8));
            } else {
                setReserveRatio(reserveRatio.add(5 * 10 ** 8));
            }

            lastRefreshReserve = block.timestamp;
        }
        
        _;
    }

    event NewPendingGov(address oldPendingGov, address newPendingGov);
    event NewGov(address oldGov, address newGov);
    event NewReserveRate(uint256 reserveRatio);
    event Mint(address share, address receiver, address collateral, uint256 collateralAmount, uint256 shareAmount, uint256 fedCashAmount);
    event Withdraw(address share, address receiver, address collateral, uint256 collateralAmount, uint256 shareAmount, uint256 fedCashAmount);
    event NewMinimumRefreshTime(uint256 minimumRefreshTime);

    modifier onlyGov() {
        require(msg.sender == gov, "ACCESS: only FedCash governance");
        _;
    }

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    mapping (address => uint256) public collateralDecimals;

    // default to 0
    uint256 public mintFee;
    uint256 public withdrawFee;

    event MintFee(uint256 fee_);
    event WithdrawFee(uint256 fee_);

    // fed share sale
    bool public saleOngoing;

    event LogPurchase(address buyer, uint256 amountIn, uint256 amountOut);

    mapping(address => uint256) _purchaseHistory; // user => fedShare history
    address payable public treasury;

    mapping(address => uint256) _lastAction;    // records user deposit / withdrawal
    uint256 public minimumDelay;                // how long a user must wait between actions

    mapping (address => address) public collateralOracle;

    // minimum delay in seconds
    function setDelay(uint256 val_)
        external
        onlyGov
    {
        minimumDelay = val_;
    }

    // function used to add
    function addCollateral(address collateral_, uint256 collateralDecimal_, address oracleAddress_)
        external
        onlyGov
    {
        collateralArray.push(collateral_);
        acceptedCollateral[collateral_] = true;
        collateralDecimals[collateral_] = collateralDecimal_;
        collateralOracle[collateral_] = oracleAddress_;
    }

    function removeCollateral(address collateral_)
        external
        onlyGov
    {
        delete acceptedCollateral[collateral_];
        delete collateralOracle[collateral_];

        for (uint i = 0; i < collateralArray.length; i++){ 
            if (collateralArray[i] == collateral_) {
                collateralArray[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }
    }

    function getCollateralByIndex(uint256 index_) external view returns (address) {
        return collateralArray[index_];
    }

    function updateOracles() public {
        for (uint i = 0; i < collateralArray.length; i++) {
            if (acceptedCollateral[collateralArray[i]]) IUniswapOracle(collateralOracle[collateralArray[i]]).update();
        } 
    }

    function getCollateralUsd(address collateral_) public view returns (uint256) {
        // price is $Y / ETH (10 ** 8 decimals)
        ( , int price, , uint timeStamp, ) = ethPrice.latestRoundData();
        require(timeStamp > 0, "Rounds not complete");

        return uint256(price).mul(10 ** 10).div((IUniswapOracle(collateralOracle[collateral_]).consult(wethAddress, 10 ** 18)).mul(10 ** 9).div(10 ** collateralDecimals[collateral_]));
    }

    function globalCollateralValue() public view returns (uint256) {
        uint256 totalCollateralUsd = 0; 

        for (uint i = 0; i < collateralArray.length; i++){ 
            // Exclude null addresses
            if (collateralArray[i] != address(0)){
                totalCollateralUsd += IERC20(collateralArray[i]).balanceOf(address(this)).mul(10 ** 9).div(10 ** collateralDecimals[collateralArray[i]]).mul(getCollateralUsd(collateralArray[i])).div(10 ** 9); // add stablecoin balance
            }

        }
        return totalCollateralUsd;
    }

    function totalSupply()
        public
        override
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(address who)
        public
        override
        view
        returns (uint256)
    {
        return _cashBalances[who];
    }

    function transfer(address to, uint256 value)
        public
        override
        validRecipient(to)
        sync()
        returns (bool)
    {
        _cashBalances[msg.sender] = _cashBalances[msg.sender].sub(value);
        _cashBalances[to] = _cashBalances[to].add(value);
        emit Transfer(msg.sender, to, value);

        return true;
    }

    function allowance(address owner_, address spender)
        public
        override
        view
        returns (uint256)
    {
        return _allowedFedCash[owner_][spender];
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        validRecipient(to)
        sync()
        returns (bool)
    {
        _allowedFedCash[from][msg.sender] = _allowedFedCash[from][msg.sender].sub(value);

        _cashBalances[from] = _cashBalances[from].sub(value);
        _cashBalances[to] = _cashBalances[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value)
        public
        override
        sync()
        returns (bool)
    {
        _allowedFedCash[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _allowedFedCash[msg.sender][spender] = _allowedFedCash[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedFedCash[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 oldValue = _allowedFedCash[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedFedCash[msg.sender][spender] = 0;
        } else {
            _allowedFedCash[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedFedCash[msg.sender][spender]);
        return true;
    }

    function setFedCashOracle(address oracle_)
        external
        onlyGov
        returns (bool) 
    {
        fedCashOracle = oracle_;
        
        return true;
    }

    function setFedShareOracle(address oracle_)
        external
        onlyGov
        returns (bool)
    {
        fedShareOracle = oracle_;

        return true;
    }

    function getFedShareOracle()
        public
        view
        returns (uint256)
    {
        uint256 fedShareTWAP = IUniswapOracle(fedShareOracle).consult(wethAddress, 1 * 10 ** 18);

        ( , int price, , uint timeStamp, ) = ethPrice.latestRoundData();

        require(timeStamp > 0, "Rounds not complete");

        return uint256(price).mul(10 ** DECIMALS).div(fedShareTWAP);
    }

    function getFedCashOracle()
        public
        view
        returns (uint256)
    {
        uint256 fedCashTWAP = IUniswapOracle(fedCashOracle).consult(wethAddress, 1 * 10 ** 18);

        ( , int price, , uint timeStamp, ) = ethPrice.latestRoundData();

        require(timeStamp > 0, "Rounds not complete");

        return uint256(price).mul(10 ** DECIMALS).div(fedCashTWAP);
    }

    function setMinimumRefreshTime(uint256 val_)
        external
        onlyGov
        returns (bool)
    {
        require(val_ != 0, "minimum refresh time must be valid");

        minimumRefreshTime = val_;

        emit NewMinimumRefreshTime(val_);
        return true;
    }

    function initialize(
        address share_,
        uint256 shareDecimals_,
        address wethAddress_,
        address ethOracleChainLink_
    )
        public
        initializer
    {
        OwnableUpgradeSafe.__Ownable_init();
        ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();

        ERC20UpgradeSafe.__ERC20_init('fedCash', 'fedCash');
        ERC20UpgradeSafe._setupDecimals(9);

        share = share_;
        minimumRefreshTime = 3600 * 8; // 8 hours by default
        shareDecimals = shareDecimals_;
        ethPrice = AggregatorV3Interface(ethOracleChainLink_);
        minimumReserveRate = 50 * 10 ** 9;
        wethAddress = wethAddress_;
        gov = msg.sender;
        reserveRatio = 100 * 10 ** 9;   // 100% reserve at first
        _totalSupply = 0;
    }

    function setPendingGov(address pendingGov_)
        external
        onlyGov
    {
        address oldPendingGov = pendingGov;
        pendingGov = pendingGov_;
        emit NewPendingGov(oldPendingGov, pendingGov_);
    }

    function acceptGov()
        external
    {
        require(msg.sender == pendingGov, "!pending");
        address oldGov = gov;
        gov = pendingGov;
        pendingGov = address(0);
        emit NewGov(oldGov, gov);
    }

    function consultFedCashRatio(uint256 fedCashAmount, address collateral)
        public
        view
        returns (uint256, uint256)
    {
        require(fedCashAmount != 0, "must use valid fedCashAmount");
        require(acceptedCollateral[collateral], "must be an accepted collateral");

        uint256 collateralAmount = fedCashAmount.mul(reserveRatio).div(MAX_RESERVE_RATIO).mul(10 ** collateralDecimals[collateral]).div(10 ** DECIMALS);
        collateralAmount = collateralAmount.mul(10 ** 9).div(getCollateralUsd(collateral)); // get real time price

        if (_totalSupply == 0) {
            return (collateralAmount, 0);
        } else {
            uint256 fedShareUsd = getFedShareOracle();                         
            uint256 fedCashPrice = getFedCashOracle();                      

            uint256 fedCashPart2 = fedCashAmount.mul(MAX_RESERVE_RATIO.sub(reserveRatio)).div(MAX_RESERVE_RATIO);
            uint256 shareAmount = fedCashPart2.mul(fedCashPrice).div(fedShareUsd);

            return (collateralAmount, shareAmount);
        }
    }

    function mint(
        uint256 fedCashAmount,
        address collateral
    )
        public
        nonReentrant
        sync()
    {
        require(acceptedCollateral[collateral], "must be an accepted collateral");
        require(now.sub(_lastAction[msg.sender]) > minimumDelay, "must wait a little before new action");

        (uint256 collateralAmount, uint256 shareAmount) = consultFedCashRatio(fedCashAmount, collateral);
        require(collateralAmount <= IERC20(collateral).balanceOf(msg.sender), "sender has insufficient collateral balance");
        require(shareAmount <= IERC20(share).balanceOf(msg.sender), "sender has insufficient share balance");

        SafeERC20.safeTransferFrom(IERC20(collateral), msg.sender, address(this), collateralAmount);

        if (shareAmount != 0) IFedShare(share).burn(msg.sender, shareAmount);

        fedCashAmount = fedCashAmount.sub(fedCashAmount.mul(mintFee).div(100 * 10 ** DECIMALS));

        _totalSupply = _totalSupply.add(fedCashAmount);
        _cashBalances[msg.sender] = _cashBalances[msg.sender].add(fedCashAmount);

        _lastAction[msg.sender] = now;

        emit Transfer(address(0x0), msg.sender, fedCashAmount);
        emit Mint(share, msg.sender, collateral, collateralAmount, shareAmount, fedCashAmount);
    }

    function editMintFee(uint256 fee_)
        external
        onlyGov
    {
        mintFee = fee_;
        emit MintFee(fee_);
    }

    function editWithdrawFee(uint256 fee_)
        external
        onlyGov
    {
        withdrawFee = fee_;
        emit WithdrawFee(fee_);
    }

    function withdraw(
        uint256 fedCashAmount,
        address collateral
    )
        public
        nonReentrant
        sync()
    {
        require(fedCashAmount <= _cashBalances[msg.sender], "insufficient balance");
        require(now.sub(_lastAction[msg.sender]) > minimumDelay, "must wait a little before new action");

        _totalSupply = _totalSupply.sub(fedCashAmount);
        _cashBalances[msg.sender] = _cashBalances[msg.sender].sub(fedCashAmount);

        (uint256 collateralAmount, uint256 shareAmount) = consultFedCashRatio(fedCashAmount, collateral);

        collateralAmount = collateralAmount.sub(collateralAmount.mul(withdrawFee).div(100 * 10 ** DECIMALS));
        shareAmount = shareAmount.sub(shareAmount.mul(withdrawFee).div(100 * 10 ** DECIMALS));

        require(collateralAmount <= IERC20(collateral).balanceOf(address(this)), "insufficient collateral reserves - try another collateral");

        SafeERC20.safeTransfer(IERC20(collateral), msg.sender, collateralAmount);
        if (shareAmount != 0) IFedShare(share).mint(msg.sender, shareAmount);

        _lastAction[msg.sender] = now;

        emit Transfer(msg.sender, address(0x0), fedCashAmount);
        emit Withdraw(share, msg.sender, collateral, collateralAmount, shareAmount, fedCashAmount);
    }


    function setTreasury(address payable treasury_) external onlyGov {
        treasury = treasury_;
    } 

    function getPurchaseHistory(address who_) public view returns (uint256) {
        return _purchaseHistory[who_];
    }

    function purchaseFedShare() nonReentrant public payable returns (bool) {
        require(saleOngoing, "Sale must be ongoing");
        require(msg.value > 0, "Must send Eth");
        uint256 currentBalance = IERC20(share).balanceOf(address(this));

        uint256 inputEth = msg.value;

        ( , int price, , uint timeStamp, ) = ethPrice.latestRoundData();
        require(timeStamp > 0, "Rounds not complete");

        uint256 outputUSD = (inputEth.mul(uint256(price))).div(10 ** 17); 
        uint256 shareAmountToBuy = outputUSD.mul(100); 

        require(shareAmountToBuy <= currentBalance, "Insufficient FedShare funds"); 
 
        _purchaseHistory[msg.sender] = _purchaseHistory[msg.sender].add(shareAmountToBuy);
        
        treasury.transfer(msg.value);
        
        SafeERC20.safeTransfer(IERC20(share), msg.sender, shareAmountToBuy);

        emit LogPurchase(msg.sender, inputEth, shareAmountToBuy);
        return true;
    }

    function startSale() 
        external
        onlyGov
    {
        require(!saleOngoing, "Sale must not be ongoing");
        saleOngoing = true;
    }

    function withdrawPrincipal()
        external
        onlyGov
    {
        require(!saleOngoing, "Sale must not be ongoing");
        uint256 currentBalance = IERC20(share).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(share), msg.sender, currentBalance);
    }

    function endSale()
        external
        onlyGov
    {
        require(saleOngoing, "Sale must be ongoing to end");
        saleOngoing = false;
    }

    function setReserveRatioAdmin(uint256 newRatio_)
        external
        onlyGov
    {
        require(newRatio_ >= 0, "positive reserve ratio");

        if (newRatio_ <= MAX_RESERVE_RATIO) {
            reserveRatio = newRatio_;
            emit NewReserveRate(reserveRatio);
        }
    }

    function setReserveRatio(uint256 newRatio_)
        private
    {
        require(newRatio_ >= 0, "positive reserve ratio");

        if (newRatio_ <= MAX_RESERVE_RATIO) {
            reserveRatio = newRatio_;
            emit NewReserveRate(reserveRatio);
        }
    }

}
