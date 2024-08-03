// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract AllocationStaking is OwnableUpgradeable {
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. Current reward debt when user joined farm. See explanation below.
        // We do some fancy math here. Basically, any point in time, the amount of ERC20s
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accERC20PerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accERC20PerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
        uint256 tokensUnlockTime; // If user registered for sale, returns when tokens are getting unlocked
        address[] salesRegistered;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. ERC20s to distribute per block.
        uint256 lastRewardTimestamp; // Last timstamp that ERC20s distribution occurs.
        uint256 accERC20PerShare; // Accumulated ERC20s per share, times 1e36.
        uint256 totalDeposits; // Total amount of tokens deposited at the moment (staked)
    }

    // Address of the ERC20 Token contract.
    IERC20 public erc20;

    // The total amount of ERC20 that's paid out as reward.
    uint256 public paidOut;

    // ERC20 tokens rewarded per second.
    uint256 public rewardPerSecond;

    // Total rewards added to farm
    uint256 public totalRewards;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The timestamp when farming starts.
    uint256 public startTimestamp;

    // The timestamp when farming ends.
    uint256 public endTimestamp;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // Number of LP pools
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Fund the farm, increase the end block
    // TODO: add onlyOwner modifier
    function fund(uint256 _amount) public {
        require(block.timestamp < endTimestamp, "fund: too late, the farm is closed");
        erc20.transferFrom(address(msg.sender), address(this), _amount);
        endTimestamp += _amount / (rewardPerSecond);
        totalRewards = totalRewards += _amount;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    // TODO: 需要添加池子的限制，每种池子只允许创建一次
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        totalAllocPoint = totalAllocPoint += _allocPoint;

        // Push new PoolInfo
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accERC20PerShare: 0,
                totalDeposits: 0
            })
        );
    }

    // Update the given pool's ERC20 allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        // 更新指定池子的积分
        totalAllocPoint = totalAllocPoint += poolInfo[_pid].allocPoint += _allocPoint;

        // 重新赋值，更新当前池子的积分权重
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // 查询指定用户在某一个池子中的质押数量
    function deposited(uint256 _pid, address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        return user.amount;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // View function to see pending ERC20s for a user.
    function pending(uint256 _pid, address _user) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        // 每单位质押代币（LP token）自池子创建以来累积的奖励总量。
        uint256 accERC20PerShare = pool.accERC20PerShare;

        uint256 lpSupply = pool.totalDeposits;

        // 用户已经有质押 && 距离上次的结算时间又过了一段时间
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
            // 保证 lastTimestamp 最大不会超过活动结束时间
            uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;
            // 计算自上次分配以来的时间
            uint256 nrOfSeconds = lastTimestamp - pool.lastRewardTimestamp;
            // 时间 * 分配速率 * 该池子的积分 / 总积分 = 新产生的奖励
            uint256 erc20Reward = (nrOfSeconds * rewardPerSecond * pool.allocPoint) / totalAllocPoint;

            // 一段时间内产生的奖励 / 池子中总的质押代币数量 = 这段时间内每单位代币的累计奖励
            // 乘以用户当前质押的代币数量 = 用户当前可以获得未领取的奖励
            accERC20PerShare += (erc20Reward * 1e36) / lpSupply;
        }

        // 自上次交互以来的新增奖励
        return (user.amount * accERC20PerShare) / 1e36 - user.rewardDebt;
    }

    // View function for total reward the farm has yet to pay out.
    // NOTE: this is not necessarily the sum of all pending sums on all pools and users
    //      example 1: when tokens have been wiped by emergency withdraw
    //      example 2: when one pool has no LP supply
    function totalPending() external view returns (uint256) {
        // 还未产生任何收益
        if (block.timestamp <= startTimestamp) {
            return 0;
        }

        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;

        // 总共生成的奖励 - 已经发放的奖励
        return rewardPerSecond * (lastTimestamp - startTimestamp) - paidOut;
    }

    function updatePool(uint256 _pid) public {
        // 根据_pid找到某个池子的信息
        PoolInfo storage pool = poolInfo[_pid];

        // 时间的边界最晚只能到活动结束时间
        uint256 lastTimestamp = block.timestamp < endTimestamp ? block.timestamp : endTimestamp;

        // 不存在有效的时间区间
        if (lastTimestamp <= pool.lastRewardTimestamp) {
            lastTimestamp = pool.lastRewardTimestamp;
        }

        uint256 lpSupply = pool.totalDeposits;

        if (lpSupply == 0) {
            pool.lastRewardTimestamp = lastTimestamp;
            return;
        }

        uint256 nrOfSeconds = lastTimestamp -= (pool.lastRewardTimestamp);
        uint256 erc20Reward = (nrOfSeconds * rewardPerSecond * pool.allocPoint) / totalAllocPoint;

        // Update pool accERC20PerShare
        pool.accERC20PerShare = pool.accERC20PerShare + (erc20Reward * 1e36) / lpSupply;

        // Update pool lastRewardTimestamp
        pool.lastRewardTimestamp = lastTimestamp;
    }

    // Deposit LP tokens to Farm for ERC20 allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // 将代币数量用depositAmount变量保存起来
        uint256 depositAmount = _amount;

        // 根据 _pid 更新池子中的数据，质押合约支持多个池子，每个池子的代币都不相同
        updatePool(_pid);

        // 如果用户在当前池子中已经质押的代币, 需要将用户已经累积的奖励发送给用户
        if (user.amount > 0) {
            uint256 pendingAmount = (user.amount * pool.accERC20PerShare / 1e36) - user.rewardDebt;
            erc20Transfer(msg.sender, pendingAmount);
        }

        // 将用户的代币转移到这个stake合约中
        pool.lpToken.transferFrom(address(msg.sender), address(this), _amount);
        // 更新当前质押池子中的代币余额
        pool.totalDeposits += depositAmount;
        // Add deposit to user's amount
        user.amount += depositAmount;
        // Compute reward debt
        user.rewardDebt = user.amount * pool.accERC20PerShare / 1e36;
        // Emit relevant event
        emit Deposit(msg.sender, _pid, depositAmount);
    }

    // Withdraw LP tokens from Farm
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.tokensUnlockTime <= block.timestamp, "Last sale you registered for is not finished yet.");
        require(user.amount >= _amount, "withdraw: can't withdraw more than deposit");

        // Update pool
        updatePool(_pid);

        // 计算用户未对付的奖励
        uint256 pendingAmount = user.amount * pool.accERC20PerShare / 1e36 - user.rewardDebt;

        // 将用户未对付的奖励发送给用户
        erc20Transfer(msg.sender, pendingAmount);
        user.amount = user.amount -= _amount;

        // 重新更新用户未兑付的奖励
        user.rewardDebt = user.amount * pool.accERC20PerShare / 1e36;

        // Transfer withdrawal amount to user
        pool.lpToken.transfer(address(msg.sender), _amount);
        pool.totalDeposits = pool.totalDeposits - _amount;

        if (_amount > 0) {
            // Reset the tokens unlock time
            user.tokensUnlockTime = 0;
        }

        // Emit relevant event
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Transfer ERC20 and update the required ERC20 to payout all rewards
    function erc20Transfer(address _to, uint256 _amount) internal {
        erc20.transfer(_to, _amount);
        paidOut += _amount;
    }
}
