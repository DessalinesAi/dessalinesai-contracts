// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  ReputationRegistry
 * @author Dessalines AI
 * @notice On-chain reputation scores for Eso pool participants.
 *
 *  Score model
 *  ───────────
 *  Each wallet earns or loses points based on their pool behavior:
 *  +10  per round contributed on time
 *  +50  per pool completed successfully
 *  -30  per round defaulted
 *  -100 per pool abandoned mid-way
 *
 *  Scores are used by the AI agent and frontend to:
 *  • Gate access to higher-value pools
 *  • Display trust indicators to pool creators
 *  • Reduce required collateral for experienced members
 *
 *  @dev Only authorized EsoPool contracts (deployed by EsoPoolFactory) can
 *       write to this registry.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ReputationRegistry is Ownable {

    // ── Score constants ───────────────────────────────────────────────────

    int256 public constant POINTS_CONTRIBUTED   =  10;
    int256 public constant POINTS_POOL_COMPLETE =  50;
    int256 public constant POINTS_DEFAULTED     = -30;
    int256 public constant POINTS_ABANDONED     = -100;

    // ── State ─────────────────────────────────────────────────────────────

    /// @notice Reputation score per wallet (can go negative)
    mapping(address => int256) public scores;

    /// @notice Total pools completed per wallet
    mapping(address => uint256) public poolsCompleted;

    /// @notice Total rounds contributed on time per wallet
    mapping(address => uint256) public roundsContributed;

    /// @notice Defaults recorded per wallet
    mapping(address => uint256) public defaults;

    /// @notice Addresses authorized to write reputation data (EsoPool contracts)
    mapping(address => bool) public authorizedPools;

    /// @notice Factory address — can authorize new pools
    address public factory;

    // ── Events ────────────────────────────────────────────────────────────

    event ScoreUpdated(address indexed wallet, int256 delta, int256 newScore, string reason);
    event PoolAuthorized(address indexed pool);
    event FactoryUpdated(address indexed newFactory);

    // ── Errors ────────────────────────────────────────────────────────────

    error Unauthorized();
    error ZeroAddress();

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address _factory) Ownable(msg.sender) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = _factory;
    }

    // ── Authorization ─────────────────────────────────────────────────────

    /// @notice Called by factory when a new pool is deployed
    function authorizePool(address pool) external {
        if (msg.sender != factory && msg.sender != owner()) revert Unauthorized();
        authorizedPools[pool] = true;
        emit PoolAuthorized(pool);
    }

    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();
        factory = newFactory;
        emit FactoryUpdated(newFactory);
    }

    // ── Write functions (only authorized pools) ───────────────────────────

    modifier onlyAuthorized() {
        if (!authorizedPools[msg.sender]) revert Unauthorized();
        _;
    }

    function recordContribution(address wallet) external onlyAuthorized {
        scores[wallet]          += POINTS_CONTRIBUTED;
        roundsContributed[wallet]++;
        emit ScoreUpdated(wallet, POINTS_CONTRIBUTED, scores[wallet], "contribution");
    }

    function recordDefault(address wallet) external onlyAuthorized {
        scores[wallet] += POINTS_DEFAULTED;
        defaults[wallet]++;
        emit ScoreUpdated(wallet, POINTS_DEFAULTED, scores[wallet], "default");
    }

    function recordPoolComplete(address wallet) external onlyAuthorized {
        scores[wallet]       += POINTS_POOL_COMPLETE;
        poolsCompleted[wallet]++;
        emit ScoreUpdated(wallet, POINTS_POOL_COMPLETE, scores[wallet], "pool_complete");
    }

    function recordAbandonment(address wallet) external onlyAuthorized {
        scores[wallet] += POINTS_ABANDONED;
        emit ScoreUpdated(wallet, POINTS_ABANDONED, scores[wallet], "abandoned");
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Full reputation summary for a wallet
    function getReputation(address wallet) external view returns (
        int256  score,
        uint256 completed,
        uint256 contributed,
        uint256 defaultCount,
        uint8   tier
    ) {
        return (
            scores[wallet],
            poolsCompleted[wallet],
            roundsContributed[wallet],
            defaults[wallet],
            reputationTier(wallet)
        );
    }

    /**
     * @notice Reputation tier used by the AI agent to gate pool access.
     * 0 = New (no history)
     * 1 = Established (score > 0)
     * 2 = Trusted (score > 100, 2+ pools)
     * 3 = Verified (score > 300, 5+ pools)
     * 4 = Elite (score > 500, 10+ pools)
     */
    function reputationTier(address wallet) public view returns (uint8) {
        int256  s = scores[wallet];
        uint256 p = poolsCompleted[wallet];
        if (s > 500 && p >= 10) return 4;
        if (s > 300 && p >=  5) return 3;
        if (s > 100 && p >=  2) return 2;
        if (s >   0)            return 1;
        return 0;
    }

    /// @notice Whether a wallet meets the minimum reputation to join a pool
    function meetsMinimumReputation(address wallet, uint8 requiredTier)
        external
        view
        returns (bool)
    {
        return reputationTier(wallet) >= requiredTier;
    }
}
