// SPDX-License-Identifier: MIT


pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

abstract contract Ownable {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        require(newOwner != _owner, "Ownable: same owner");

        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

interface IPancakeFactory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
}

interface IPancakeRouter {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

contract KindLPStakingV2 is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable KIND;
    IERC20 public HUG; // original HUG address
    IERC20 public rewardToken; // rewards token (initially HUG)
    address public burnAddress;
    address public devWallet;

    address public WBNB;
    address public BUSD;
    IPancakeFactory public immutable pancakeFactory;
    IPancakeRouter public pancakeRouter;

    // Parameters
    uint256 public minStakeUSD = 50 * 1e18; // $50
    uint256 public monthSeconds = 30 days;
    uint256 public stakingFee = 500; // 5%
    uint256 public earlyUnstake = 1500; // 15%
    bool public earlyUnstakeEnabled = true;
    uint256 public claimInterval = 1 days;
    uint256 public lockSeconds = 90 days; // 90 days lock for unstake

    // Plans
    struct Plan {
        uint256 minUSD;
        uint256 monthlyRate; // 1000 = 10% every 30 days
    }
    Plan[] public plans;

    // Pool info
    struct PoolInfo {
        IERC20 lpToken;
        address token0;
        address token1;
        bool active;
        uint256 totalStakedLP;
        uint256 totalBurnedToken; // token-side burned via stake/fees
        uint256 totalBNBToDev; // BNB or "BNB-side" token forwarded to dev
    }
    PoolInfo[] public poolInfo;

    // Positions
    struct Position {
        address user;
        uint256 pid; // pool id
        uint256 lpAmount; // LP tokens staked (after stake fee)
        uint8 planId;
        uint256 stakeUSD; // USD value at stake time
        uint256 startTime;
        uint256 endTime; // lock end
        bool closed;
        uint256 lastClaimTime;
        uint256 endTimeAtClose; // when unstaked
    }

    uint256 public positionCounter;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public positionsOfUser;

    // Referrals
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public referralEarnings;

    uint256 public referralStakePercent = 5; // stake bonus (default 5%)
    uint256 public referralClaimPercent = 2; // claim bonus (default 2%)

    // Price pair mapping (token => pair address)
    mapping(address => address) public tokenPairs;

    // Events
    event PoolAdded(
        uint256 indexed pid,
        address lpToken,
        address token0,
        address token1
    );
    event PoolsAdded(uint256 startPid, uint256 count);
    event RewardTokenUpdated(address indexed previous, address indexed current);
    event EarlyUnstakeEnabledUpdated(bool enabled);
    event Staked(
        address indexed user,
        uint256 indexed positionId,
        uint256 pid,
        uint8 planId,
        uint256 lpAmount,
        uint256 stakeUSD
    );
    event Claimed(
        address indexed user,
        uint256 indexed positionId,
        uint256 usdPaid,
        uint256 rewardPaid
    );
    event Unstaked(
        address indexed user,
        uint256 indexed positionId,
        uint256 lpReturned,
        bool early,
        uint256 lpFeeProcessed
    );
    event ReferralRegistered(address indexed user, address indexed referrer);
    event ReferralStakeBonus(
        address indexed referrer,
        address indexed referee,
        uint256 usd,
        uint256 rewardPaid
    );
    event ReferralClaimBonus(
        address indexed referrer,
        address indexed referee,
        uint256 rewardPaid
    );
    event ClaimIntervalUpdated(uint256 newInterval);

    event PoolUpdated(
        uint256 indexed pid,
        address lpToken,
        address token0,
        address token1,
        bool active
    );

    constructor(
        address _kind,
        address _hug,
        address _burn,
        address _wbnb,
        address _busd,
        address _factory,
        address _router,
        address _devWallet,
        address kindWbnbLP,
        address hugWbnbLP
    ) {
        require(
            _kind != address(0) &&
                _hug != address(0) &&
                _factory != address(0) &&
                _router != address(0),
            "Zero address"
        );
        KIND = IERC20(_kind);
        HUG = IERC20(_hug);
        rewardToken = IERC20(_hug);
        burnAddress = _burn == address(0)
            ? 0x000000000000000000000000000000000000dEaD
            : _burn;
        WBNB = _wbnb;
        BUSD = _busd;
        pancakeFactory = IPancakeFactory(_factory);
        pancakeRouter = IPancakeRouter(_router);
        devWallet = _devWallet;

        // Default plans (Bronze / Silver / Gold / Diamond)
        plans.push(Plan({minUSD: 50 * 1e18, monthlyRate: 1000})); // 10% / 30 days
        plans.push(Plan({minUSD: 300 * 1e18, monthlyRate: 1500})); // 15% / 30 days
        plans.push(Plan({minUSD: 1500 * 1e18, monthlyRate: 2000})); // 20% / 30 days
        plans.push(Plan({minUSD: 10000 * 1e18, monthlyRate: 2700})); // 27% / 30 days

        // Optionally auto-add KIND/WBNB and HUG/WBNB LP pools
        if (kindWbnbLP != address(0)) {
            addPool(kindWbnbLP);
        }
        if (hugWbnbLP != address(0)) {
            addPool(hugWbnbLP);
        }
    }

    /* ================================= Admin ================================= */

    function addPool(address lpToken) public onlyOwner {
        require(lpToken != address(0), "Zero lp");
        IPancakePair pair = IPancakePair(lpToken);
        address t0 = pair.token0();
        address t1 = pair.token1();

        PoolInfo memory p = PoolInfo({
            lpToken: IERC20(lpToken),
            token0: t0,
            token1: t1,
            active: true,
            totalStakedLP: 0,
            totalBurnedToken: 0,
            totalBNBToDev: 0
        });
        poolInfo.push(p);
        emit PoolAdded(poolInfo.length - 1, lpToken, t0, t1);

        _trySetPair(t0);
        _trySetPair(t1);
    }

    function addPools(address[] calldata lpTokens) external onlyOwner {
        require(lpTokens.length > 0, "Empty");
        uint256 start = poolInfo.length;
        for (uint i = 0; i < lpTokens.length; i++) {
            addPool(lpTokens[i]);
        }
        emit PoolsAdded(start, lpTokens.length);
    }

    function updatePool(
        uint256 pid,
        address newLpToken,
        bool newActive
    ) external onlyOwner {
        require(pid < poolInfo.length, "Invalid pid");
        require(newLpToken != address(0), "Zero LP address");

        IPancakePair pair = IPancakePair(newLpToken);

        address t0 = pair.token0();
        address t1 = pair.token1();

        PoolInfo storage pool = poolInfo[pid];

        // update the LP token & its metadata
        pool.lpToken = IERC20(newLpToken);
        pool.token0 = t0;
        pool.token1 = t1;
        pool.active = newActive;

        // update price pair mapping safely
        _trySetPair(t0);
        _trySetPair(t1);

        emit PoolUpdated(pid, newLpToken, t0, t1, newActive);
    }

    function setPoolActive(uint256 pid, bool active) external onlyOwner {
        require(pid < poolInfo.length, "Invalid pid");
        poolInfo[pid].active = active;
    }

    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "Zero");
        pancakeRouter = IPancakeRouter(_router);
    }

    function setDevWallet(address _dev) external onlyOwner {
        devWallet = _dev;
    }

    function setBurnAddress(address _burn) external onlyOwner {
        burnAddress = _burn;
    }

    function setStakingFee(uint256 newAmount) external onlyOwner {
        require(newAmount <= 2000, "Max 20%");
        stakingFee = newAmount;
    }

    function setEarlyUnstake(uint256 newAmount) external onlyOwner {
        require(newAmount <= 5000, "Max 50%");
        earlyUnstake = newAmount;
    }

    function setEarlyUnstakeEnabled(bool enabled) external onlyOwner {
        earlyUnstakeEnabled = enabled;
        emit EarlyUnstakeEnabledUpdated(enabled);
    }
    function setReferralStakePercent(uint256 newPercent) external onlyOwner {
        require(newPercent <= 20, "Cannot exceed 20%");
        referralStakePercent = newPercent;
    }

    function setReferralClaimPercent(uint256 newPercent) external onlyOwner {
        require(newPercent <= 20, "Cannot exceed 20%");
        referralClaimPercent = newPercent;
    }

    function setMinStakeUSD(uint256 _min) external onlyOwner {
        minStakeUSD = _min;
    }

    function setClaimInterval(uint256 seconds_) external onlyOwner {
        require(seconds_ >= 1 hours && seconds_ <= 7 days, "Invalid interval");
        claimInterval = seconds_;
        emit ClaimIntervalUpdated(seconds_);
    }

    function setLockSeconds(uint256 _lockSeconds) external onlyOwner {
        lockSeconds = _lockSeconds;
    }

    function addPlan(uint256 minUSD, uint256 monthlyRate) external onlyOwner {
        require(minUSD > 0, "minUSD must be > 0");
        require(monthlyRate > 0, "rate must be > 0");
        plans.push(Plan({minUSD: minUSD, monthlyRate: monthlyRate}));
    }

    function setPlans(Plan[] calldata newPlans) external onlyOwner {
        delete plans;
        for (uint i = 0; i < newPlans.length; i++) {
            plans.push(newPlans[i]);
        }
    }

    function updatePlan(
        uint256 planId,
        uint256 minUSD,
        uint256 monthlyRate
    ) external onlyOwner {
        require(planId < plans.length, "Invalid planId");
        plans[planId].minUSD = minUSD;
        plans[planId].monthlyRate = monthlyRate;
    }
    function getPoolByLP(
        address lpToken
    )
        external
        view
        returns (
            uint256 pid,
            address lp,
            address token0,
            address token1,
            bool active
        )
    {
        require(lpToken != address(0), "Zero address");

        uint256 len = poolInfo.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(poolInfo[i].lpToken) == lpToken) {
                IPancakePair pair = IPancakePair(lpToken);
                return (
                    i,
                    lpToken,
                    pair.token0(),
                    pair.token1(),
                    poolInfo[i].active
                );
            }
        }

        revert("Pool not found");
    }

    function setRewardToken(address _reward) external onlyOwner {
        require(_reward != address(0), "Zero");
        address previous = address(rewardToken);
        rewardToken = IERC20(_reward);
        emit RewardTokenUpdated(previous, _reward);
    }

    function topUpReward(uint256 amount) external onlyOwner {
        require(address(rewardToken) != address(0), "No reward token");
        IERC20(address(rewardToken)).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    function topUpAnyReward(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Zero");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function topUpHUG(uint256 amount) external onlyOwner {
        IERC20(address(HUG)).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
    }

    function recoverERC20(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    /* ========================= Price helpers ========================= */

    function _trySetPair(address token) internal {
        if (token == address(0) || token == BUSD) return;
        if (tokenPairs[token] != address(0)) return;

        address pair = pancakeFactory.getPair(token, WBNB);
        if (pair == address(0)) {
            pair = pancakeFactory.getPair(token, BUSD);
            if (pair == address(0)) {
                pair = pancakeFactory.getPair(token, address(KIND));
            }
        }
        if (pair != address(0)) tokenPairs[token] = pair;
    }

    function updatePair(address token) external onlyOwner {
        _trySetPair(token);
    }

    // returns price scaled by 1e18 USD per token
    function _getTokenPriceUSD(
        address token
    ) internal view returns (uint256 priceUSD) {
        if (token == BUSD) return 1e18;
        address pairAddr = tokenPairs[token];
        require(pairAddr != address(0), "Pair not set for token");

        IPancakePair pair = IPancakePair(pairAddr);
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        address t0 = pair.token0();
        address t1 = pair.token1();
        require(r0 > 0 && r1 > 0, "Invalid pair reserves");

        uint256 tokenPerPair = token == t0
            ? (uint256(r1) * 1e18) / uint256(r0)
            : (uint256(r0) * 1e18) / uint256(r1);
        address otherToken = token == t0 ? t1 : t0;

        if (otherToken == BUSD) {
            return tokenPerPair;
        } else if (otherToken == WBNB) {
            address wbnbPairAddr = tokenPairs[WBNB];
            require(wbnbPairAddr != address(0), "WBNB pair not set");
            IPancakePair wbnbPair = IPancakePair(wbnbPairAddr);
            (uint112 rw0, uint112 rw1, ) = wbnbPair.getReserves();
            address t0w = wbnbPair.token0();
            require(rw0 > 0 && rw1 > 0, "Invalid WBNB pair reserves");
            uint256 wbnbUSD = WBNB == t0w
                ? (uint256(rw1) * 1e18) / uint256(rw0)
                : (uint256(rw0) * 1e18) / uint256(rw1);
            return (tokenPerPair * wbnbUSD) / 1e18;
        } else if (otherToken == address(KIND)) {
            uint256 kindUSD = _getTokenPriceUSD(address(KIND));
            return (tokenPerPair * kindUSD) / 1e18;
        }

        revert("Cannot determine token price");
    }

    function _lpValueUSD(
        address lpPair,
        uint256 lpAmount
    ) internal view returns (uint256 usdValue) {
        IPancakePair pair = IPancakePair(lpPair);
        (uint112 r0, uint112 r1, ) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();
        if (totalSupply == 0) return 0;

        address t0 = pair.token0();
        address t1 = pair.token1();

        uint256 p0 = (tokenPairs[t0] == address(0)) ? 0 : _getTokenPriceUSD(t0);
        uint256 p1 = (tokenPairs[t1] == address(0)) ? 0 : _getTokenPriceUSD(t1);

        if (p0 == 0 && t0 == address(KIND))
            p0 = _getTokenPriceUSD(address(KIND));
        if (p1 == 0 && t1 == address(KIND))
            p1 = _getTokenPriceUSD(address(KIND));

        uint256 value0 = p0 > 0 ? (uint256(r0) * p0) / 1e18 : 0;
        uint256 value1 = p1 > 0 ? (uint256(r1) * p1) / 1e18 : 0;
        uint256 totalPoolUSD = value0 + value1;
        if (totalPoolUSD == 0) return 0;

        usdValue = (totalPoolUSD * lpAmount) / totalSupply;
    }

    /* ============================ Internal helpers ============================ */

    function _createPosition(
        address user,
        uint256 pid,
        uint8 planId,
        uint256 netLP,
        uint256 stakeUSD
    ) internal returns (uint256 positionId) {
        positionCounter++;
        positionId = positionCounter;

        positions[positionId] = Position({
            user: user,
            pid: pid,
            lpAmount: netLP,
            planId: planId,
            stakeUSD: stakeUSD,
            startTime: block.timestamp,
            endTime: block.timestamp + lockSeconds,
            closed: false,
            lastClaimTime: block.timestamp,
            endTimeAtClose: 0
        });

        positionsOfUser[user].push(positionId);
    }

    function _handleReferral(address user, uint256 stakeUSD) internal {
        address ref = referrerOf[user];
        if (ref == address(0)) return;

        uint256 bonusUSD = (stakeUSD * referralStakePercent) / 100;
        uint256 rPrice = _getTokenPriceUSD(address(rewardToken));
        if (rPrice == 0) return;

        uint256 rewardAmount = (bonusUSD * 1e18) / rPrice;
        if (
            rewardAmount > 0 &&
            IERC20(address(rewardToken)).balanceOf(address(this)) >=
            rewardAmount
        ) {
            IERC20(address(rewardToken)).safeTransfer(ref, rewardAmount);
            referralEarnings[ref] += rewardAmount;
            emit ReferralStakeBonus(ref, user, bonusUSD, rewardAmount);
        }
    }

    /* ============================ Staking Logic ============================ */

    function stake(
        uint256 pid,
        uint256 amount,
        uint8 planId,
        address ref
    ) external whenNotPaused nonReentrant {
        require(pid < poolInfo.length, "Invalid pool");
        PoolInfo storage pool = poolInfo[pid];
        require(pool.active, "Pool inactive");
        require(amount > 0, "Zero amount");
        require(planId < plans.length, "Invalid plan");

        uint256 stakeUSD = _lpValueUSD(address(pool.lpToken), amount);
        require(stakeUSD >= plans[planId].minUSD, "Below plan minimum");
        require(stakeUSD >= minStakeUSD, "Stake too small");

        // Transfer LP
        pool.lpToken.safeTransferFrom(msg.sender, address(this), amount);

        // Staking fee
        uint256 feeLP = (amount * stakingFee) / 10000;
        uint256 netLP = amount - feeLP;

        if (feeLP > 0) {
            _processStakeFee(address(pool.lpToken), feeLP, pid);
        }

        // Register referrer on first stake
        if (
            referrerOf[msg.sender] == address(0) &&
            ref != address(0) &&
            ref != msg.sender &&
            positionsOfUser[ref].length > 0
        ) {
            referrerOf[msg.sender] = ref;
            emit ReferralRegistered(msg.sender, ref);
        }

        // Create position
        uint256 positionId = _createPosition(
            msg.sender,
            pid,
            planId,
            netLP,
            stakeUSD
        );

        pool.totalStakedLP += netLP;

        // Referral bonus (5% in rewardToken)
        _handleReferral(msg.sender, stakeUSD);

        emit Staked(msg.sender, positionId, pid, planId, netLP, stakeUSD);
    }

    // 5% stake fee: BNB-side -> dev, token-side -> burn
    function _processStakeFee(
        address lpPair,
        uint256 feeLP,
        uint256 pid
    ) internal {
        IERC20(lpPair).approve(address(pancakeRouter), 0);
        IERC20(lpPair).approve(address(pancakeRouter), feeLP);

        IPancakePair pair = IPancakePair(lpPair);
        address t0 = pair.token0();
        address t1 = pair.token1();

        (uint256 amountA, uint256 amountB) = pancakeRouter.removeLiquidity(
            t0,
            t1,
            feeLP,
            0,
            0,
            address(this),
            block.timestamp + 600
        );

        PoolInfo storage pool = poolInfo[pid];

        if (t0 == WBNB || t1 == WBNB) {
            uint256 wbnbAmt = t0 == WBNB ? amountA : amountB;
            uint256 tokenAmt = t0 == WBNB ? amountB : amountA;
            address tokenAddr = t0 == WBNB ? t1 : t0;

            if (wbnbAmt > 0 && devWallet != address(0)) {
                IERC20(WBNB).transfer(devWallet, wbnbAmt);
                pool.totalBNBToDev += wbnbAmt;
            }
            if (tokenAmt > 0) {
                IERC20(tokenAddr).transfer(burnAddress, tokenAmt);
                pool.totalBurnedToken += tokenAmt;
            }
        } else {
            if (amountA > 0 && devWallet != address(0)) {
                IERC20(t0).transfer(devWallet, amountA);
                pool.totalBNBToDev += amountA;
            }
            if (amountB > 0) {
                IERC20(t1).transfer(burnAddress, amountB);
                pool.totalBurnedToken += amountB;
            }
        }
    }

    // Claim HUG/rewardToken rewards
    function claim(uint256 positionId) public nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.user == msg.sender, "Not owner");
        require(
            block.timestamp >= pos.lastClaimTime + claimInterval,
            "Claim interval active"
        );

        (uint256 usdPaid, uint256 rewardPaid) = _processClaim(positionId);
        require(usdPaid > 0, "Nothing to claim");

        pos.lastClaimTime = block.timestamp;

        // 2% referral bonus on claimed rewards
        address ref = referrerOf[msg.sender];
        if (ref != address(0) && rewardPaid > 0) {
            uint256 refAmount = (rewardPaid * referralClaimPercent) / 100;
            if (
                refAmount > 0 &&
                IERC20(address(rewardToken)).balanceOf(address(this)) >=
                refAmount
            ) {
                IERC20(address(rewardToken)).safeTransfer(ref, refAmount);
                referralEarnings[ref] += refAmount;
                emit ReferralClaimBonus(ref, msg.sender, refAmount);
            }
        }

        emit Claimed(msg.sender, positionId, usdPaid, rewardPaid);
    }

    // rewards from lastClaimTime until now (or unstake time if closed)
    function _processClaim(
        uint256 positionId
    ) internal returns (uint256 usdToPay, uint256 rewardAmount) {
        Position storage pos = positions[positionId];
        require(pos.user != address(0), "No position");

        uint256 endTimestamp = pos.closed
            ? pos.endTimeAtClose
            : block.timestamp;

        if (endTimestamp <= pos.lastClaimTime) return (0, 0);

        uint256 elapsed = endTimestamp - pos.lastClaimTime;

        Plan memory plan = plans[pos.planId];

        // reward in USD (scaled 1e18)
        usdToPay =
            (pos.stakeUSD * plan.monthlyRate * elapsed) /
            (monthSeconds * 10000);

        if (usdToPay == 0) return (0, 0);

        uint256 rPrice = _getTokenPriceUSD(address(rewardToken));
        require(rPrice > 0, "Reward price unavailable");

        rewardAmount = (usdToPay * 1e18) / rPrice;

        if (rewardAmount > 0) {
            require(
                IERC20(address(rewardToken)).balanceOf(address(this)) >=
                    rewardAmount,
                "Insufficient rewards"
            );
            IERC20(address(rewardToken)).safeTransfer(pos.user, rewardAmount);
        }
    }

    // Unstake LP (with optional early-unstake penalty)
    function unstake(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(!pos.closed, "Closed");
        require(pos.user == msg.sender, "Not owner");

        PoolInfo storage pool = poolInfo[pos.pid];
        bool early = block.timestamp < pos.endTime;
        uint256 lpFeeProcessed = 0;
        uint256 lpReturn = pos.lpAmount;

        if (early) {
            require(earlyUnstakeEnabled, "Early unstake disabled");
            uint256 feeLP = (pos.lpAmount * earlyUnstake) / 10000;
            lpFeeProcessed = feeLP;
            lpReturn = pos.lpAmount - feeLP;

            if (feeLP > 0) {
                _processEarlyUnstakeFee(address(pool.lpToken), feeLP, pos.pid);
            }
        }

        // reduce totalStakedLP by full amount
        if (pool.totalStakedLP >= pos.lpAmount)
            pool.totalStakedLP -= pos.lpAmount;
        else pool.totalStakedLP = 0;

        // transfer remaining LP back
        pool.lpToken.safeTransfer(msg.sender, lpReturn);

        pos.closed = true;
        pos.endTimeAtClose = block.timestamp;

        emit Unstaked(msg.sender, positionId, lpReturn, early, lpFeeProcessed);
    }

    // Early-unstake fee:
    // - WBNB side -> dev
    // - token side -> 100% burn (no redistribution)
    function _processEarlyUnstakeFee(
        address lpPair,
        uint256 feeLP,
        uint256 pid
    ) internal {
        IERC20(lpPair).approve(address(pancakeRouter), 0);
        IERC20(lpPair).approve(address(pancakeRouter), feeLP);

        IPancakePair pair = IPancakePair(lpPair);
        address t0 = pair.token0();
        address t1 = pair.token1();

        (uint256 amountA, uint256 amountB) = pancakeRouter.removeLiquidity(
            t0,
            t1,
            feeLP,
            0,
            0,
            address(this),
            block.timestamp + 600
        );

        PoolInfo storage pool = poolInfo[pid];

        if (t0 == WBNB || t1 == WBNB) {
            uint256 wbnbAmt = (t0 == WBNB) ? amountA : amountB;
            uint256 tokenAmt = (t0 == WBNB) ? amountB : amountA;
            address tokenAddr = (t0 == WBNB) ? t1 : t0;

            if (wbnbAmt > 0 && devWallet != address(0)) {
                IERC20(WBNB).transfer(devWallet, wbnbAmt);
                pool.totalBNBToDev += wbnbAmt;
            }

            if (tokenAmt > 0) {
                IERC20(tokenAddr).transfer(burnAddress, tokenAmt);
                pool.totalBurnedToken += tokenAmt;
            }
        } else {
            // Non-WBNB LP: treat token0 as "BNB-side" (dev), token1 as burn
            if (amountA > 0 && devWallet != address(0)) {
                IERC20(t0).transfer(devWallet, amountA);
                pool.totalBNBToDev += amountA;
            }
            if (amountB > 0) {
                IERC20(t1).transfer(burnAddress, amountB);
                pool.totalBurnedToken += amountB;
            }
        }
    }

    /* ============================ Views ============================ */

    function getPlans() external view returns (Plan[] memory) {
        return plans;
    }

    function poolsLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function positionsOf(
        address user
    ) external view returns (uint256[] memory) {
        return positionsOfUser[user];
    }

    function positionInfo(
        uint256 id
    )
        external
        view
        returns (
            Position memory pos,
            uint256 claimableUSD,
            uint256 claimableReward
        )
    {
        pos = positions[id];
        if (pos.user == address(0)) return (pos, 0, 0);

        uint256 endTimestamp = pos.closed
            ? pos.endTimeAtClose
            : block.timestamp;

        if (endTimestamp <= pos.lastClaimTime) {
            return (pos, 0, 0);
        }

        uint256 elapsed = endTimestamp - pos.lastClaimTime;
        Plan memory plan = plans[pos.planId];

        claimableUSD =
            (pos.stakeUSD * plan.monthlyRate * elapsed) /
            (monthSeconds * 10000);

        uint256 rPrice = _getTokenPriceUSD(address(rewardToken));
        if (rPrice > 0) {
            claimableReward = (claimableUSD * 1e18) / rPrice;
        } else {
            claimableReward = 0;
        }
    }

    function lpValueUSD(
        uint256 pid,
        uint256 lpAmount
    ) external view returns (uint256) {
        require(pid < poolInfo.length, "Invalid pid");
        return _lpValueUSD(address(poolInfo[pid].lpToken), lpAmount);
    }

    function poolStats(
        uint256 pid
    )
        external
        view
        returns (
            uint256 totalStakedLP,
            uint256 totalStakedUSD,
            uint256 totalBurnedToken,
            uint256 totalBNBToDev
        )
    {
        require(pid < poolInfo.length, "Invalid pid");
        PoolInfo storage pool = poolInfo[pid];
        totalStakedLP = pool.totalStakedLP;
        totalStakedUSD = _lpValueUSD(address(pool.lpToken), pool.totalStakedLP);
        totalBurnedToken = pool.totalBurnedToken;
        totalBNBToDev = pool.totalBNBToDev;
    }
}
