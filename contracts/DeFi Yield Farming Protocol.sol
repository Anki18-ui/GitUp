// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DeFi Yield Farming Protocol
 * @dev A decentralized yield farming protocol that allows users to stake tokens and earn rewards
 */
contract Project is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Struct to store user staking information
    struct UserInfo {
        uint256 amount;          // Amount of tokens staked
        uint256 rewardDebt;      // Reward debt for accurate reward calculation
        uint256 lastStakeTime;   // Timestamp of last stake
    }

    // Struct to store pool information
    struct PoolInfo {
        IERC20 stakingToken;     // Token to be staked
        IERC20 rewardToken;      // Token given as reward
        uint256 totalStaked;     // Total amount staked in pool
        uint256 rewardPerSecond; // Reward tokens per second
        uint256 lastRewardTime;  // Last time rewards were calculated
        uint256 accRewardPerShare; // Accumulated reward per share
        bool isActive;           // Pool status
    }

    // State variables
    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => bool) public authorizedTokens;
    
    uint256 public constant PRECISION = 1e12;
    uint256 public totalPools;

    // Events
    event PoolAdded(uint256 indexed pid, address stakingToken, address rewardToken, uint256 rewardPerSecond);
    event Staked(address indexed user, uint256 indexed pid, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolUpdated(uint256 indexed pid, uint256 rewardPerSecond);

    constructor() {}

    /**
     * @dev Core Function 1: Create a new staking pool
     * @param _stakingToken Address of token to be staked
     * @param _rewardToken Address of reward token
     * @param _rewardPerSecond Amount of reward tokens distributed per second
     */
    function createPool(
        IERC20 _stakingToken,
        IERC20 _rewardToken,
        uint256 _rewardPerSecond
    ) external onlyOwner {
        require(address(_stakingToken) != address(0), "Invalid staking token");
        require(address(_rewardToken) != address(0), "Invalid reward token");
        require(_rewardPerSecond > 0, "Reward per second must be positive");

        poolInfo.push(PoolInfo({
            stakingToken: _stakingToken,
            rewardToken: _rewardToken,
            totalStaked: 0,
            rewardPerSecond: _rewardPerSecond,
            lastRewardTime: block.timestamp,
            accRewardPerShare: 0,
            isActive: true
        }));

        totalPools++;
        authorizedTokens[address(_stakingToken)] = true;

        emit PoolAdded(totalPools - 1, address(_stakingToken), address(_rewardToken), _rewardPerSecond);
    }

    /**
     * @dev Core Function 2: Stake tokens in a specific pool
     * @param _pid Pool ID
     * @param _amount Amount of tokens to stake
     */
    function stakeTokens(uint256 _pid, uint256 _amount) external nonReentrant {
        require(_pid < totalPools, "Pool does not exist");
        require(_amount > 0, "Amount must be positive");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        require(pool.isActive, "Pool is not active");

        // Update pool rewards before staking
        updatePool(_pid);

        // If user already has stake, claim pending rewards
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare / PRECISION) - user.rewardDebt;
            if (pending > 0) {
                pool.rewardToken.safeTransfer(msg.sender, pending);
                emit RewardsClaimed(msg.sender, _pid, pending);
            }
        }

        // Transfer staking tokens from user
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Update user and pool information
        user.amount += _amount;
        user.lastStakeTime = block.timestamp;
        pool.totalStaked += _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / PRECISION;

        emit Staked(msg.sender, _pid, _amount);
    }

    /**
     * @dev Core Function 3: Unstake tokens and claim rewards
     * @param _pid Pool ID
     * @param _amount Amount of tokens to unstake
     */
    function unstakeTokens(uint256 _pid, uint256 _amount) external nonReentrant {
        require(_pid < totalPools, "Pool does not exist");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        require(user.amount >= _amount, "Insufficient staked amount");
        require(_amount > 0, "Amount must be positive");

        // Update pool rewards before unstaking
        updatePool(_pid);

        // Calculate and transfer pending rewards
        uint256 pending = (user.amount * pool.accRewardPerShare / PRECISION) - user.rewardDebt;
        if (pending > 0) {
            pool.rewardToken.safeTransfer(msg.sender, pending);
            emit RewardsClaimed(msg.sender, _pid, pending);
        }

        // Update user and pool information
        user.amount -= _amount;
        pool.totalStaked -= _amount;
        user.rewardDebt = user.amount * pool.accRewardPerShare / PRECISION;

        // Transfer staked tokens back to user
        pool.stakingToken.safeTransfer(msg.sender, _amount);

        emit Unstaked(msg.sender, _pid, _amount);
    }

    /**
     * @dev Update reward variables for a specific pool
     * @param _pid Pool ID
     */
    function updatePool(uint256 _pid) public {
        require(_pid < totalPools, "Pool does not exist");
        
        PoolInfo storage pool = poolInfo[_pid];
        
        if (block.timestamp <= pool.lastRewardTime || pool.totalStaked == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint256 timeElapsed = block.timestamp - pool.lastRewardTime;
        uint256 reward = timeElapsed * pool.rewardPerSecond;
        
        pool.accRewardPerShare += (reward * PRECISION) / pool.totalStaked;
        pool.lastRewardTime = block.timestamp;
    }

    /**
     * @dev Get pending rewards for a user in a specific pool
     * @param _pid Pool ID
     * @param _user User address
     * @return Pending reward amount
     */
    function getPendingRewards(uint256 _pid, address _user) external view returns (uint256) {
        require(_pid < totalPools, "Pool does not exist");
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        
        uint256 accRewardPerShare = pool.accRewardPerShare;
        
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - pool.lastRewardTime;
            uint256 reward = timeElapsed * pool.rewardPerSecond;
            accRewardPerShare += (reward * PRECISION) / pool.totalStaked;
        }
        
        return (user.amount * accRewardPerShare / PRECISION) - user.rewardDebt;
    }

    /**
     * @dev Update reward rate for a specific pool (Owner only)
     * @param _pid Pool ID
     * @param _rewardPerSecond New reward per second
     */
    function updateRewardRate(uint256 _pid, uint256 _rewardPerSecond) external onlyOwner {
        require(_pid < totalPools, "Pool does not exist");
        require(_rewardPerSecond > 0, "Reward per second must be positive");
        
        updatePool(_pid);
        poolInfo[_pid].rewardPerSecond = _rewardPerSecond;
        
        emit PoolUpdated(_pid, _rewardPerSecond);
    }

    /**
     * @dev Toggle pool active status (Owner only)
     * @param _pid Pool ID
     */
    function togglePoolStatus(uint256 _pid) external onlyOwner {
        require(_pid < totalPools, "Pool does not exist");
        poolInfo[_pid].isActive = !poolInfo[_pid].isActive;
    }

    /**
     * @dev Emergency withdraw function (Owner only)
     * @param _token Token address
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(IERC20 _token, uint256 _amount) external onlyOwner {
        _token.safeTransfer(owner(), _amount);
    }

    /**
     * @dev Get pool information
     * @param _pid Pool ID
     */
    function getPoolInfo(uint256 _pid) external view returns (
        address stakingToken,
        address rewardToken,
        uint256 totalStaked,
        uint256 rewardPerSecond,
        bool isActive
    ) {
        require(_pid < totalPools, "Pool does not exist");
        PoolInfo storage pool = poolInfo[_pid];
        
        return (
            address(pool.stakingToken),
            address(pool.rewardToken),
            pool.totalStaked,
            pool.rewardPerSecond,
            pool.isActive
        );
    }

    /**
     * @dev Get user staking information
     * @param _pid Pool ID
     * @param _user User address
     */
    function getUserInfo(uint256 _pid, address _user) external view returns (
        uint256 amount,
        uint256 lastStakeTime
    ) {
        require(_pid < totalPools, "Pool does not exist");
        UserInfo storage user = userInfo[_pid][_user];
        
        return (user.amount, user.lastStakeTime);
    }
}
