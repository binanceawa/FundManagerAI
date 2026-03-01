// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FundManagerAI — DeFi yield allocator
/// @notice Routes customer deposits across strategies for optimal yield. Tulip-era accounting with block-based vesting.
/// @dev No delegatecall; reentrancy guard; all config immutable or owner-set; mainnet-safe.

contract FundManagerAI {
    uint256 private _lock;

    uint256 public constant FMAI_BPS = 10000;
    uint256 public constant FMAI_MAX_FEE_BPS = 2000;
    uint256 public constant FMAI_MIN_DEPOSIT = 100;
    uint256 public constant FMAI_MAX_STRATEGIES = 32;
    uint256 public constant FMAI_HARVEST_COOLDOWN_BLOCKS = 12;
    uint256 public constant FMAI_VESTING_BLOCKS = 86400;
    uint256 public constant FMAI_STRATEGY_CAP_BPS = 5000;
    uint256 public constant FMAI_DOMAIN_TYPEHASH = 0x8f2a4b6c8e0d1f3a5b7c9d1e3f5a7b9c0d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2;
    bytes32 public constant FMAI_DEPOSIT_TYPEHASH = keccak256("FMAI_Deposit(address user,address token,uint256 amount,uint256 nonce)");
    bytes32 public constant FMAI_CLAIM_TYPEHASH = keccak256("FMAI_Claim(address user,uint256 amount,uint256 nonce)");

    address public immutable treasury;
    address public immutable yieldKeeper;
    address public immutable vault;
    uint256 public immutable genesisBlock;
    bytes32 public immutable domainSeparator;

    address public owner;
    bool public fmaiPaused;
    uint256 public performanceFeeBps;
    uint256 public depositFeeBps;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;
    uint256 public totalYieldHarvested;
    uint256 public strategyCount;
    uint256 public lastHarvestBlock;

    struct FMAIStrategy {
        address target;
        address token;
        uint256 allocated;
        uint256 harvested;
        uint256 capBps;
        bool active;
        uint256 addedAtBlock;
    }
    mapping(uint256 => FMAIStrategy) public fmaiStrategies;

    struct FMAIDepositor {
        uint256 deposited;
        uint256 withdrawn;
        uint256 lastDepositBlock;
        uint256 pendingYield;
        uint256 yieldClaimed;
        uint256 vestingStartBlock;
        uint256 vestingAmount;
    }
    mapping(address => mapping(address => FMAIDepositor)) public fmaiDepositors;

    mapping(address => uint256) public userNonce;
    mapping(address => bool) public allowedTokens;
    mapping(address => uint256) public tokenTotalDeposits;
    address[] public tokenList;
    mapping(uint256 => address[]) public strategyDepositorList;

    error FMAI_Unauthorized();
    error FMAI_Paused();
    error FMAI_Reentrancy();
    error FMAI_ZeroAddress();
    error FMAI_ZeroAmount();
