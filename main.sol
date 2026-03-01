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
        if (fee > 0) _pushToken(token, treasury, fee);

        _pullToken(token, msg.sender, amount);
        totalDeposited += amount;
        tokenTotalDeposits[token] += amount;

        FMAIDepositor storage d = fmaiDepositors[msg.sender][token];
        d.deposited += net;
        d.lastDepositBlock = block.number;
        if (tokenList.length == 0 || tokenTotalDeposits[token] == net) {
            bool found;
            for (uint256 i = 0; i < tokenList.length; i++) {
                if (tokenList[i] == token) { found = true; break; }
            }
            if (!found) tokenList.push(token);
        }

        emit FMAI_Deposit(msg.sender, token, amount, fee, net);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert FMAI_ZeroAddress();
        if (amount == 0) revert FMAI_ZeroAmount();
        FMAIDepositor storage d = fmaiDepositors[msg.sender][token];
        uint256 available = d.deposited - d.withdrawn;
        if (amount > available) revert FMAI_InsufficientBalance();

        d.withdrawn += amount;
        totalWithdrawn += amount;
        tokenTotalDeposits[token] -= amount;
        _pushToken(token, msg.sender, amount);
        emit FMAI_Withdraw(msg.sender, token, amount);
    }

    function addStrategy(address target, address token, uint256 capBps) external onlyOwner {
        if (strategyCount >= FMAI_MAX_STRATEGIES) revert FMAI_MaxStrategies();
        if (capBps > FMAI_STRATEGY_CAP_BPS) revert FMAI_InvalidBps();
        strategyCount++;
        uint256 id = strategyCount;
        fmaiStrategies[id] = FMAIStrategy({
            target: target,
            token: token,
            allocated: 0,
            harvested: 0,
            capBps: capBps,
            active: true,
            addedAtBlock: block.number
        });
        emit FMAI_StrategyAdded(id, target, token, capBps);
    }

    function allocateToStrategy(uint256 strategyId, uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        if (strategyId == 0 || strategyId > strategyCount) revert FMAI_InvalidStrategyId();
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        if (!s.active) revert FMAI_StrategyInactive();
        if (amount == 0) revert FMAI_ZeroAmount();

        uint256 cap = (tokenTotalDeposits[s.token] * s.capBps) / FMAI_BPS;
        if (s.allocated + amount > cap) revert FMAI_StrategyCapExceeded();

        s.allocated += amount;
        _pushToken(s.token, s.target, amount);
        emit FMAI_StrategyAllocated(strategyId, amount);
    }

    function harvestYield(uint256 strategyId, uint256 amount) external onlyOwner nonReentrant {
        if (strategyId == 0 || strategyId > strategyCount) revert FMAI_InvalidStrategyId();
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        if (!s.active) revert FMAI_StrategyInactive();
        if (block.number < lastHarvestBlock + FMAI_HARVEST_COOLDOWN_BLOCKS) revert FMAI_HarvestCooldown();

        lastHarvestBlock = block.number;
        (bool ok,) = s.target.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        if (!ok) revert FMAI_TransferFailed();
        s.harvested += amount;
        totalYieldHarvested += amount;
        uint256 fee = (amount * performanceFeeBps) / FMAI_BPS;
        if (fee > 0) _pushToken(s.token, treasury, fee);
        emit FMAI_YieldHarvested(strategyId, amount);
    }

    function creditYieldToUser(address user, address token, uint256 amount) external onlyOwner {
        if (user == address(0)) revert FMAI_ZeroAddress();
        if (amount == 0) revert FMAI_ZeroAmount();
        FMAIDepositor storage d = fmaiDepositors[user][token];
        d.pendingYield += amount;
        d.vestingStartBlock = block.number;
        d.vestingAmount += amount;
    }

    function claimYield(address token) external nonReentrant {
        FMAIDepositor storage d = fmaiDepositors[msg.sender][token];
        uint256 claimable;
        if (block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS) {
            claimable = d.vestingAmount - d.yieldClaimed;
        } else {
            uint256 elapsed = block.number - d.vestingStartBlock;
            if (elapsed >= FMAI_VESTING_BLOCKS) {
                claimable = d.vestingAmount - d.yieldClaimed;
            } else {
                uint256 vested = (d.vestingAmount * elapsed) / FMAI_VESTING_BLOCKS;
                claimable = vested > d.yieldClaimed ? vested - d.yieldClaimed : 0;
            }
        }
        if (claimable == 0) revert FMAI_NoYieldToClaim();
        d.yieldClaimed += claimable;
        _pushToken(token, msg.sender, claimable);
        emit FMAI_YieldClaimed(msg.sender, claimable);
    }

    function setPaused(bool p) external onlyOwner {
        fmaiPaused = p;
        emit FMAI_PauseToggled(p);
    }

    function setFees(uint256 perfBps, uint256 depBps) external onlyOwner {
        if (perfBps > FMAI_MAX_FEE_BPS || depBps > FMAI_MAX_FEE_BPS) revert FMAI_InvalidFee();
        performanceFeeBps = perfBps;
        depositFeeBps = depBps;
        emit FMAI_FeesUpdated(perfBps, depBps);
    }

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        allowedTokens[token] = allowed;
        emit FMAI_TokenAllowed(token, allowed);
    }

    function setStrategyActive(uint256 strategyId, bool active) external onlyOwner {
        if (strategyId == 0 || strategyId > strategyCount) revert FMAI_InvalidStrategyId();
        fmaiStrategies[strategyId].active = active;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert FMAI_ZeroAddress();
        emit FMAI_OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getDepositBalance(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return d.deposited - d.withdrawn;
    }

    function getClaimableYield(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        if (block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS)
            return d.vestingAmount - d.yieldClaimed;
        uint256 elapsed = block.number - d.vestingStartBlock;
        if (elapsed >= FMAI_VESTING_BLOCKS) return d.vestingAmount - d.yieldClaimed;
        uint256 vested = (d.vestingAmount * elapsed) / FMAI_VESTING_BLOCKS;
        return vested > d.yieldClaimed ? vested - d.yieldClaimed : 0;
    }

    function getStrategy(uint256 strategyId) external view returns (
        address target,
        address token,
        uint256 allocated,
        uint256 harvested,
        uint256 capBps,
        bool active,
        uint256 addedAtBlock
    ) {
        if (strategyId == 0 || strategyId > strategyCount) revert FMAI_InvalidStrategyId();
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        return (s.target, s.token, s.allocated, s.harvested, s.capBps, s.active, s.addedAtBlock);
    }

    function getTokenList() external view returns (address[] memory) {
        return tokenList;
    }

    function getTokenTotalDeposits(address token) external view returns (uint256) {
        return tokenTotalDeposits[token];
    }

    function getGlobalStats() external view returns (
        uint256 totalDeposited_,
        uint256 totalWithdrawn_,
        uint256 totalYieldHarvested_,
        uint256 strategyCount_,
        bool paused_
    ) {
        return (totalDeposited, totalWithdrawn, totalYieldHarvested, strategyCount, fmaiPaused);
    }

    uint256 public constant FMAI_TOKEN_LIST_MAX = 64;
    uint256 public constant FMAI_STRATEGY_NAME_MAX_LEN = 24;
    uint256 public constant FMAI_YIELD_DECIMALS = 18;
    uint256 public constant FMAI_GENESIS_SEED = 0x7a2b4c6e8f0a1d3e5b7c9d1f4a6c8e0b2d5f7a9;

    function getDepositorFull(address user, address token) external view returns (
        uint256 deposited_,
        uint256 withdrawn_,
        uint256 netBalance_,
        uint256 lastDepositBlock_,
        uint256 pendingYield_,
        uint256 yieldClaimed_,
        uint256 vestingStartBlock_,
        uint256 vestingAmount_
    ) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return (
            d.deposited,
            d.withdrawn,
            d.deposited - d.withdrawn,
            d.lastDepositBlock,
            d.pendingYield,
            d.yieldClaimed,
            d.vestingStartBlock,
            d.vestingAmount
        );
    }

    function getStrategyIdsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = strategyCount;
        if (offset >= n) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > n) end = n;
        uint256 len = end - offset;
        ids = new uint256[](len);
        for (uint256 i = 0; i < len; i++) ids[i] = offset + i + 1;
    }

    function getStrategyBatch(uint256[] calldata strategyIds) external view returns (
        address[] memory targets,
        address[] memory tokens,
        uint256[] memory allocateds,
        uint256[] memory harvesteds,
        bool[] memory actives
    ) {
        uint256 n = strategyIds.length;
        targets = new address[](n);
        tokens = new address[](n);
        allocateds = new uint256[](n);
        harvesteds = new uint256[](n);
        actives = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = strategyIds[i];
            if (id != 0 && id <= strategyCount) {
                FMAIStrategy storage s = fmaiStrategies[id];
                targets[i] = s.target;
                tokens[i] = s.token;
                allocateds[i] = s.allocated;
                harvesteds[i] = s.harvested;
                actives[i] = s.active;
            }
        }
    }

    function getTokenListLength() external view returns (uint256) {
        return tokenList.length;
    }

    function getTokenAt(uint256 index) external view returns (address) {
        return tokenList[index];
    }

    function isTokenAllowed(address token) external view returns (bool) {
        return allowedTokens[token];
    }

    function getFeeConfig() external view returns (uint256 perfBps, uint256 depBps) {
        return (performanceFeeBps, depositFeeBps);
    }

    function getImmutableAddresses() external view returns (address treasury_, address keeper_, address vault_) {
        return (treasury, yieldKeeper, vault);
    }

    function getGenesisBlock() external view returns (uint256) {
        return genesisBlock;
    }

    function getDomainSeparator() external view returns (bytes32) {
        return domainSeparator;
    }

    function harvestCooldownRemaining() external view returns (uint256) {
        if (block.number >= lastHarvestBlock + FMAI_HARVEST_COOLDOWN_BLOCKS) return 0;
        return lastHarvestBlock + FMAI_HARVEST_COOLDOWN_BLOCKS - block.number;
    }

    function canHarvest() external view returns (bool) {
        return block.number >= lastHarvestBlock + FMAI_HARVEST_COOLDOWN_BLOCKS;
    }

    function getStrategyCapRemaining(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        uint256 cap = (tokenTotalDeposits[s.token] * s.capBps) / FMAI_BPS;
        return cap > s.allocated ? cap - s.allocated : 0;
    }

    function getVestingProgress(address user, address token) external view returns (
        uint256 startBlock_,
        uint256 endBlock_,
        uint256 currentBlock_,
        uint256 vestingAmount_,
        uint256 claimed_
    ) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return (
            d.vestingStartBlock,
            d.vestingStartBlock + FMAI_VESTING_BLOCKS,
            block.number,
            d.vestingAmount,
            d.yieldClaimed
        );
    }

    function getDepositFeeForAmount(uint256 amount) external view returns (uint256) {
        return (amount * depositFeeBps) / FMAI_BPS;
    }

    function getPerformanceFeeForAmount(uint256 amount) external view returns (uint256) {
        return (amount * performanceFeeBps) / FMAI_BPS;
    }

    function getNetDepositAmount(uint256 grossAmount) external view returns (uint256) {
        return grossAmount - (grossAmount * depositFeeBps) / FMAI_BPS;
    }

    function totalNetDeposits() external view returns (uint256) {
        return totalDeposited - totalWithdrawn;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function getPaused() external view returns (bool) {
        return fmaiPaused;
    }

    function getLastHarvestBlock() external view returns (uint256) {
        return lastHarvestBlock;
    }

    function getConstantsBundle() external pure returns (
        uint256 bps,
        uint256 maxFeeBps,
        uint256 minDeposit,
        uint256 maxStrategies,
        uint256 harvestCooldownBlocks,
        uint256 vestingBlocks,
        uint256 strategyCapBps
    ) {
        return (
            FMAI_BPS,
            FMAI_MAX_FEE_BPS,
            FMAI_MIN_DEPOSIT,
            FMAI_MAX_STRATEGIES,
            FMAI_HARVEST_COOLDOWN_BLOCKS,
            FMAI_VESTING_BLOCKS,
            FMAI_STRATEGY_CAP_BPS
        );
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getContractTokenBalance(address token) external view returns (uint256) {
        return IERC20Min(token).balanceOf(address(this));
    }

    function getFullStrategy(uint256 strategyId) external view returns (
        address target_,
        address token_,
        uint256 allocated_,
        uint256 harvested_,
        uint256 capBps_,
        bool active_,
        uint256 addedAtBlock_,
        uint256 capWei_,
        uint256 remainingCap_
    ) {
        if (strategyId == 0 || strategyId > strategyCount) revert FMAI_InvalidStrategyId();
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        uint256 capWei = (tokenTotalDeposits[s.token] * s.capBps) / FMAI_BPS;
        uint256 rem = capWei > s.allocated ? capWei - s.allocated : 0;
        return (
            s.target,
            s.token,
            s.allocated,
            s.harvested,
            s.capBps,
            s.active,
            s.addedAtBlock,
            capWei,
            rem
        );
    }

    function getActiveStrategyIds() external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].active) count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].active) {
                ids[j] = i;
                j++;
            }
        }
        return ids;
    }

    function getStrategyCountActive() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].active) c++;
        }
        return c;
    }

    function getUserNonce(address user) external view returns (uint256) {
        return userNonce[user];
    }

    function getTotalYieldHarvested() external view returns (uint256) {
        return totalYieldHarvested;
    }

    function getTotalDeposited() external view returns (uint256) {
        return totalDeposited;
    }

    function getTotalWithdrawn() external view returns (uint256) {
        return totalWithdrawn;
    }

    function getStrategyAllocated(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        return fmaiStrategies[strategyId].allocated;
    }

    function getStrategyHarvested(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        return fmaiStrategies[strategyId].harvested;
    }

    function getStrategyToken(uint256 strategyId) external view returns (address) {
        if (strategyId == 0 || strategyId > strategyCount) return address(0);
        return fmaiStrategies[strategyId].token;
    }

    function getStrategyTarget(uint256 strategyId) external view returns (address) {
        if (strategyId == 0 || strategyId > strategyCount) return address(0);
        return fmaiStrategies[strategyId].target;
    }

    function getStrategyActive(uint256 strategyId) external view returns (bool) {
        if (strategyId == 0 || strategyId > strategyCount) return false;
        return fmaiStrategies[strategyId].active;
    }

    function vestingBlocksRemaining(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        uint256 endBlock = d.vestingStartBlock + FMAI_VESTING_BLOCKS;
        if (block.number >= endBlock) return 0;
        return endBlock - block.number;
    }

    function isVestingComplete(address user, address token) external view returns (bool) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS;
    }

    function getDepositBalanceBatch(address user, address[] calldata tokens) external view returns (uint256[] memory balances) {
        uint256 n = tokens.length;
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            FMAIDepositor storage d = fmaiDepositors[user][tokens[i]];
            balances[i] = d.deposited - d.withdrawn;
        }
    }

    function getClaimableYieldBatch(address user, address[] calldata tokens) external view returns (uint256[] memory claimables) {
        uint256 n = tokens.length;
        claimables = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            FMAIDepositor storage d = fmaiDepositors[user][tokens[i]];
            if (block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS) {
                claimables[i] = d.vestingAmount - d.yieldClaimed;
            } else {
                uint256 elapsed = block.number - d.vestingStartBlock;
                uint256 vested = (d.vestingAmount * elapsed) / FMAI_VESTING_BLOCKS;
                claimables[i] = vested > d.yieldClaimed ? vested - d.yieldClaimed : 0;
            }
        }
    }

    uint256 public constant FMAI_VERSION = 1;
    uint256 public constant FMAI_RESERVE_BPS = 500;
    uint256 public constant FMAI_EMERGENCY_DELAY_BLOCKS = 100;
    bytes32 public constant FMAI_HARVEST_TYPEHASH = keccak256("FMAI_Harvest(uint256 strategyId,uint256 amount,uint256 nonce)");
    bytes32 public constant FMAI_ALLOCATE_TYPEHASH = keccak256("FMAI_Allocate(uint256 strategyId,uint256 amount,uint256 nonce)");

    function computeDepositFee(uint256 amount, uint256 bps) external pure returns (uint256 fee, uint256 net) {
        fee = (amount * bps) / FMAI_BPS;
        net = amount - fee;
    }

    function computePerformanceFee(uint256 amount, uint256 bps) external pure returns (uint256 fee) {
        return (amount * bps) / FMAI_BPS;
    }

    function getFullGlobalStats() external view returns (
        uint256 totalDeposited_,
        uint256 totalWithdrawn_,
        uint256 totalYieldHarvested_,
        uint256 strategyCount_,
        bool paused_,
        uint256 perfFeeBps_,
        uint256 depFeeBps_,
        uint256 lastHarvestBlock_,
        uint256 genesisBlock_,
        uint256 chainId_
    ) {
        return (
            totalDeposited,
            totalWithdrawn,
            totalYieldHarvested,
            strategyCount,
            fmaiPaused,
            performanceFeeBps,
            depositFeeBps,
            lastHarvestBlock,
            genesisBlock,
            block.chainid
        );
    }

    function getTokenTotalsBatch(address[] calldata tokens) external view returns (uint256[] memory totals) {
        uint256 n = tokens.length;
        totals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) totals[i] = tokenTotalDeposits[tokens[i]];
    }

    function getStrategyCapInWei(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        FMAIStrategy storage s = fmaiStrategies[strategyId];
        return (tokenTotalDeposits[s.token] * s.capBps) / FMAI_BPS;
    }

    function blocksUntilHarvestAllowed() external view returns (uint256) {
        uint256 next = lastHarvestBlock + FMAI_HARVEST_COOLDOWN_BLOCKS;
        if (block.number >= next) return 0;
        return next - block.number;
    }

    function getDepositorSummary(address user) external view returns (
        uint256 totalDepositedByUser_,
        uint256 totalWithdrawnByUser_,
        uint256 netDeposited_
    ) {
        totalDepositedByUser_ = 0;
        totalWithdrawnByUser_ = 0;
        for (uint256 i = 0; i < tokenList.length; i++) {
            address t = tokenList[i];
            FMAIDepositor storage d = fmaiDepositors[user][t];
            totalDepositedByUser_ += d.deposited;
            totalWithdrawnByUser_ += d.withdrawn;
        }
        netDeposited_ = totalDepositedByUser_ - totalWithdrawnByUser_;
    }

    function getDepositorSummaryForToken(address user, address token) external view returns (
        uint256 deposited_,
        uint256 withdrawn_,
        uint256 net_,
        uint256 yieldClaimed_,
        uint256 vestingAmount_
    ) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return (
            d.deposited,
            d.withdrawn,
            d.deposited - d.withdrawn,
            d.yieldClaimed,
            d.vestingAmount
        );
    }

    function totalAllocatedAcrossStrategies() external view returns (uint256 total) {
        for (uint256 i = 1; i <= strategyCount; i++) {
            total += fmaiStrategies[i].allocated;
        }
    }

    function totalHarvestedAcrossStrategies() external view returns (uint256 total) {
        for (uint256 i = 1; i <= strategyCount; i++) {
            total += fmaiStrategies[i].harvested;
        }
    }

    function getStrategyIdsForToken(address token) external view returns (uint256[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) count++;
        }
        ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getActiveStrategyIdsForToken(address token) external view returns (uint256[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            FMAIStrategy storage s = fmaiStrategies[i];
            if (s.token == token && s.active) count++;
        }
        ids = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            FMAIStrategy storage s = fmaiStrategies[i];
            if (s.token == token && s.active) {
                ids[j] = i;
                j++;
            }
        }
    }

    function getVestingEndBlock(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return d.vestingStartBlock + FMAI_VESTING_BLOCKS;
    }

    function getMinDeposit() external pure returns (uint256) {
        return FMAI_MIN_DEPOSIT;
    }

    function getMaxStrategies() external pure returns (uint256) {
        return FMAI_MAX_STRATEGIES;
    }

    function getVestingBlocks() external pure returns (uint256) {
        return FMAI_VESTING_BLOCKS;
    }

    function getHarvestCooldownBlocks() external pure returns (uint256) {
        return FMAI_HARVEST_COOLDOWN_BLOCKS;
    }

    function getBpsDenom() external pure returns (uint256) {
        return FMAI_BPS;
    }

    function getMaxFeeBps() external pure returns (uint256) {
        return FMAI_MAX_FEE_BPS;
    }

    function getStrategyCapBpsLimit() external pure returns (uint256) {
        return FMAI_STRATEGY_CAP_BPS;
    }

    function isOwner(address account) external view returns (bool) {
        return account == owner;
    }

    function isTreasury(address account) external view returns (bool) {
        return account == treasury;
    }

    function isYieldKeeper(address account) external view returns (bool) {
        return account == yieldKeeper;
    }

    function isVault(address account) external view returns (bool) {
        return account == vault;
    }

    function getDomainInfo() external view returns (bytes32 domainSep_, uint256 genesis_) {
        return (domainSeparator, genesisBlock);
    }

    function estimateYieldAfterFee(uint256 grossYield, uint256 bps) external pure returns (uint256 netYield) {
        uint256 fee = (grossYield * bps) / FMAI_BPS;
        return grossYield - fee;
    }

    function estimateDepositNet(uint256 gross, uint256 bps) external pure returns (uint256 net) {
        return gross - (gross * bps) / FMAI_BPS;
    }

    function getStrategyAddedAtBlock(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        return fmaiStrategies[strategyId].addedAtBlock;
    }

    function getStrategyCapBps(uint256 strategyId) external view returns (uint256) {
        if (strategyId == 0 || strategyId > strategyCount) return 0;
        return fmaiStrategies[strategyId].capBps;
    }

    function hasDeposit(address user, address token) external view returns (bool) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return d.deposited > d.withdrawn;
    }

    function hasVesting(address user, address token) external view returns (bool) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        return d.vestingAmount > d.yieldClaimed;
    }

    function getYieldVestedSoFar(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        if (block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS) return d.vestingAmount;
        uint256 elapsed = block.number - d.vestingStartBlock;
        return (d.vestingAmount * elapsed) / FMAI_VESTING_BLOCKS;
    }

    function getYieldPendingVest(address user, address token) external view returns (uint256) {
        FMAIDepositor storage d = fmaiDepositors[user][token];
        uint256 vested;
        if (block.number >= d.vestingStartBlock + FMAI_VESTING_BLOCKS) vested = d.vestingAmount;
        else {
            uint256 elapsed = block.number - d.vestingStartBlock;
            vested = (d.vestingAmount * elapsed) / FMAI_VESTING_BLOCKS;
        }
        return vested > d.yieldClaimed ? vested - d.yieldClaimed : 0;
    }

    function getStrategyAllocationsForToken(address token) external view returns (uint256[] memory allocations) {
        uint256 count = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) count++;
        }
        allocations = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) {
                allocations[j] = fmaiStrategies[i].allocated;
                j++;
            }
        }
    }

    function getStrategyHarvestsForToken(address token) external view returns (uint256[] memory harvests) {
        uint256 count = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) count++;
        }
        harvests = new uint256[](count);
        uint256 j = 0;
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].token == token) {
                harvests[j] = fmaiStrategies[i].harvested;
                j++;
            }
        }
    }

    function bpsToFraction(uint256 bps) external pure returns (uint256 num, uint256 denom) {
        return (bps, FMAI_BPS);
    }

    function fractionToBps(uint256 num, uint256 denom) external pure returns (uint256 bps) {
        if (denom == 0) return 0;
        return (num * FMAI_BPS) / denom;
    }

    function applyBps(uint256 amount, uint256 bps) external pure returns (uint256 result) {
        return (amount * bps) / FMAI_BPS;
    }

    function applyBpsReverse(uint256 amount, uint256 bps) external pure returns (uint256 result) {
        return (amount * (FMAI_BPS - bps)) / FMAI_BPS;
    }

    function getTreasury() external view returns (address) { return treasury; }
    function getYieldKeeper() external view returns (address) { return yieldKeeper; }
    function getVault() external view returns (address) { return vault; }

    function getStrategyCount() external view returns (uint256) { return strategyCount; }

    function tokenListContains(address token) external view returns (bool) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            if (tokenList[i] == token) return true;
        }
        return false;
    }

    function getDepositFeeBps() external view returns (uint256) { return depositFeeBps; }
    function getPerformanceFeeBps() external view returns (uint256) { return performanceFeeBps; }

    function netDeposits() external view returns (uint256) {
        return totalDeposited > totalWithdrawn ? totalDeposited - totalWithdrawn : 0;
    }

    function getStrategyAllocationSum() external view returns (uint256 sum) {
        for (uint256 i = 1; i <= strategyCount; i++) sum += fmaiStrategies[i].allocated;
    }

    function getStrategyHarvestSum() external view returns (uint256 sum) {
        for (uint256 i = 1; i <= strategyCount; i++) sum += fmaiStrategies[i].harvested;
    }

    function getActiveStrategyCount() external view returns (uint256 c) {
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (fmaiStrategies[i].active) c++;
        }
    }

    function getInactiveStrategyCount() external view returns (uint256 c) {
        for (uint256 i = 1; i <= strategyCount; i++) {
            if (!fmaiStrategies[i].active) c++;
        }
    }

    function getStrategyByIndex(uint256 index) external view returns (
        uint256 id_,
        address target_,
        address token_,
        uint256 allocated_,
        bool active_
    ) {
        if (index >= strategyCount) revert FMAI_InvalidStrategyId();
        uint256 id = index + 1;
        FMAIStrategy storage s = fmaiStrategies[id];
        return (id, s.target, s.token, s.allocated, s.active);
    }

    function getTokenTotalByIndex(uint256 index) external view returns (address token_, uint256 total_) {
        if (index >= tokenList.length) revert FMAI_InvalidStrategyId();
        token_ = tokenList[index];
        total_ = tokenTotalDeposits[token_];
    }
