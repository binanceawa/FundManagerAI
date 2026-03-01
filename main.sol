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
    error FMAI_TokenNotAllowed();
    error FMAI_DepositTooSmall();
    error FMAI_InsufficientBalance();
    error FMAI_TransferFailed();
    error FMAI_StrategyNotFound();
    error FMAI_StrategyInactive();
    error FMAI_StrategyCapExceeded();
    error FMAI_MaxStrategies();
    error FMAI_HarvestCooldown();
    error FMAI_InvalidFee();
    error FMAI_InvalidBps();
    error FMAI_NoYieldToClaim();
    error FMAI_VestingNotDone();
    error FMAI_InvalidStrategyId();

    event FMAI_Deposit(address indexed user, address indexed token, uint256 amount, uint256 feeWei, uint256 netAmount);
    event FMAI_Withdraw(address indexed user, address indexed token, uint256 amount);
    event FMAI_StrategyAdded(uint256 indexed strategyId, address target, address token, uint256 capBps);
    event FMAI_StrategyAllocated(uint256 indexed strategyId, uint256 amount);
    event FMAI_YieldHarvested(uint256 indexed strategyId, uint256 amount);
    event FMAI_YieldClaimed(address indexed user, uint256 amount);
    event FMAI_PauseToggled(bool paused);
    event FMAI_FeesUpdated(uint256 performanceFeeBps, uint256 depositFeeBps);
    event FMAI_OwnershipTransferred(address indexed previous, address indexed next);
    event FMAI_TokenAllowed(address indexed token, bool allowed);

    modifier onlyOwner() {
        if (msg.sender != owner) revert FMAI_Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (fmaiPaused) revert FMAI_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert FMAI_Reentrancy();
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor() {
        treasury = 0x8b3f92a1c4d6e7f9a0b2c3d4e5f6a7b8c9d0e1f2;
        yieldKeeper = 0x1c5e7a9b0d2f4b6d8e0a2c4e6f8b0d2f4a6c8e0a;
        vault = 0x3d7f1a9e0b4c6d8f2a5c7e9b1d4f6a8c0e2a4b6d;
        genesisBlock = block.number;
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FundManagerAI"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        owner = msg.sender;
        performanceFeeBps = 100;
        depositFeeBps = 10;
    }

    function deposit(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (token == address(0)) revert FMAI_ZeroAddress();
        if (amount == 0) revert FMAI_ZeroAmount();
        if (!allowedTokens[token]) revert FMAI_TokenNotAllowed();
        if (amount < FMAI_MIN_DEPOSIT) revert FMAI_DepositTooSmall();

        uint256 fee = (amount * depositFeeBps) / FMAI_BPS;
        uint256 net = amount - fee;
