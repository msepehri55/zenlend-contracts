// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface WZTC_DepositHelper {
function deposit() external payable;
function approve(address spender, uint256 amount) external returns (bool);
function balanceOf(address account) external view returns (uint256);
}