pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract FedShare is ERC20UpgradeSafe, OwnableUpgradeSafe {
    using SafeMath for uint256;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        require(to != address(this));
        _;
    }

    modifier onlyMinter() {
        require(msg.sender == _minter);
        _;
    }

    uint256 private constant DECIMALS = 9;
    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_SHARE_SUPPLY = 1000 * 10 ** 6 * 10 ** DECIMALS;

    uint256 private constant MAX_SUPPLY = ~uint128(0);

    uint256 private _totalSupply;
    address public _minter;

    mapping(address => uint256) private _shareBalances;
    mapping (address => mapping (address => uint256)) private _allowedSHARE;

    function initialize(address minter)
        public
        initializer
    {
        OwnableUpgradeSafe.__Ownable_init();

        ERC20UpgradeSafe.__ERC20_init("FedShare", "FedShare");
        ERC20UpgradeSafe._setupDecimals(uint8(DECIMALS));

        _totalSupply = INITIAL_SHARE_SUPPLY;
        _shareBalances[msg.sender] = _totalSupply;
        _minter = minter;

        emit Transfer(address(0x0), msg.sender, _totalSupply);
    }

    function burn(address from, uint256 amount)
        external
        onlyMinter
    {
        require(_shareBalances[from] >= amount, "insufficient FedShare balance to burn");

        _totalSupply = _totalSupply.sub(amount);
        _shareBalances[from] = _shareBalances[from].sub(amount);
        emit Transfer(from, address(0x0), amount);
    }

    function mint(address to, uint256 amount)
        external
        onlyMinter
    {
        _totalSupply = _totalSupply.add(amount);
        _shareBalances[to] = _shareBalances[to].sub(amount);

        emit Transfer(address(0x0), to, amount);
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
        return _shareBalances[who];
    }

    function transfer(address to, uint256 value)
        public
        override
        validRecipient(to)
        returns (bool)
    {
        _shareBalances[msg.sender] = _shareBalances[msg.sender].sub(value);
        _shareBalances[to] = _shareBalances[to].add(value);
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function allowance(address owner_, address spender)
        public
        override
        view
        returns (uint256)
    {
        return _allowedSHARE[owner_][spender];
    }

    function transferFrom(address from, address to, uint256 value)
        public
        override
        validRecipient(to)
        returns (bool)
    {
        _allowedSHARE[from][msg.sender] = _allowedSHARE[from][msg.sender].sub(value);

        _shareBalances[from] = _shareBalances[from].sub(value);
        _shareBalances[to] = _shareBalances[to].add(value);
        emit Transfer(from, to, value);

        return true;
    }

    function approve(address spender, uint256 value)
        public
        override
        validRecipient(spender)
        returns (bool)
    {
        _allowedSHARE[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        override
        returns (bool)
    {
        _allowedSHARE[msg.sender][spender] =
            _allowedSHARE[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedSHARE[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        override
        returns (bool)
    {
        uint256 oldValue = _allowedSHARE[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedSHARE[msg.sender][spender] = 0;
        } else {
            _allowedSHARE[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedSHARE[msg.sender][spender]);
        return true;
    }

}
