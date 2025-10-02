// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
interface ERC20Helper {
function approve(address spender, uint256 amount) external returns (bool);
function allowance(address owner, address spender) external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
function decimals() external view returns (uint8);
}