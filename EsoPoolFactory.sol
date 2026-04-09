// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  EsoPoolFactory
 * @author Dessalines AI
 * @notice Deploys and tracks individual EsoPool contracts.
 *
 *  Anyone can create a pool. The factory keeps a registry of all pools
 *  and acts as the admin for emergency cancellations.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EsoPool} from "./EsoPool.sol";

contract EsoPoolFactory is Ownable {

    // ── Constants ─────────────────────────────────────────────────────────

    /// @dev USDC on Base mainnet
    address public constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Default protocol fee: 1%
    uint16  public constant DEFAULT_FEE_BPS = 100;

    // ── State ─────────────────────────────────────────────────────────────

    /// @notice DessaiStaking contract — receives all protocol fees
    address public protocolFeeRecipient;

    /// @notice All pools ever created
    address[] public allPools;

    /// @notice Pools created by a specific address
    mapping(address => address[]) public poolsByCreator;

    /// @notice True if address is a valid pool deployed by this factory
    mapping(address => bool) public isPool;

    // ── Events ────────────────────────────────────────────────────────────

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        string  poolName,
        uint256 contributionAmount,
        uint8   maxMembers,
        uint256 roundDuration
    );
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    // ── Errors ────────────────────────────────────────────────────────────

    error ZeroAddress();
    error InvalidParameters();

    // ── Constructor ───────────────────────────────────────────────────────

    constructor(address _protocolFeeRecipient) Ownable(msg.sender) {
        if (_protocolFeeRecipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = _protocolFeeRecipient;
    }

    // ── Create pool ───────────────────────────────────────────────────────

    /**
     * @notice Deploy a new EsoPool.
     *
     * @param poolName            Human-readable name (e.g. "Pool Ayiti Diaspora")
     * @param contributionAmount  USDC per member per round in 6-decimal units
     *                            (e.g. 50_000_000 = $50 USDC)
     * @param maxMembers          Number of members (3–50)
     * @param roundDurationDays   Round length in days (7 / 14 / 30)
     * @param contributionDays    Days to contribute within each round (< roundDurationDays)
     *
     * @return pool Address of the newly deployed EsoPool
     */
    function createPool(
        string  calldata poolName,
        uint256 contributionAmount,
        uint8   maxMembers,
        uint8   roundDurationDays,
        uint8   contributionDays
    ) external returns (address pool) {
        if (maxMembers < 3 || maxMembers > 50)           revert InvalidParameters();
        if (contributionAmount < 10e6)                   revert InvalidParameters(); // min $10
        if (roundDurationDays < 7)                       revert InvalidParameters(); // min 1 week
        if (contributionDays >= roundDurationDays)       revert InvalidParameters();
        if (bytes(poolName).length == 0)                 revert InvalidParameters();

        uint256 roundDuration        = uint256(roundDurationDays) * 1 days;
        uint256 contributionWindow   = uint256(contributionDays)  * 1 days;

        EsoPool newPool = new EsoPool(
            msg.sender,             // creator
            USDC_BASE,              // usdc
            protocolFeeRecipient,   // fee recipient
            contributionAmount,
            maxMembers,
            roundDuration,
            contributionWindow,
            DEFAULT_FEE_BPS,
            poolName
        );

        pool = address(newPool);
        allPools.push(pool);
        poolsByCreator[msg.sender].push(pool);
        isPool[pool] = true;

        emit PoolCreated(
            pool,
            msg.sender,
            poolName,
            contributionAmount,
            maxMembers,
            roundDuration
        );
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    /// @notice Update the staking contract that receives protocol fees.
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(protocolFeeRecipient, newRecipient);
        protocolFeeRecipient = newRecipient;
    }

    /// @notice Emergency cancel a specific pool (admin only).
    function emergencyCancel(address pool, string calldata reason) external onlyOwner {
        require(isPool[pool], "Not a valid pool");
        EsoPool(pool).emergencyCancel(reason);
    }

    // ── Views ─────────────────────────────────────────────────────────────

    /// @notice Total number of pools ever created
    function totalPools() external view returns (uint256) {
        return allPools.length;
    }

    /// @notice All pools created by a specific wallet
    function getPoolsByCreator(address creator) external view returns (address[] memory) {
        return poolsByCreator[creator];
    }

    /**
     * @notice Get pool data for a range of pools (for frontend pagination).
     * @param  start  Start index (inclusive)
     * @param  end    End index (exclusive)
     */
    function getPools(uint256 start, uint256 end)
        external
        view
        returns (address[] memory)
    {
        require(end <= allPools.length && start < end, "Invalid range");
        address[] memory result = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = allPools[i];
        }
        return result;
    }
}
