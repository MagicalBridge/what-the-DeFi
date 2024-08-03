// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "./interface/IERC20.sol";
// import "./token/ERC20.sol";
// import "./interface/IMaxStake.sol";
// import "./utils/ReentrancyGuard.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MaxStake is AccessControlUpgradeable {
    //奖励代币
    IERC20 public ierc20B2;
    // 活动结束时间
    uint256 public endTimeStamp;
    // 总的奖励金额
    uint256 public totalRewards;
    // 每秒奖励的数量
    uint256 public rewardPerSecond;
    // 活动开始时间
    uint256 public startTimeStamp;
    // 总分配的点数
    uint256 public totalAllocPoint;
    // 提取功能的状态
    bool public claimPaused;

    // 拥有人
    address private _owner;
    // 用户在流动性池子里面的存款
    mapping(uint256 => mapping(address => User)) userInfo;

    struct Pool {
        // 代币的Token地址
        address stTokenAddress;
        // 质押权重
        uint256 poolWeight;
        // 最后一次计算奖励时间
        uint256 lastRewardBlock;
        // 每个代币奖励质押B2份额
        uint256 accB2PerST;
        // 池子中总的代币数量
        uint256 stTokenAmount;
        // 最小质押代币数量
        uint256 minDepositAmount;
        // 最小解除质押代币数量
        uint256 minUnstakeAmount;
        // 总借出代币数量
        uint256 lendingAmount;
        // 总借入代币数量
        uint256 borrowingAmount;
        // 总借出奖励数量
        uint256 lendingRewardAmount;
        // 总借入奖励数量
        uint256 borrowingRewardAmount;
    }

    // 是否已经在流动性池子中了
    mapping(address => bool) isAddedToPool;

    Pool[] public pools;

    struct User {
        // 用户质押的代币数量
        uint256 stAmount;
        // 用户已经分配的奖励代币数量
        uint256 finishedB2;
        // 用户待分配的奖励代币数量
        uint256 pendingB2;
        // tokenUnlockTime
        uint256 tokensUnlockTime;
        // registered sale users
        address[] salesRegistered;
    }

    // 更新对应的流动池
    event UpdatePool(uint256 idx, uint256 lastRewardBlock, uint256 reward);

    event Deposit(uint256 _pid, uint256 amount);

    constructor(uint256 _startTimeStamp) {
        startTimeStamp = _startTimeStamp;
        _owner = msg.sender;
    }

    // 校验是否属于所有人
    modifier onlyOwner() {
        require(_owner == msg.sender, "Invalid Operator");
        _;
    }

    // 校验claim没有暂停
    modifier claimUnPaused() {
        require(!claimPaused, "claim is Paused");
        _;
    }
    // 为池子注入B2资金(作为整体奖励)

    function fund(uint256 _amount) external onlyOwner {
        require(block.timestamp < endTimeStamp, "Time is too late");
        totalRewards += _amount;
        endTimeStamp += _amount / rewardPerSecond;
        // 将代币从ERC20合约转移到stakemax合约,需要提前授权
        ierc20B2.transferFrom(msg.sender, address(this), _amount);
    }

    // 为合约增加流动性提供者
    function add(
        address _tokenAddr,
        bool _withUpdate,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _minUnstakeAmount
    ) external onlyOwner {
        require(_tokenAddr != address(0), "Invalid token address");
        require(_poolWeight > 0, "Pool weight must be greater than zero");
        require(_minDepositAmount > 0, "Minimum deposit amount must be greater than zero");
        require(_minUnstakeAmount > 0, "Minimum unstake amount must be greater than zero");
        require(!isAddedToPool[_tokenAddr], "Token can only add once");

        if (_withUpdate) {
            //更新所有的流动性池子
            massUpdatePools();
        }

        // 保证奖励开始时间的公平性，新添加的池子以当前的时间点为起点或者活动的开始时间，取比较大的那个值
        uint256 _lastRewardBlock = block.timestamp > startTimeStamp ? block.timestamp : startTimeStamp;

        // 往流动性池子中增加一个流动性pool
        pools.push(
            Pool({
                stTokenAddress: _tokenAddr,
                poolWeight: _poolWeight,
                lastRewardBlock: _lastRewardBlock,
                accB2PerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                minUnstakeAmount: _minUnstakeAmount,
                lendingAmount: 0,
                borrowingAmount: 0,
                lendingRewardAmount: 0,
                borrowingRewardAmount: 0
            })
        );
        // 总的分配点数增加
        totalAllocPoint += _poolWeight;

        //同一种类型的代币只允许添加一次
        isAddedToPool[_tokenAddr] = true;
    }

    // 更新所有的流动性池子
    function massUpdatePools() internal {
        for (uint256 i = 0; i < pools.length; ++i) {
            updatePool(i);
        }
    }

    function updatePool(uint256 idx) internal {
        Pool storage pool = pools[idx];

        // 活动结束的时间是刚性确定的，活动结束之后不再计算新的奖励
        uint256 lastTime = block.timestamp < endTimeStamp ? block.timestamp : endTimeStamp;

        // 奖励是用过时间线进行线性释放的，lastTime <= pool.lastRewardBlock 之后的运算没有意义
        if (lastTime <= pool.lastRewardBlock) {
            return;
        }

        // 获取代币的总的数量
        uint256 totalSupply = pool.stTokenAmount;

        if (totalSupply == 0) {
            // 如果池子中代币为空，则只更新最后计算时间，不需要计算奖励
            pool.lastRewardBlock = lastTime;
            return;
        }
        // 计算持续时间
        // 时间差：从上次计算奖励的时间到当前时间这段时间内池子中的质押代币可以获得奖励。
        uint256 effectTime = lastTime - pool.lastRewardBlock;
        uint256 accB2PerST = pool.accB2PerST;

        // 奖励速率 * 持续时间 * 权重 / 总分配点数
        uint256 reward = (rewardPerSecond * (effectTime) * (pool.poolWeight)) / (totalAllocPoint);
        accB2PerST = accB2PerST + ((reward * (1e36)) / (totalSupply));

        //
        pool.accB2PerST = accB2PerST;
        pool.lastRewardBlock = block.timestamp;
        emit UpdatePool(idx, pool.lastRewardBlock, reward);
    }

    // 质押
    function deposit(uint256 _pid, uint256 amount) external claimUnPaused {
        require(block.timestamp < endTimeStamp, "time is over");

        Pool storage pool = pools[_pid];

        require(amount >= pool.minDepositAmount, "amount less than limit");

        User storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        if (user.stAmount > 0) {
            // 先取出奖励池子里面的奖励，给到质押者
            uint256 reward = pending(_pid, msg.sender);

            user.finishedB2 += reward;
            user.pendingB2 = 0;
            ierc20B2.transfer(msg.sender, reward);
        } else {
            user.pendingB2 = (user.stAmount * (pool.accB2PerST)) / (1e36) - user.finishedB2;
        }

        user.stAmount = user.stAmount + amount;
        pool.stTokenAmount += amount;

        IERC20(pool.stTokenAddress).transferFrom(msg.sender, address(this), amount);

        emit Deposit(_pid, amount);
    }

    function pending(uint256 _pid, address _user) internal view returns (uint256) {
        User storage user = userInfo[_pid][_user];
        Pool storage pool = pools[_pid];

        uint256 accB2PerST = pool.accB2PerST;
        uint256 totalSupply = pool.stTokenAmount;

        if (block.timestamp > pool.lastRewardBlock && totalSupply > 0) {
            uint256 lastTime = block.timestamp < endTimeStamp ? block.timestamp : endTimeStamp;
            uint256 compareLastRewardTime = pool.lastRewardBlock < endTimeStamp ? pool.lastRewardBlock : endTimeStamp;
            uint256 effectTime = lastTime - compareLastRewardTime;
            uint256 reward = (rewardPerSecond * effectTime * pool.poolWeight) / (totalAllocPoint);
            accB2PerST = accB2PerST + ((reward * (1e36)) / (totalSupply));
        }

        return (user.stAmount * (accB2PerST)) / (1e36) - (user.finishedB2);
    }
}
