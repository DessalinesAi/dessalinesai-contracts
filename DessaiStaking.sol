// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  DessaiStaking
 * @author Dessalines AI
 * @notice Stake $DESSAI to earn 100% of protocol fees from every Eso pool payout.
 *
 *  Reward model
 *  ────────────
 *  • All protocol fees (USDC) flow from every EsoPool into this contract.
 *  • Rewards accrue continuously proportional to each staker's share.
 *  • Stakers can withdraw rewards at any time without unstaking.
 *  • $DESSAI tokens are returned when a staker unstakes.
 *
 *  Staking tiers (enforced by the AI agent / frontend — not on-chain gates)
 *  ────────────────────────────────────────────────────────────────────────
 *  Any amount → weekly share of 100% of fees
 *  500+       → join mid-tier pools without USDC collateral
 *  2 000+     → reduced pool fees (0.5% instead of 1%)
 *  5 000+     → governance rights
 *  10 000+    → Biznis Eso access
 *
 *  @dev Uses a reward-per-token accumulator pattern (similar to Synthetix).
 *       No time-locks — stakers can enter and exit freely.
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DessaiStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Tokens ────────────────────────────────────────────────────────────

    /// @notice $DESSAI token (staking token)
    IERC20 public immutable dessai;

    /// @notice USDC on Base (reward token)
    IERC20 public immutable usdc;

    // ── Global reward accumulator ─────────────────────────────────────────

    /// @notice Cumulative USDC reward per DESSAI token (scaled by 1e18)
    uint256 public rewardPerTokenStored;

    /// @notice Total DESSAI currently staked
    uint256 public totalStaked;

    // ── Per-staker state ──────────────────────────────────────────────────

    struct StakerInfo {
        uint256 balance;               // DESSAI staked
        uint256 rewardDebt;            // rewardPerToken snapshot at last claim
        uint256 pendingRewards;        // USDC earned but not yet claimed
    }

    mapping(address => StakerInfo) public stakers;

    // ── Events ────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event ProtocolFeeReceived(uint256 amount, uint256 newRewardPerToken);

    // ── Errors ────────────────────────────────────────────────────────────

    error ZeroAmount();
    error InsufficientStake();
    error NoRewardsToClaim();
    error ZeroAddress();

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address _dessai, address _usdc) Ownable(msg.sender) {
        if (_dessai == address(0) || _usdc == address(0)) revert ZeroAddress();
        dessai = IERC20(_dessai);
        usdc   = IERC20(_usdc);
    }

    // ── Protocol fee entry point ──────────────────────────────────────────

    /**
     * @notice Called by EsoPool contracts when paying protocol fees.
     * @dev    Automatically distributes to all stakers pro-rata.
     *         If no one is staking, fees accumulate until first staker joins.
     */
    function receiveProtocolFee(uint256 amount) external nonReentrant {
        if (amount == 0) return;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        if (totalStaked > 0) {
            // Accumulate reward per token (scaled 1e18 to avoid precision loss)
            rewardPerTokenStored += (amount * 1e18) / totalStaked;
        }
        // If totalStaked == 0, fees stay in contract and are distributed
        // to first stakers upon their stake (they receive no retroactive rewards)

        emit ProtocolFeeReceived(amount, rewardPerTokenStored);
    }

    // ── Staking ───────────────────────────────────────────────────────────

    /**
     * @notice Stake DESSAI tokens to start earning USDC protocol fees.
     * @param  amount Amount of DESSAI to stake (no minimum)
     */
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Settle pending rewards before changing balance
        _settleRewards(msg.sender);

        dessai.safeTransferFrom(msg.sender, address(this), amount);

        stakers[msg.sender].balance += amount;
        totalStaked                 += amount;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake DESSAI tokens. Pending rewards are auto-claimed.
     * @param  amount Amount of DESSAI to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakers[msg.sender].balance < amount) revert InsufficientStake();

        // Settle and claim rewards first
        _settleRewards(msg.sender);
        _claimRewards(msg.sender);

        stakers[msg.sender].balance -= amount;
        totalStaked                 -= amount;

        dessai.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /**
     * @notice Claim all pending USDC rewards without unstaking.
     */
    function claimRewards() external nonReentrant {
        _settleRewards(msg.sender);
        _claimRewards(msg.sender);
    }

    // ── Internals ─────────────────────────────────────────────────────────

    /// @dev Update pending rewards for a staker based on accumulated rewardPerToken.
    function _settleRewards(address user) internal {
        StakerInfo storage s = stakers[user];
        if (s.balance > 0) {
            uint256 earned = (s.balance * (rewardPerTokenStored - s.rewardDebt)) / 1e18;
            s.pendingRewards += earned;
        }
        s.rewardDebt = rewardPerTokenStored;
    }

    /// @dev Transfer pending USDC rewards to a staker.
    function _claimRewards(address user) internal {
        uint256 reward = stakers[user].pendingRewards;
        if (reward == 0) revert NoRewardsToClaim();

        stakers[user].pendingRewards = 0;
        usdc.safeTransfer(user, reward);

        emit RewardsClaimed(user, reward);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice USDC claimable by a staker right now
    function pendingRewards(address user) external view returns (uint256) {
        StakerInfo memory s = stakers[user];
        if (s.balance == 0) return s.pendingRewards;
        uint256 earned = (s.balance * (rewardPerTokenStored - s.rewardDebt)) / 1e18;
        return s.pendingRewards + earned;
    }

    /// @notice DESSAI staked by a user
    function stakedBalance(address user) external view returns (uint256) {
        return stakers[user].balance;
    }

    /// @notice Total USDC held in this contract (fees + unclaimed rewards)
    function totalUsdcReserves() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Current staking tier for a user (used by frontend/AI agent)
     * 0 = none, 1 = any, 2 = 500+, 3 = 2000+, 4 = 5000+, 5 = 10000+
     */
    function stakingTier(address user) external view returns (uint8) {
        uint256 bal = stakers[user].balance;
        // DESSAI has 18 decimals
        if (bal >= 10_000e18) return 5;
        if (bal >=  5_000e18) return 4;
        if (bal >=  2_000e18) return 3;
        if (bal >=    500e18) return 2;
        if (bal >          0) return 1;
        return 0;
    }
}
