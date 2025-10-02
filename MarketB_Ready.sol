// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  Market B (ZenChain testnet)
  - Collateral: ZUSDC (0xF8aD5140d8B21D68366755DeF1fEFA2e2665060C) 6d
  - Debt/Supply: WZTC  (0x66D9541D1220488F5d569a8a43e80298Df145f4E) 18d
  - Oracle:      0x1b7e2509a34273d74c7F1767740E7dc2F63dcaAc
  - Admin:       0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F

  Functions:
    - supply/withdrawUnderlying (WZTC)
    - depositCollateral/withdrawCollateral (ZUSDC)
    - borrow/repay (WZTC)
    - liquidate

  Testnet only. Not audited.
*/

interface IERC20B {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPriceOracleB {
    function getPriceE8(address token) external view returns (uint256);
}

contract MarketB_ZenFinal {
    // Addresses (checksummed)
    address public constant ADMIN  = 0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F;
    address public constant ZUSDC  = 0xF8aD5140d8B21D68366755DeF1fEFA2e2665060C; // 6 decimals
    address public constant WZTC   = 0x66D9541D1220488F5d569a8a43e80298Df145f4E; // 18 decimals
    address public constant ORACLE = 0x1b7e2509a34273d74c7F1767740E7dc2F63dcaAc;

    // Decimals for math
    uint8  public constant COL_DEC = 6;  // ZUSDC
    uint8  public constant DEBT_DEC = 18; // WZTC

    // Risk params (1e18)
    uint256 public constant LTV   = 80e16;   // 80%
    uint256 public constant LT    = 88e16;   // 88%
    uint256 public constant BONUS = 106e16;  // 1.06
    uint256 public constant CLOSE = 50e16;   // 50%
    uint256 public constant RES   = 10e16;   // 10%

    // Interest model
    uint256 public constant BASE   =  5e16;   // 0.5%
    uint256 public constant SLOPE1 = 70e16;   // 7%
    uint256 public constant SLOPE2 = 450e16;  // 45%
    uint256 public constant KINK   =  80e16;  // 80%
    uint256 public constant YEAR   = 365 days;

    // Tokens and oracle
    IERC20B public immutable collateralToken; // ZUSDC
    IERC20B public immutable debtToken;       // WZTC
    IPriceOracleB public immutable oracle;

    // Reentrancy guard
    uint256 private locked = 1;
    modifier nonReentrant() { require(locked == 1, "REENTRANCY"); locked = 2; _; locked = 1; }

    // Accounting for pool (debt side)
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public borrowIndex = 1e18;
    uint256 public accrualTimestamp;

    // Suppliers (share model)
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    // Borrowers/collateral
    mapping(address => uint256) public collateralBalance; // ZUSDC units
    mapping(address => uint256) public borrowPrincipal;   // scaled by index
    mapping(address => uint256) public borrowerIndex;

    // Events
    event Supply(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdraw(address indexed user, uint256 amount, uint256 sharesBurned);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed borrower, uint256 repayAmount, uint256 seizeAmount);

    constructor() {
        collateralToken = IERC20B(ZUSDC);
        debtToken = IERC20B(WZTC);
        oracle = IPriceOracleB(ORACLE);
        accrualTimestamp = block.timestamp;
    }

    // -------- Views --------
    function cash() public view returns (uint256) { return debtToken.balanceOf(address(this)); }

    function totalUnderlying() public view returns (uint256) {
        return cash() + totalBorrows - totalReserves;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalUnderlying() * 1e18) / totalShares;
    }

    function _toUSD(address token, uint8 dec, uint256 amt) internal view returns (uint256) {
        uint256 p = oracle.getPriceE8(token); // 1e8
        return amt * p * 1e10 / (10 ** dec);
    }

    function borrowBalanceOf(address u) public view returns (uint256) {
        uint256 p = borrowPrincipal[u];
        if (p == 0) return 0;
        return (p * borrowIndex) / (borrowerIndex[u] == 0 ? 1e18 : borrowerIndex[u]);
    }

    function healthFactorOf(address u) public view returns (uint256) {
        uint256 debt = borrowBalanceOf(u);
        if (debt == 0) return type(uint256).max;
        uint256 colUSD = _toUSD(ZUSDC, COL_DEC, collateralBalance[u]);
        uint256 debtUSD = _toUSD(WZTC, DEBT_DEC, debt);
        return (colUSD * LT) / debtUSD; // 1e18
    }

    // -------- Interest --------
    function _utilization(uint256 _cash, uint256 _borrows, uint256 _res) internal pure returns (uint256) {
        if (_borrows == 0) return 0;
        return _borrows * 1e18 / (_cash + _borrows - _res);
    }

    function _borrowRatePerSecond(uint256 _cash, uint256 _borrows, uint256 _res) internal pure returns (uint256) {
        uint256 u = _utilization(_cash, _borrows, _res);
        uint256 apr;
        if (u <= KINK) {
            apr = BASE + (SLOPE1 * u) / KINK;
        } else {
            apr = BASE + SLOPE1 + (SLOPE2 * (u - KINK)) / (1e18 - KINK);
        }
        return apr / YEAR;
    }

    function accrueInterest() public {
        if (block.timestamp == accrualTimestamp) return;
        uint256 dt = block.timestamp - accrualTimestamp;
        accrualTimestamp = block.timestamp;
        if (totalBorrows == 0) return;

        uint256 rate = _borrowRatePerSecond(cash(), totalBorrows, totalReserves); // 1e18
        uint256 interest = (totalBorrows * rate * dt) / 1e18;

        totalBorrows += interest;
        uint256 addRes = (interest * RES) / 1e18;
        totalReserves += addRes;
        borrowIndex = borrowIndex + (borrowIndex * rate * dt) / 1e18;
    }

    // -------- Supply (WZTC) --------
    function supply(uint256 amount) external nonReentrant {
        accrueInterest();
        uint256 rate = exchangeRate();
        uint256 mintShares = (amount * 1e18) / rate;
        require(debtToken.transferFrom(msg.sender, address(this), amount), "transferFrom");
        totalShares += mintShares;
        shares[msg.sender] += mintShares;
        emit Supply(msg.sender, amount, mintShares);
    }

    function withdrawUnderlying(uint256 amount) external nonReentrant {
        accrueInterest();
        uint256 rate = exchangeRate();
        uint256 burnShares = (amount * 1e18 + rate - 1) / rate;
        require(totalShares >= burnShares && shares[msg.sender] >= burnShares, "shares");
        require(cash() >= amount, "cash");

        shares[msg.sender] -= burnShares;
        totalShares -= burnShares;
        require(debtToken.transfer(msg.sender, amount), "transfer");
        emit Withdraw(msg.sender, amount, burnShares);
    }

    // -------- Collateral (ZUSDC) --------
    function depositCollateral(uint256 amount) external nonReentrant {
        accrueInterest();
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "transferFrom");
        collateralBalance[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        accrueInterest();
        require(collateralBalance[msg.sender] >= amount, "collateral");
        collateralBalance[msg.sender] -= amount;
        require(healthFactorOf(msg.sender) >= 1e18, "HF<1");
        require(collateralToken.transfer(msg.sender, amount), "transfer");
        emit WithdrawCollateral(msg.sender, amount);
    }

    // -------- Borrow/repay (WZTC) --------
    function borrow(uint256 amount) external nonReentrant {
        accrueInterest();
        require(cash() >= amount, "liquidity");

        uint256 owed = borrowBalanceOf(msg.sender);
        uint256 newOwed = owed + amount;

        // Check LTV
        uint256 colUSD = _toUSD(ZUSDC, COL_DEC, collateralBalance[msg.sender]);
        uint256 debtUSD = _toUSD(WZTC, DEBT_DEC, newOwed);
        require(debtUSD <= (colUSD * LTV) / 1e18, "exceeds LTV");

        borrowPrincipal[msg.sender] = (newOwed * 1e18) / borrowIndex;
        borrowerIndex[msg.sender] = borrowIndex;

        totalBorrows += amount;
        require(debtToken.transfer(msg.sender, amount), "transfer");
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external nonReentrant {
        accrueInterest();
        uint256 owed = borrowBalanceOf(msg.sender);
        require(owed > 0, "no debt");

        uint256 pay = amount > owed ? owed : amount;
        require(debtToken.transferFrom(msg.sender, address(this), pay), "transferFrom");

        uint256 newOwed = owed - pay;
        if (newOwed == 0) { borrowPrincipal[msg.sender] = 0; borrowerIndex[msg.sender] = 1e18; }
        else { borrowPrincipal[msg.sender] = (newOwed * 1e18) / borrowIndex; borrowerIndex[msg.sender] = borrowIndex; }
        totalBorrows -= pay;
        emit Repay(msg.sender, pay);
    }

    // -------- Liquidation --------
    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        accrueInterest();
        require(healthFactorOf(borrower) < 1e18, "healthy");

        uint256 owed = borrowBalanceOf(borrower);
        uint256 maxRepay = (owed * CLOSE) / 1e18;
        uint256 toRepay = repayAmount > maxRepay ? maxRepay : repayAmount;

        require(debtToken.transferFrom(msg.sender, address(this), toRepay), "transferFrom");

        uint256 newOwed = owed - toRepay;
        if (newOwed == 0) { borrowPrincipal[borrower] = 0; borrowerIndex[borrower] = 1e18; }
        else { borrowPrincipal[borrower] = (newOwed * 1e18) / borrowIndex; borrowerIndex[borrower] = borrowIndex; }
        totalBorrows -= toRepay;

        uint256 priceDebt = oracle.getPriceE8(WZTC);
        uint256 priceColl = oracle.getPriceE8(ZUSDC);
        uint256 seize = (toRepay * priceDebt * (10 ** COL_DEC)) / (priceColl * (10 ** DEBT_DEC));
        seize = (seize * BONUS) / 1e18;

        require(collateralBalance[borrower] >= seize, "collateral");
        collateralBalance[borrower] -= seize;
        require(collateralToken.transfer(msg.sender, seize), "transfer");

        emit Liquidate(msg.sender, borrower, toRepay, seize);
    }
}