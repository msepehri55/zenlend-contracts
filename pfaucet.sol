// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ZenFaucet - native ZTC faucet with operator-triggered claims
/// @notice Users donate by sending ZTC to the contract address.
///         The backend (operator) calls claimFor(recipient) if the recipient
///         has < minEligibleBalance and cooldown has passed.
contract ZenFaucet {
    // --- Ownable (minimal) ---
    address public owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "newOwner=0");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- Pausable (minimal) ---
    bool public paused;
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }
    function pause() external onlyOwner { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    // --- ReentrancyGuard (minimal) ---
    bool private _entered;
    modifier nonReentrant() {
        require(!_entered, "Reentrancy");
        _entered = true;
        _;
        _entered = false;
    }

    // --- Operators (backend signers) ---
    mapping(address => bool) public operators;
    event OperatorUpdated(address indexed operator, bool allowed);
    modifier onlyOperator() {
        require(operators[msg.sender], "Not operator");
        _;
    }
    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    // --- Faucet config ---
    // Defaults assume 18 decimals (ZTC has 18)
    uint256 public payoutAmount;        // e.g., 20e18
    uint256 public minEligibleBalance;  // must be < this to claim (e.g., 20e18)
    uint256 public cooldown;            // seconds (e.g., 86400)

    event ParametersUpdated(uint256 payoutAmount, uint256 minEligibleBalance, uint256 cooldown);
    function setParameters(
        uint256 payout,
        uint256 minEligible,
        uint256 cooldownSeconds
    ) external onlyOwner {
        payoutAmount = payout;
        minEligibleBalance = minEligible;
        cooldown = cooldownSeconds;
        emit ParametersUpdated(payout, minEligible, cooldownSeconds);
    }

    mapping(address => uint256) public lastClaim; // last claim timestamp per recipient

    event Donated(address indexed from, uint256 amount);
    event Claimed(address indexed to, uint256 amount);

    // Hardcoded addresses per your request:
    // Owner:    0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F
    // Operator: 0x58530EA0481221124b4157536f4a2d0489195d67
    constructor() {
        address initialOwner = 0x58E53eaDBed51C4AffDc06E7CCeD4bE1265d928F;
        address initialOperator = 0x58530EA0481221124b4157536f4a2d0489195d67;

        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        operators[initialOperator] = true;
        emit OperatorUpdated(initialOperator, true);

        payoutAmount = 20 ether;        // 20 ZTC
        minEligibleBalance = 20 ether;  // must have < 20 ZTC to claim
        cooldown = 1 days;              // 24h
        emit ParametersUpdated(payoutAmount, minEligibleBalance, cooldown);
    }

    // Donations: send native ZTC directly
    receive() external payable { emit Donated(msg.sender, msg.value); }
    fallback() external payable { if (msg.value > 0) emit Donated(msg.sender, msg.value); }
    function donate() external payable { require(msg.value > 0, "no value"); emit Donated(msg.sender, msg.value); }

    // Operator triggers the payout to recipient (no wallet connect needed for users)
    function claimFor(address recipient)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        require(recipient != address(0), "recipient=0");
        require(recipient.balance < minEligibleBalance, "balance >= threshold");
        require(lastClaim[recipient] + cooldown <= block.timestamp, "cooldown active");
        require(address(this).balance >= payoutAmount, "faucet empty");

        lastClaim[recipient] = block.timestamp;

        (bool ok, ) = payable(recipient).call{value: payoutAmount}("");
        require(ok, "transfer failed");

        emit Claimed(recipient, payoutAmount);
    }

    // Helper views
    function faucetBalance() external view returns (uint256) {
        return address(this).balance;
    }
    function secondsUntilNextClaim(address account) external view returns (uint256) {
        uint256 next = lastClaim[account] + cooldown;
        if (next <= block.timestamp) return 0;
        return next - block.timestamp;
    }

    // Admin withdraw (e.g., to move leftover funds)
    function withdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "to=0");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }
}