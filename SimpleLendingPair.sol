pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint);
    function balanceOf(address) external view returns (uint);
    function allowance(address, address) external view returns (uint);
    function approve(address, uint) external returns (bool);
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
}

interface IPriceOracle {
    function getPriceE8(address token) external view returns (uint256);
}

interface IRateModel {
    function borrowRatePerSecond(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256);
}

library SafeTransfer {
    function safeTransfer(IERC20 t, address to, uint256 v) internal {
        require(t.transfer(to, v), "TRANSFER_FAILED");
    }
    function safeTransferFrom(IERC20 t, address from, address to, uint256 v) internal {
        require(t.transferFrom(from, to, v), "TRANSFER_FROM_FAILED");
    }
}

contract ReentrancyGuard {
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }
}

// Minimal receipt token minted/burned by the pair
contract ZToken {
    string public name;
    string public symbol;
    uint8  public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable owner;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed from, address indexed spender, uint256 value);

    constructor(string memory _n, string memory _s, uint8 _d) {
        owner = msg.sender; // the Pair
        name = _n; symbol = _s; decimals = _d;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _transfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (msg.sender != f && a != type(uint256).max) {
            require(a >= v, "ALLOW");
            allowance[f][msg.sender] = a - v;
        }
        _transfer(f, to, v);
        return true;
    }

    function _transfer(address f, address to, uint256 v) internal {
        require(balanceOf[f] >= v, "BAL");
        balanceOf[f] -= v;
        balanceOf[to] += v;
        emit Transfer(f, to, v);
    }

    function mint(address to, uint256 v) external onlyOwner {
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function burnFrom(address from, uint256 v) external onlyOwner {
        require(balanceOf[from] >= v, "BURN");
        balanceOf[from] -= v;
        totalSupply -= v;
        emit Transfer(from, address(0), v);
    }
}

contract SimpleLendingPair is ReentrancyGuard {
    using SafeTransfer for IERC20;

    // Admin/params
    address public admin;

    IERC20 public immutable collateralToken; // e.g., WZTC
    IERC20 public immutable debtToken;       // e.g., ZUSDC or WZTC
    uint8   public immutable collateralDecimals;
    uint8   public immutable debtDecimals;

    IPriceOracle public oracle;  // returns price in 1e8
    IRateModel   public rateModel;

    uint256 public ltv;                  // 1e18
    uint256 public liquidationThreshold; // 1e18
    uint256 public liquidationBonus;     // 1e18 (e.g., 1.07e18)
    uint256 public closeFactor;          // 1e18
    uint256 public reserveFactor;        // 1e18

    // Accounting
    uint256 public totalBorrows;     // debt token units
    uint256 public totalReserves;    // debt token units
    uint256 public borrowIndex = 1e18;
    uint256 public accrualTimestamp;

    mapping(address => uint256) public collateralBalance; // in collateral units
    mapping(address => uint256) public borrowPrincipal;   // scaled by index
    mapping(address => uint256) public borrowerIndex;     // snapshot

    ZToken public zToken; // receipt for suppliers of debtToken

    // Events
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Supply(address indexed user, uint256 amount, uint256 zMinted);
    event Redeem(address indexed user, uint256 zBurned, uint256 amountUnderlying);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repayAmount, uint256 seizeAmount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NOT_ADMIN");
        _;
    }

    constructor(
        address _admin,
        address _collateralToken,
        uint8   _collateralDecimals,
        address _debtToken,
        uint8   _debtDecimals,
        address _oracle,
        address _rateModel,
        uint256 _ltv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _closeFactor,
        uint256 _reserveFactor,
        string memory _zName,
        string memory _zSymbol
    ) {
        admin = _admin;
        collateralToken = IERC20(_collateralToken);
        debtToken = IERC20(_debtToken);
        collateralDecimals = _collateralDecimals;
        debtDecimals = _debtDecimals;
        oracle = IPriceOracle(_oracle);
        rateModel = IRateModel(_rateModel);
        ltv = _ltv;
        liquidationThreshold = _liquidationThreshold;
        liquidationBonus = _liquidationBonus;
        closeFactor = _closeFactor;
        reserveFactor = _reserveFactor;

        zToken = new ZToken(_zName, _zSymbol, _debtDecimals);
        accrualTimestamp = block.timestamp;
    }

    // ------------ Views ------------

    function cash() public view returns (uint256) {
        return debtToken.balanceOf(address(this));
    }

    function exchangeRate() public view returns (uint256) {
        uint256 zSupply = zToken.totalSupply();
        if (zSupply == 0) return 1e18;
        uint256 c = cash();
        return ((c + totalBorrows - totalReserves) * 1e18) / zSupply;
    }

    function _toUSD(address token, uint8 dec, uint256 amount) internal view returns (uint256) {
        uint256 p = oracle.getPriceE8(token); // 1e8
        // return 1e18 value: amount * price(1e8) * 1e10 / 10^dec
        return amount * p * (10 ** 10) / (10 ** dec);
    }

    function borrowBalanceOf(address user) public view returns (uint256) {
        uint256 p = borrowPrincipal[user];
        if (p == 0) return 0;
        return (p * borrowIndex) / borrowerIndex[user];
    }

    function healthFactorOf(address user) public view returns (uint256) {
        uint256 debt = borrowBalanceOf(user);
        if (debt == 0) return type(uint256).max;

        uint256 colUSD = _toUSD(address(collateralToken), collateralDecimals, collateralBalance[user]);
        uint256 debtUSD = _toUSD(address(debtToken), debtDecimals, debt);
        return (colUSD * liquidationThreshold) / debtUSD; // 1e18
    }

    // ------------ Admin ------------

    function setOracle(address _oracle) external onlyAdmin { oracle = IPriceOracle(_oracle); }
    function setRateModel(address _rm) external onlyAdmin { rateModel = IRateModel(_rm); }
    function setParams(
        uint256 _ltv,
        uint256 _liquidationThreshold,
        uint256 _liquidationBonus,
        uint256 _closeFactor,
        uint256 _reserveFactor
    ) external onlyAdmin {
        ltv = _ltv;
        liquidationThreshold = _liquidationThreshold;
        liquidationBonus = _liquidationBonus;
        closeFactor = _closeFactor;
        reserveFactor = _reserveFactor;
    }

    // ------------ Core: interest accrual ------------

    function accrueInterest() public {
        if (block.timestamp == accrualTimestamp) return;

        uint256 dt = block.timestamp - accrualTimestamp;
        accrualTimestamp = block.timestamp;

        if (totalBorrows == 0) return;

        uint256 ratePerSec = rateModel.borrowRatePerSecond(cash(), totalBorrows, totalReserves); // 1e18
        uint256 interest = (totalBorrows * ratePerSec * dt) / 1e18;

        totalBorrows += interest;
        uint256 addToReserves = (interest * reserveFactor) / 1e18;
        totalReserves += addToReserves;

        // Update index (approx: borrowIndex *= (1 + ratePerSec*dt))
        borrowIndex = borrowIndex + (borrowIndex * ratePerSec * dt) / 1e18;
    }

    // ------------ User actions ------------

    function depositCollateral(uint256 amount) external nonReentrant {
        accrueInterest();
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        accrueInterest();
        require(collateralBalance[msg.sender] >= amount, "collateral");
        collateralBalance[msg.sender] -= amount;
        require(healthFactorOf(msg.sender) >= 1e18, "HF < 1");
        collateralToken.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    // Supply debt token to earn interest (mints zTokens)
    function supply(uint256 amount) external nonReentrant {
        accrueInterest();
        uint256 rate = exchangeRate(); // 1e18
        uint256 zMint = (amount * 1e18) / rate;
        debtToken.safeTransferFrom(msg.sender, address(this), amount);
        zToken.mint(msg.sender, zMint);
        emit Supply(msg.sender, amount, zMint);
    }

    // Withdraw by burning zTokens
    function redeem(uint256 zAmount) external nonReentrant {
        accrueInterest();
        uint256 rate = exchangeRate();
        uint256 underlying = (zAmount * rate) / 1e18;
        require(cash() >= underlying, "cash");
        zToken.burnFrom(msg.sender, zAmount);
        debtToken.safeTransfer(msg.sender, underlying);
        emit Redeem(msg.sender, zAmount, underlying);
    }

    // Withdraw an exact amount of underlying
    function redeemUnderlying(uint256 amount) external nonReentrant {
        accrueInterest();
        uint256 rate = exchangeRate();
        uint256 zBurn = (amount * 1e18 + rate - 1) / rate; // ceil
        require(cash() >= amount, "cash");
        zToken.burnFrom(msg.sender, zBurn);
        debtToken.safeTransfer(msg.sender, amount);
        emit Redeem(msg.sender, zBurn, amount);
    }

    function borrow(uint256 amount) external nonReentrant {
        accrueInterest();
        require(cash() >= amount, "insufficient liquidity");

        // Update borrower balance
        uint256 owed = borrowBalanceOf(msg.sender);
        uint256 newOwed = owed + amount;
        borrowPrincipal[msg.sender] = (newOwed * 1e18) / borrowIndex;
        borrowerIndex[msg.sender] = borrowIndex;

        // Check LTV after borrow
        uint256 colUSD = _toUSD(address(collateralToken), collateralDecimals, collateralBalance[msg.sender]);
        uint256 debtUSD = _toUSD(address(debtToken), debtDecimals, newOwed);
        require(debtUSD <= (colUSD * ltv) / 1e18, "exceeds LTV");

        debtToken.safeTransfer(msg.sender, amount);
        totalBorrows += amount;
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        accrueInterest();

        uint256 owed = borrowBalanceOf(msg.sender);
        require(owed > 0, "no debt");

        uint256 pay = amount > owed ? owed : amount;
        debtToken.safeTransferFrom(msg.sender, address(this), pay);

        uint256 newOwed = owed - pay;
        if (newOwed == 0) {
            borrowPrincipal[msg.sender] = 0;
            borrowerIndex[msg.sender] = 1e18;
        } else {
            borrowPrincipal[msg.sender] = (newOwed * 1e18) / borrowIndex;
            borrowerIndex[msg.sender] = borrowIndex;
        }

        totalBorrows -= pay;
        emit Repay(msg.sender, pay);
    }

    // Liquidate up to closeFactor of borrow; seize collateral with bonus
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        accrueInterest();
        require(healthFactorOf(borrower) < 1e18, "healthy");

        uint256 owed = borrowBalanceOf(borrower);
        uint256 maxRepay = (owed * closeFactor) / 1e18;
        uint256 toRepay = repayAmount > maxRepay ? maxRepay : repayAmount;

        // Transfer repay
        debtToken.safeTransferFrom(msg.sender, address(this), toRepay);

        // Update borrower debt
        uint256 newOwed = owed - toRepay;
        if (newOwed == 0) {
            borrowPrincipal[borrower] = 0;
            borrowerIndex[borrower] = 1e18;
        } else {
            borrowPrincipal[borrower] = (newOwed * 1e18) / borrowIndex;
            borrowerIndex[borrower] = borrowIndex;
        }
        totalBorrows -= toRepay;

        // Seize collateral = repayValueUSD * bonus / collateralPrice
        uint256 priceDebt = oracle.getPriceE8(address(debtToken));       // 1e8
        uint256 priceColl = oracle.getPriceE8(address(collateralToken)); // 1e8

        // seize = toRepay * priceDebt / priceColl * (10^collDec / 10^debtDec) * bonus
        uint256 seize = (toRepay * priceDebt * (10 ** collateralDecimals)) / (priceColl * (10 ** debtDecimals));
        seize = (seize * liquidationBonus) / 1e18;

        require(collateralBalance[borrower] >= seize, "collateral");

        collateralBalance[borrower] -= seize;
        collateralToken.safeTransfer(msg.sender, seize);

        emit Liquidate(msg.sender, borrower, toRepay, seize);
    }
}