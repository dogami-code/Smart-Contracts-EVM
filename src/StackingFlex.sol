// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
import "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";


contract StackingFlex is Ownable, Pausable, ReentrancyGuard {

    /// @dev Emitted when tokens are staked.
    event TokensStaked(address indexed staker, uint256 amount);

    /// @dev Emitted when a tokens are withdrawn.
    event TokensWithdrawn(address indexed staker, uint256 amount);

    /// @dev Emitted when a staker claims staking rewards.
    event RewardsClaimed(address indexed staker, uint256 rewardAmount);

    /// @dev Emitted when contract admin updates timeUnit.
    event UpdatedTimeUnit(uint256 oldTimeUnit, uint256 newTimeUnit);

    /// @dev Emitted when contract admin updates rewardsPerUnitTime.
    event UpdatedRewardRatio(
        uint256 oldNumerator,
        uint256 newNumerator,
        uint256 oldDenominator,
        uint256 newDenominator
    );

    struct StakingCondition {
        uint256 timeUnit;
        uint256 startTimestamp;
        uint256 endTimestamp;
        uint256 rewardRatioNumerator;
        uint256 rewardRatioDenominator;
    }

    struct StakerStacking {
        uint256 conditionIdOflastUpdate;
        uint256 timeOfLastUpdate;
        uint256 amountStaked;
        uint256 unclaimedRewards;
    }

    ///@dev Mapping staker address to Staker struct. See {struct IStaking20.Staker}.
    mapping(address => StakerStacking) public stakers;

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

    /// @dev List of accounts that have staked that token-id.
    address[] public stakersArray;

    /// @dev Total amount of tokens staked in the contract.
    uint256 public stakingTokenBalance;

    ///@dev Next staking condition Id. Tracks number of conditon updates so far.
    uint256 private nextConditionId;

    /// @dev Address of the wallet holdings the token rewards
    address public rewardWallet;

    /// @dev Count the total number of unique stakers
    uint256 public totalStakers;

    /// @dev Count the total rewards claied
    uint256 public totalRewardClaimed;

    /// @dev Mapping from condition Id to staking condition. See {struct IStaking721.StakingCondition}
    mapping(uint256 => StakingCondition) private stakingConditions;

    constructor(
        address _stakingToken,
        address _rewardToken,
        address _rewardWallet,

        uint80 _timeUnit,
        uint256 _numerator,
        uint256 _denominator
    ) Ownable(msg.sender) {
        stakingToken = _stakingToken;
        // Fetch the decimals from the ERC20 token contracts
        stakingTokenDecimals = IERC20Metadata(_stakingToken).decimals();
        rewardTokenDecimals = IERC20Metadata(_rewardToken).decimals();
        //
        rewardToken = _rewardToken;
        rewardWallet = _rewardWallet;
        _setStakingCondition(_timeUnit, _numerator, _denominator);
    }

    function getTimeUnit() public view returns (uint256 _timeUnit) {
        _timeUnit = stakingConditions[nextConditionId - 1].timeUnit;
    }

    function getRewardRatio() public view returns (uint256 _numerator, uint256 _denominator) {
        _numerator = stakingConditions[nextConditionId - 1].rewardRatioNumerator;
        _denominator = stakingConditions[nextConditionId - 1].rewardRatioDenominator;
    }


    /**
     *  @notice  Set time unit. Set as a number of seconds.
     *           Could be specified as -- x * 1 hours, x * 1 days, etc.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *  @param _timeUnit    New time unit.
     */
    function setTimeUnit(uint256 _timeUnit) external virtual onlyOwner {

        StakingCondition memory condition = stakingConditions[nextConditionId - 1];
        require(_timeUnit != condition.timeUnit, "Time-unit unchanged.");
        _setStakingCondition(_timeUnit, condition.rewardRatioNumerator, condition.rewardRatioDenominator);

        emit UpdatedTimeUnit(condition.timeUnit, _timeUnit);
    }

    /**
     *  @notice  Set rewards per unit of time.
     *           Interpreted as (numerator/denominator) rewards per second/per day/etc based on time-unit.
     *
     *           For e.g., ratio of 1/20 would mean 1 reward token for every 20 tokens staked.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *  @param _numerator    Reward ratio numerator.
     *  @param _denominator  Reward ratio denominator.
     */
    function setRewardRatio(uint256 _numerator, uint256 _denominator) external virtual onlyOwner {

        StakingCondition memory condition = stakingConditions[nextConditionId - 1];
        require(
            _numerator != condition.rewardRatioNumerator || _denominator != condition.rewardRatioDenominator,
            "Reward ratio unchanged."
        );
        _setStakingCondition(condition.timeUnit, _numerator, _denominator);

        emit UpdatedRewardRatio(
            condition.rewardRatioNumerator,
            _numerator,
            condition.rewardRatioDenominator,
            _denominator
        );
    }

    /// @dev Set staking conditions.
    function _setStakingCondition(uint256 _timeUnit, uint256 _numerator, uint256 _denominator) internal virtual {
        require(_denominator != 0, "divide by 0");
        require(_numerator != 0, "time-unit can't be 0");
        uint256 conditionId = nextConditionId;
        nextConditionId += 1;

        stakingConditions[conditionId] = StakingCondition({
            timeUnit: _timeUnit,
            rewardRatioNumerator: _numerator,
            rewardRatioDenominator: _denominator,
            startTimestamp: block.timestamp,
            endTimestamp: 0
        });

        if (conditionId > 0) {
            stakingConditions[conditionId - 1].endTimestamp = block.timestamp;
        }
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

        if (stakers[_stakeMsgSender()].amountStaked > 0) {
            _updateUnclaimedRewardsForStaker(_stakeMsgSender());
        } else {
            stakers[_stakeMsgSender()].timeOfLastUpdate = block.timestamp;
            stakers[_stakeMsgSender()].conditionIdOflastUpdate = nextConditionId - 1;
            totalStakers++;
        }

        uint256 balanceBefore = IERC20(_stakingToken).balanceOf(address(this));
        safeTransferERC20(
            stakingToken,
            _stakeMsgSender(),
            address(this),
            _amount
        );
        uint256 actualAmount = IERC20(_stakingToken).balanceOf(address(this)) - balanceBefore;

        stakers[_stakeMsgSender()].amountStaked += actualAmount;
        stakingTokenBalance += actualAmount;

        emit TokensStaked(_stakeMsgSender(), actualAmount);
    }

    function _updateUnclaimedRewardsForStaker(address _staker) internal virtual {
        uint256 rewards = _calculateRewards(_staker);
        stakers[_staker].unclaimedRewards += rewards;
        stakers[_staker].timeOfLastUpdate = block.timestamp;
        stakers[_staker].conditionIdOflastUpdate = nextConditionId - 1;
    }

    /// @dev Calculate rewards for a staker.
    function _calculateRewards(address _staker) internal view virtual returns (uint256 _rewards) {
        StakerStacking memory staker = stakers[_staker];

        uint256 _stakerConditionId = staker.conditionIdOflastUpdate;
        uint256 _nextConditionId = nextConditionId;

        for (uint256 i = _stakerConditionId; i < _nextConditionId; i += 1) {
            StakingCondition memory condition = stakingConditions[i];

            uint256 startTime = i != _stakerConditionId ? condition.startTimestamp : staker.timeOfLastUpdate;
            uint256 endTime = condition.endTimestamp != 0 ? condition.endTimestamp : block.timestamp;

            (bool noOverflowProduct, uint256 rewardsProduct) = Math.tryMul(
                (endTime - startTime) * staker.amountStaked,
                condition.rewardRatioNumerator
            );
            (bool noOverflowSum, uint256 rewardsSum) = Math.tryAdd(
                _rewards,
                (rewardsProduct / condition.timeUnit) / condition.rewardRatioDenominator
            );

            _rewards = noOverflowProduct && noOverflowSum ? rewardsSum : _rewards;
        }

        (, _rewards) = Math.tryMul(_rewards, 10 ** rewardTokenDecimals);

        _rewards /= (10 ** stakingTokenDecimals);
    }

    /// @dev Exposes the ability to override the msg sender -- support ERC2771.
    function _stakeMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /// @dev Transfer `amount` of ERC20 token from `from` to `to`.
    function safeTransferERC20(address _currency, address _from, address _to, uint256 _amount) internal {
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
    function _withdraw(uint256 _amount) internal virtual {
        uint256 _amountStaked = stakers[_stakeMsgSender()].amountStaked;
        require(_amount != 0, "Withdrawing 0 tokens");
        require(_amountStaked >= _amount, "Withdrawing more than staked");

        _updateUnclaimedRewardsForStaker(_stakeMsgSender());

        stakers[_stakeMsgSender()].amountStaked -= _amount;
        stakingTokenBalance -= _amount;

        safeTransferERC20(
            stakingToken,
            address(this),
            _stakeMsgSender(),
            _amount
        );

        if (stakers[_stakeMsgSender()].amountStaked == 0) {
            totalStakers --;
        }

        emit TokensWithdrawn(_stakeMsgSender(), _amount);
    }

    /// @dev View available rewards for a user.
    function availableRewards(address _staker) external view virtual returns (uint256 _rewards) {
        if (stakers[_staker].amountStaked == 0) {
            _rewards = stakers[_staker].unclaimedRewards;
        } else {
            _rewards = stakers[_staker].unclaimedRewards + _calculateRewards(_staker);
        }
    }

    /// @dev Logic for claiming rewards. Override to add custom logic.
    function _claimRewards() internal virtual {
        uint256 rewards = stakers[_stakeMsgSender()].unclaimedRewards + _calculateRewards(_stakeMsgSender());

        require(rewards != 0, "No rewards");

        stakers[_stakeMsgSender()].timeOfLastUpdate = block.timestamp;
        stakers[_stakeMsgSender()].unclaimedRewards = 0;
        stakers[_stakeMsgSender()].conditionIdOflastUpdate = nextConditionId - 1;

        // @dev Transfer the reward to the user
        safeTransferERC20(
            rewardToken,
            rewardWallet,
            _stakeMsgSender(),
            rewards
        );
        stakersRewardClaimed[_stakeMsgSender()] += rewards;
        totalRewardClaimed += rewards;
        emit RewardsClaimed(_stakeMsgSender(), rewards);
    }

    function getStackingInfo(address _staker) external view returns (StakerStacking memory stackInfo) {
        require(stakers[_staker].timeOfLastUpdate > 0, "Staker not found");

        stackInfo = stakers[_staker];
        stackInfo.unclaimedRewards = stackInfo.unclaimedRewards + _calculateRewards(_staker);
    }

    function stake(uint256 _amount) external whenNotPaused nonReentrant {
        _stake(_amount);
    }

    function withdraw(uint256 _amount) external nonReentrant {
        _withdraw(_amount);
    }

    function claimRewards() external nonReentrant {
        _claimRewards();
    }
}