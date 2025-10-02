// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceOracle {
    function getPriceE8(address token) external view returns (uint256);
}

/**
 * AdminPriceOracle
 * - Admin can update prices (USD, 1e8 decimals)
 * - Pre-seeded with:
 *   ZUSDC = $1.00
 *   WZTC  = $0.08012
 * Admin: 0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F
 * ZUSDC: 0xF8aD5140d8B21D68366755DeF1fEFA2e2665060C
 * WZTC : 0x66D9541D1220488F5d569a8a43e80298Df145f4E
 */
contract AdminPriceOracle is IPriceOracle {
    // Fixed addresses
    address public constant ADMIN = 0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F;
    address public constant ZUSDC = 0xF8aD5140d8B21D68366755DeF1fEFA2e2665060C;
    address public constant WZTC  = 0x66D9541D1220488F5d569a8a43e80298Df145f4E;

    // Initial prices (USD, 1e8)
    uint256 public constant ZUSDC_PRICE_E8 = 100_000_000; // $1.00
    uint256 public constant ZTC_PRICE_E8   =   8_012_000; // $0.08012

    // Current admin (starts as ADMIN, can be changed)
    address public admin;

    // token => price in 1e8
    mapping(address => uint256) public priceE8;

    event PriceUpdated(address indexed token, uint256 priceE8);
    event AdminChanged(address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    // No constructor args needed
    constructor() {
        admin = ADMIN;
        priceE8[ZUSDC] = ZUSDC_PRICE_E8;
        priceE8[WZTC]  = ZTC_PRICE_E8;
        emit PriceUpdated(ZUSDC, ZUSDC_PRICE_E8);
        emit PriceUpdated(WZTC,  ZTC_PRICE_E8);
        emit AdminChanged(ADMIN);
    }

    // Change admin (optional)
    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
        emit AdminChanged(_admin);
    }

    // Update price for any token
    function setPrice(address token, uint256 _priceE8) external onlyAdmin {
        priceE8[token] = _priceE8;
        emit PriceUpdated(token, _priceE8);
    }

    // Read price (USD, 1e8)
    function getPriceE8(address token) external view returns (uint256) {
        return priceE8[token];
    }
}