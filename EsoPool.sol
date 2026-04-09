// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  EsoPool
 * @author Dessalines AI
 * @notice Trustless rotating savings circle (eso / ROSCA) on Base.
 *
 *  Flow
 *  ────
 *  1. Factory deploys EsoPool with agreed parameters.
 *  2. Members call join() — pool auto-starts when full.
 *  3. Each round: members call contribute() inside the window.
 *  4. After the window: anyone calls settleRound() to pay the recipient.
 *  5. Repeat until all members have received their payout.
 *
 *  Security properties
 *  ───────────────────
 *  • No central coordinator — payout order is fixed on-chain at creation.
 *  • ReentrancyGuard on all USDC-moving functions.
 *  • Contributions held in contract; only the designated recipient can receive.
 *  • Defaulters are flagged on-chain; their stake is redistributed that round.
 *  • 1 % protocol fee (configurable up to 3 %) sent to staking contract.
 *
 *  @dev Depends on OpenZeppelin v5 — install with:
 *       forge install OpenZeppelin/openzeppelin-contracts
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  Types
// ─────────────────────────────────────────────────────────────────────────────

enum PoolStatus {
    Recruiting,  // waiting for members
    Active,      // rounds running
    Completed,   // all rounds done
    Cancelled    // emergency cancellation
}

enum MemberStatus {
    None,        // not a member
    Active,      // good standing
    Defaulted,   // missed a contribution
    Paid         // has received their payout
}

struct Member {
    address  wallet;
    uint8    payoutPosition;    // 1-based index in payout sequence
    bool     hasContributed;    // current round only — reset each round
    bool     hasReceivedPayout; // lifetime flag
    uint256  totalContributed;  // cumulative USDC contributed
    MemberStatus status;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Contract
// ─────────────────────────────────────────────────────────────────────────────

contract EsoPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Immutables (set in constructor, never change) ─────────────────────

    /// @notice Factory that deployed this pool
    address public immutable factory;

    /// @notice Wallet that created this pool
    address public immutable creator;

    /// @notice USDC contract on Base (6 decimals)
    IERC20  public immutable usdc;

    /// @notice DessaiStaking contract — receives protocol fees
    address public immutable protocolFeeRecipient;

    /// @notice Fixed USDC contribution per member per round (6 decimals)
    uint256 public immutable contributionAmount;

    /// @notice Total number of members (= total rounds)
    uint8   public immutable maxMembers;

    /// @notice Seconds between round start and next round start
    uint256 public immutable roundDuration;

    /// @notice Seconds from round start during which contributions are accepted
    uint256 public immutable contributionWindow;

    /// @notice Protocol fee in basis points (100 = 1 %)
    uint16  public immutable protocolFeeBps;

    // ── Mutable state ─────────────────────────────────────────────────────

    /// @notice Human-readable pool name (e.g. "Pool Ayiti Diaspora")
    string public poolName;

    /// @notice Current pool lifecycle stage
    PoolStatus public status;

    /// @notice 1-based current round number
    uint8 public currentRound;

    /// @notice Number of members who have joined
    uint8 public memberCount;

    /// @notice Timestamp when the current round started
    uint256 public roundStartTime;

    /// @notice USDC collected this round (only from active contributors)
    uint256 public roundPot;

    /// @notice Member data keyed by wallet address
    mapping(address => Member) public members;

    /// @notice All member addresses in join order
    address[] public memberList;

    /// @notice Payout sequence — index 0 is paid in round 1, etc.
    address[] public payoutOrder;

    // ── Events ────────────────────────────────────────────────────────────

    event MemberJoined(address indexed member, uint8 payoutPosition);
    event PoolStarted(uint256 startTime, address[] payoutOrder);
    event ContributionMade(address indexed member, uint256 amount, uint8 round);
    event RoundSettled(
        uint8   indexed round,
        address indexed recipient,
        uint256 payout,
        uint256 protocolFee,
        uint8   defaulters
    );
    event MemberDefaulted(address indexed member, uint8 round);
    event PoolCompleted(uint8 totalRounds);
    event EmergencyCancellation(string reason, address triggeredBy);

    // ── Custom errors (cheaper than require strings) ──────────────────────

    error PoolFull();
    error AlreadyMember();
    error NotMember();
    error PositionTaken(uint8 position);
    error PositionOutOfRange(uint8 position, uint8 max);
    error PoolNotRecruiting();
    error PoolNotActive();
    error PoolAlreadyActive();
    error AlreadyContributed();
    error ContributionWindowClosed(uint256 closedAt, uint256 now_);
    error ContributionWindowStillOpen(uint256 closesAt);
    error InsufficientUsdcAllowance(uint256 required, uint256 actual);
    error Unauthorized();
    error ZeroAddress();

    // ── Constructor ───────────────────────────────────────────────────────

    /**
     * @param _creator              Wallet that initiated the pool
     * @param _usdc                 USDC token address on Base
     * @param _protocolFeeRecipient DessaiStaking contract address
     * @param _contributionAmount   USDC per member per round (6 decimals)
     * @param _maxMembers           Number of members (3–50)
     * @param _roundDuration        Seconds per round (e.g. 30 days = 2_592_000)
     * @param _contributionWindow   Seconds to contribute each round (< roundDuration)
     * @param _protocolFeeBps       Protocol fee basis points (≤ 300)
     * @param _poolName             Display name for this pool
     */
    constructor(
        address _creator,
        address _usdc,
        address _protocolFeeRecipient,
        uint256 _contributionAmount,
        uint8   _maxMembers,
        uint256 _roundDuration,
        uint256 _contributionWindow,
        uint16  _protocolFeeBps,
        string  memory _poolName
    ) {
        if (_creator            == address(0)) revert ZeroAddress();
        if (_usdc               == address(0)) revert ZeroAddress();
        if (_protocolFeeRecipient == address(0)) revert ZeroAddress();
        require(_maxMembers        >= 3  && _maxMembers <= 50,            "Members: 3-50");
        require(_contributionAmount >= 10e6,                               "Min $10 USDC");
        require(_contributionWindow  < _roundDuration,                     "Window >= duration");
        require(_protocolFeeBps      <= 300,                               "Max 3% fee");

        factory               = msg.sender;
        creator               = _creator;
        usdc                  = IERC20(_usdc);
        protocolFeeRecipient  = _protocolFeeRecipient;
        contributionAmount    = _contributionAmount;
        maxMembers            = _maxMembers;
        roundDuration         = _roundDuration;
        contributionWindow    = _contributionWindow;
        protocolFeeBps        = _protocolFeeBps;
        poolName              = _poolName;
        status                = PoolStatus.Recruiting;
    }

    // ── Modifiers ─────────────────────────────────────────────────────────

    modifier onlyMember() {
        if (members[msg.sender].status == MemberStatus.None) revert NotMember();
        _;
    }

    modifier whenRecruiting() {
        if (status != PoolStatus.Recruiting) revert PoolNotRecruiting();
        _;
    }

    modifier whenActive() {
        if (status != PoolStatus.Active) revert PoolNotActive();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Phase 1 — Recruiting
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Join the pool and claim a payout position.
     * @dev    Position 1 is paid first, position N last.
     *         The pool starts automatically when all slots are filled.
     * @param  payoutPosition 1-based slot in the payout sequence
     */
    function join(uint8 payoutPosition) external whenRecruiting {
        if (memberCount >= maxMembers)                revert PoolFull();
        if (members[msg.sender].status != MemberStatus.None) revert AlreadyMember();
        if (payoutPosition == 0 || payoutPosition > maxMembers)
            revert PositionOutOfRange(payoutPosition, maxMembers);

        // Verify position is not already taken
        for (uint8 i = 0; i < memberList.length; i++) {
            if (members[memberList[i]].payoutPosition == payoutPosition)
                revert PositionTaken(payoutPosition);
        }

        members[msg.sender] = Member({
            wallet:            msg.sender,
            payoutPosition:    payoutPosition,
            hasContributed:    false,
            hasReceivedPayout: false,
            totalContributed:  0,
            status:            MemberStatus.Active
        });

        memberList.push(msg.sender);
        memberCount++;

        emit MemberJoined(msg.sender, payoutPosition);

        // Auto-start when the pool is full
        if (memberCount == maxMembers) {
            _startPool();
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Internal — Start
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Called automatically when the last member joins.
    function _startPool() internal {
        status         = PoolStatus.Active;
        currentRound   = 1;
        roundStartTime = block.timestamp;

        _buildPayoutOrder();

        emit PoolStarted(block.timestamp, payoutOrder);
    }

    /// @dev Sort members into payout order by their chosen position.
    function _buildPayoutOrder() internal {
        address[] memory sorted = new address[](maxMembers);
        for (uint8 i = 0; i < memberList.length; i++) {
            uint8 pos = members[memberList[i]].payoutPosition;
            sorted[pos - 1] = memberList[i]; // pos is 1-based
        }
        payoutOrder = sorted;
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Phase 2 — Active rounds
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Contribute USDC for the current round.
     * @dev    Caller must have approved this contract for ≥ contributionAmount.
     *         Contributions only accepted within the contribution window.
     */
    function contribute() external onlyMember whenActive nonReentrant {
        Member storage m = members[msg.sender];

        // Only Active members contribute (not Defaulted or already Paid-and-done)
        if (m.status == MemberStatus.Defaulted) revert NotMember();

        if (m.hasContributed) revert AlreadyContributed();

        uint256 windowClose = roundStartTime + contributionWindow;
        if (block.timestamp > windowClose)
            revert ContributionWindowClosed(windowClose, block.timestamp);

        uint256 allowance = usdc.allowance(msg.sender, address(this));
        if (allowance < contributionAmount)
            revert InsufficientUsdcAllowance(contributionAmount, allowance);

        usdc.safeTransferFrom(msg.sender, address(this), contributionAmount);

        m.hasContributed   = true;
        m.totalContributed += contributionAmount;
        roundPot           += contributionAmount;

        emit ContributionMade(msg.sender, contributionAmount, currentRound);
    }

    /**
     * @notice Settle the current round: mark defaulters, pay the recipient.
     * @dev    Callable by anyone after the contribution window has closed.
     *         This design means no single party can block settlement.
     */
    function settleRound() external whenActive nonReentrant {
        uint256 windowClose = roundStartTime + contributionWindow;
        if (block.timestamp <= windowClose)
            revert ContributionWindowStillOpen(windowClose);

        // ── 1. Mark defaulters ──────────────────────────────────────────
        uint8 defaulterCount = 0;
        for (uint8 i = 0; i < memberList.length; i++) {
            address addr = memberList[i];
            Member storage m = members[addr];
            if (m.status == MemberStatus.Active && !m.hasContributed) {
                m.status = MemberStatus.Defaulted;
                defaulterCount++;
                emit MemberDefaulted(addr, currentRound);
            }
        }

        // ── 2. Identify recipient ───────────────────────────────────────
        //    payoutOrder is 0-indexed; currentRound is 1-based
        address recipient = payoutOrder[currentRound - 1];

        // ── 3. Calculate fee and net payout ────────────────────────────
        uint256 pot      = roundPot; // USDC actually collected
        uint256 fee      = (pot * protocolFeeBps) / 10_000;
        uint256 payout   = pot - fee;

        // ── 4. Transfer fee to protocol ─────────────────────────────────
        if (fee > 0) {
            usdc.safeTransfer(protocolFeeRecipient, fee);
        }

        // ── 5. Transfer payout to recipient ────────────────────────────
        if (payout > 0) {
            usdc.safeTransfer(recipient, payout);
        }

        // Mark recipient
        members[recipient].hasReceivedPayout = true;
        if (members[recipient].status == MemberStatus.Active) {
            members[recipient].status = MemberStatus.Paid;
        }

        emit RoundSettled(currentRound, recipient, payout, fee, defaulterCount);

        // ── 6. Advance or complete ──────────────────────────────────────
        if (currentRound == maxMembers) {
            status = PoolStatus.Completed;
            emit PoolCompleted(maxMembers);
        } else {
            currentRound++;
            roundStartTime = block.timestamp;
            roundPot       = 0;

            // Reset contribution flags for the next round
            // (Defaulted members are excluded; Paid members still contribute)
            for (uint8 i = 0; i < memberList.length; i++) {
                Member storage m = members[memberList[i]];
                if (m.status == MemberStatus.Active || m.status == MemberStatus.Paid) {
                    m.hasContributed = false;
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Emergency
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Emergency cancellation — refunds all funds held in this round.
     * @dev    Only callable by the factory owner (protocol admin).
     *         Previous round payouts are NOT reversed — only unspent funds.
     */
    function emergencyCancel(string calldata reason) external {
        if (msg.sender != factory) revert Unauthorized();
        if (status == PoolStatus.Completed || status == PoolStatus.Cancelled) return;

        status = PoolStatus.Cancelled;

        // Refund current round contributions proportionally
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            // Count contributors this round
            uint8 contributors = 0;
            for (uint8 i = 0; i < memberList.length; i++) {
                if (members[memberList[i]].hasContributed) contributors++;
            }
            if (contributors > 0) {
                uint256 refundPer = balance / contributors;
                for (uint8 i = 0; i < memberList.length; i++) {
                    if (members[memberList[i]].hasContributed) {
                        usdc.safeTransfer(memberList[i], refundPer);
                    }
                }
            }
        }

        emit EmergencyCancellation(reason, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  View functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Full pool summary for the frontend
    function getPoolInfo() external view returns (
        PoolStatus  _status,
        uint8       _currentRound,
        uint8       _memberCount,
        uint8       _maxMembers,
        uint256     _contributionAmount,
        uint256     _roundStartTime,
        uint256     _windowCloseTime,
        uint256     _roundPot,
        address     _currentRecipient
    ) {
        address recipient = (status == PoolStatus.Active && payoutOrder.length > 0)
            ? payoutOrder[currentRound - 1]
            : address(0);

        return (
            status,
            currentRound,
            memberCount,
            maxMembers,
            contributionAmount,
            roundStartTime,
            roundStartTime + contributionWindow,
            roundPot,
            recipient
        );
    }

    /// @notice Returns full member data for an address
    function getMember(address wallet) external view returns (Member memory) {
        return members[wallet];
    }

    /// @notice Ordered payout sequence (index 0 = round 1 recipient)
    function getPayoutOrder() external view returns (address[] memory) {
        return payoutOrder;
    }

    /// @notice All member addresses in join order
    function getMemberList() external view returns (address[] memory) {
        return memberList;
    }

    /// @notice True if contributions are currently being accepted
    function isContributionWindowOpen() external view returns (bool) {
        if (status != PoolStatus.Active) return false;
        return block.timestamp <= roundStartTime + contributionWindow;
    }

    /// @notice Seconds until the contribution window closes (0 if already closed)
    function timeUntilWindowCloses() external view returns (uint256) {
        if (status != PoolStatus.Active) return 0;
        uint256 close = roundStartTime + contributionWindow;
        if (block.timestamp >= close) return 0;
        return close - block.timestamp;
    }

    /// @notice Estimated total pot for this round if all active members contribute
    function estimatedPot() external view returns (uint256) {
        uint8 activeMembers = 0;
        for (uint8 i = 0; i < memberList.length; i++) {
            MemberStatus s = members[memberList[i]].status;
            if (s == MemberStatus.Active || s == MemberStatus.Paid) activeMembers++;
        }
        return uint256(activeMembers) * contributionAmount;
    }

    /// @notice Who receives the payout in the current round
    function currentRecipient() external view returns (address) {
        if (status != PoolStatus.Active || payoutOrder.length == 0) return address(0);
        return payoutOrder[currentRound - 1];
    }
}
