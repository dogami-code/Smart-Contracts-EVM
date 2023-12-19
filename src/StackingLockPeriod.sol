// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";


contract StackingLockPeriod is Ownable, Pausable, ReentrancyGuard {

    /// @dev Emitted when tokens are staked.
    event TokensStaked(address indexed staker, uint256 amount);

    /// @dev Emitted when a tokens are withdrawn.
    event TokensWithdrawn(address indexed staker, uint256 amount);

    /// @dev Emitted when a staker claims staking rewards.
    event RewardsClaimed(address indexed staker, uint256 rewardAmount);


    struct StakingCondition {
        uint80 timeUnit;
        uint256 rewardRatioNumerator;
        uint256 rewardRatioDenominator;
    }

    struct StakerStacking {
        uint256 timeOfLastUpdate;
        uint256 unlockTime;
        uint256 amountStaked;
        uint256 unclaimedRewards;
    }

    ///@dev Mapping staker address to Staker struct. See {struct IStaking20.Staker}.
    mapping(address => StakerStacking[]) public stakers;

    /// @dev Total reward collected per Wallet
    mapping(address => uint256) public stakersRewardClaimed;

    /// @dev Address of ERC20 contract of Stacked Tokens
    address public stakingToken;

    /// @dev Decimals of staking token.
    uint256 public stakingTokenDecimals;

    /// @dev Address of ERC20 contract of Stacked Tokens
    address public rewardToken;

    /// @dev Decimals of reward token.
    uint256 public rewardTokenDecimals;

    /// @dev Total amount of tokens staked in the contract.
    uint256 public stakingTokenBalance;

    /// @dev Address of the wallet holdings the token rewards
    address public rewardWallet;

    /// @dev Count the total number of unique stakers
    uint256 public totalStakers;

    /// @dev Count the total rewards claied
    uint256 public totalRewardClaimed;

    /// @dev Stacking condition
    StakingCondition public stackingCondition;

    /// @dev Time in second that token must be locked to collect the full rewards
    uint256 public lockPeriodDuration;

    constructor(
        address _stakingToken,
        address _rewardToken,
        address _rewardWallet,
        uint80 _timeUnit,
        uint256 _numerator,
        uint256 _denominator,
        uint256 _lockPeriodDuration

    ) Ownable(msg.sender) {
        stakingToken = _stakingToken;
        // Fetch the decimals from the ERC20 token contracts
        stakingTokenDecimals = IERC20Metadata(_stakingToken).decimals();
        rewardTokenDecimals = IERC20Metadata(_rewardToken).decimals();
        //
        rewardToken = _rewardToken;
        rewardWallet = _rewardWallet;
        lockPeriodDuration = _lockPeriodDuration;
        totalStakers = 0;
        stackingCondition = StakingCondition({
            timeUnit: _timeUnit,
            rewardRatioNumerator: _numerator,
            rewardRatioDenominator: _denominator
        });
    }
    /// @dev Emergency function
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    /// @dev Staking logic.
    function _stake(uint256 _amount) internal virtual {
        require(_amount != 0, "Staking 0 tokens");

        address _stakingToken = stakingToken;

        uint256 balanceBefore = IERC20(_stakingToken).balanceOf(address(this));
        _safeTransferERC20(
            stakingToken,
            _stakeMsgSender(),
            address(this),
            _amount
        );
        uint256 actualAmount = IERC20(_stakingToken).balanceOf(address(this)) - balanceBefore;
        StakerStacking memory newStakerStacking = StakerStacking({
            timeOfLastUpdate: block.timestamp,
            unlockTime: block.timestamp + lockPeriodDuration,
            amountStaked: actualAmount,
            unclaimedRewards: 0
        });

        if(stakers[_stakeMsgSender()].length == 0) {
            totalStakers ++;
        }
        stakers[_stakeMsgSender()].push(newStakerStacking);

        stakingTokenBalance += actualAmount;
        emit TokensStaked(_stakeMsgSender(), actualAmount);
    }

    function _updateUnclaimedRewardsForStaker(address _staker, uint256 stackIndex) internal virtual {
        uint256 rewards = _calculateRewards(_staker, stackIndex);
        stakers[_staker][stackIndex].unclaimedRewards += rewards;
        stakers[_staker][stackIndex].timeOfLastUpdate = block.timestamp;
    }

    /// @dev Calculate rewards for a staker.
    function _calculateRewards(address _staker, uint256 stackIndex) internal view virtual returns (uint256 _rewards) {
        StakerStacking memory staker = stakers[_staker][stackIndex];

        StakingCondition memory condition = stackingCondition;
        uint256 startTime = staker.timeOfLastUpdate > staker.unlockTime ? staker.unlockTime : staker.timeOfLastUpdate;
        // @dev Only calculate the reward at the end of the lock period.
        uint256 endTime = staker.unlockTime;

        (bool noOverflowProduct, uint256 rewardsProduct) = Math.tryMul(
            (endTime - startTime) * staker.amountStaked,
            condition.rewardRatioNumerator
        );
        (bool noOverflowSum, uint256 rewardsSum) = Math.tryAdd(
            _rewards,
            (rewardsProduct / condition.timeUnit) / condition.rewardRatioDenominator
        );

        _rewards = noOverflowProduct && noOverflowSum ? rewardsSum : _rewards;

        (, _rewards) = Math.tryMul(_rewards, 10 ** rewardTokenDecimals);

        _rewards /= (10 ** stakingTokenDecimals);
    }

    /// @dev Transfer `amount` of ERC20 token from `from` to `to`.
    function _safeTransferERC20(address _currency, address _from, address _to, uint256 _amount) internal {
        if (_from == _to) {
            return;
        }

        if (_from == address(this)) {
            IERC20(_currency).transfer(_to, _amount);
        } else {
            IERC20(_currency).transferFrom(_from, _to, _amount);
        }
    }

    /// @dev Withdraw logic. Override to add custom logic.
    function _withdraw(uint256 _amount, uint256 stackIndex) internal virtual {
        require(stakers[_stakeMsgSender()].length > 0, "Staker not found");
        require(stackIndex < stakers[_stakeMsgSender()].length, "Stacking not found");
        uint256 _amountStaked = stakers[_stakeMsgSender()][stackIndex].amountStaked;
        require(_amount != 0, "Withdrawing 0 tokens");
        require(_amountStaked >= _amount, "Withdrawing more than staked");

        _updateUnclaimedRewardsForStaker(_stakeMsgSender(), stackIndex);

        stakers[_stakeMsgSender()][stackIndex].amountStaked -= _amount;

        stakingTokenBalance -= _amount;

        _safeTransferERC20(
            stakingToken,
            address(this),
            _stakeMsgSender(),
            _amount
        );

        if (block.timestamp >= stakers[_stakeMsgSender()][stackIndex].unlockTime) {
            _claimRewards(_stakeMsgSender(), stackIndex);
        }
        _removeStackingFromArray(_stakeMsgSender(), stackIndex);
        if(stakers[_stakeMsgSender()].length == 0) {
            totalStakers --;
        }
        emit TokensWithdrawn(_stakeMsgSender(), _amount);
    }

    function _isStackingEmpty(address _stacker, uint256 stackIndex) internal view returns (bool isEmpty) {
        StakerStacking memory stackData = stakers[_stacker][stackIndex];
        isEmpty = stackData.amountStaked == 0 && stackData.unclaimedRewards == 0;
    }

    function _removeStackingFromArray(address _stacker, uint256 stackIndex) internal {
        uint256 lastIndex = stakers[_stakeMsgSender()].length - 1;
        if (stackIndex < lastIndex) {
            stakers[_stacker][stackIndex] = stakers[_stacker][lastIndex];
        }
        stakers[_stacker].pop();
    }

    /// @dev Logic for claiming rewards. Override to add custom logic.
    function _claimRewards(address _stacker, uint256 stackIndex) internal virtual {
        require(stakers[_stacker].length > 0, "Staker not found");
        require(stackIndex < stakers[_stacker].length, "Stacking not found");

        StakerStacking storage stackingInstance = stakers[_stacker][stackIndex];

        uint256 rewards = stackingInstance.unclaimedRewards + _calculateRewards(_stacker, stackIndex);

        require(rewards != 0, "No rewards");

        require(block.timestamp >= stackingInstance.unlockTime, "Lock period is still active");

        stakers[_stacker][stackIndex].timeOfLastUpdate = block.timestamp;
        stakers[_stacker][stackIndex].unclaimedRewards = 0;

        // @dev Transfer the reward to the user
        _safeTransferERC20(
            rewardToken,
            rewardWallet,
            _stacker,
            rewards
        );
        stakersRewardClaimed[_stacker] += rewards;
        totalRewardClaimed += rewards;
        emit RewardsClaimed(_stacker, rewards);
    }

    /// @dev Exposes the ability to override the msg sender -- support ERC2771.
    function _stakeMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /// @dev Return the number of stacking instances for a given wallet address.
    function getStackingCount(address _staker) external view returns (uint256 count) {
        count = stakers[_staker].length;
    }

    function getStackingInfo(address _staker, uint256 stackIndex) external view returns (StakerStacking memory stackInfo) {
        require(stakers[_staker].length > 0, "Staker not found");
        require(stackIndex < stakers[_staker].length, "Stacking not found");

        stackInfo = stakers[_staker][stackIndex];
        stackInfo.unclaimedRewards = _calculateRewards(_staker, stackIndex);
    }

    function stake(uint256 _amount) external whenNotPaused nonReentrant {
        _stake(_amount);
    }

    function withdrawTotal(uint256 stackIndex) external nonReentrant {
        require(stakers[_stakeMsgSender()].length > 0, "Staker not found");
        require(stackIndex < stakers[_stakeMsgSender()].length, "Stacking not found");
        uint256 _amountStaked = stakers[_stakeMsgSender()][stackIndex].amountStaked;
        _withdraw(_amountStaked, stackIndex);
    }

}