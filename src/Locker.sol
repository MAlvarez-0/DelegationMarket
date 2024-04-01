// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Delegation} from "./Delegation.sol";

interface TwabDelegator {
    function createDelegation(address _delegator, uint256 _slot, address _delegatee, uint96 _lockDuration) external returns (Delegation);
    function updateDelegatee(address _delegator, uint256 _slot, address _delegatee, uint96 _lockDuration) external returns (Delegation);
    function fundDelegation(address _delegator, uint256 _slot, uint256 _amount) external returns (Delegation);
    function transferDelegationTo(uint256 _slot, uint256 _amount, address _to) external returns (Delegation);
}

contract DelegationLocker {
    using SafeERC20 for IERC20;

    struct Locker {
        bool isActive;
        address owner;
        address tokenAddress;
        uint tokenAmount;
        uint endLock;

        uint rewardRate;
        uint lastUpdated;
        uint rewardPerTokenStored;

        uint delegationAmount;
        address[] delegators;
    }
    
    struct Delegator {
        bool exist;
        bool delegationEnded;
        uint slot;
        uint delegatedAmount;
        uint rewards;
        uint rewardPerTokenPaid;
    }

    TwabDelegator public twabDelegator;
    address public pUSDCAddress;

    uint public numberOfLockers = 0; 
    mapping (address => uint[]) public lockerIDsByAddress;
    mapping (uint => Locker) public lockerByIndex;

    mapping (address => mapping (uint => Delegator)) public delegators;  // Address => LockerID => Delegator

    constructor(TwabDelegator _twabDelegator, address _pUSDCAddress) {
        twabDelegator = _twabDelegator;
        pUSDCAddress = _pUSDCAddress;
    }


    modifier existingLocker(uint _lockerID) {
        require(numberOfLockers >= _lockerID, "Locker does not exist");
        _;
    }


    function createLocker(address _tokenAddress, uint _tokenAmount, uint _lockingTime, uint _delegationAmount) external {
        //require((block.timestamp + 1 days) <= _lockingTime, "Locker must have a locking time of at least one day");
        address[] memory _delegators;
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenAmount);

        uint rewardRate = _tokenAmount / (_lockingTime - block.timestamp);
        lockerByIndex[numberOfLockers] = (Locker(true, msg.sender, _tokenAddress, _tokenAmount, _lockingTime, rewardRate, block.timestamp, 0, _delegationAmount, _delegators));
        lockerIDsByAddress[msg.sender].push(numberOfLockers);
        numberOfLockers++;

        //EMIT UN EVENT
    }

    function startLocker(uint _lockerID, address _tokenAddress, uint _tokenAmount, uint _lockingTime, uint _delegationAmount) external existingLocker(_lockerID) {
        Locker storage userLocker = lockerByIndex[_lockerID];
        require(userLocker.owner == msg.sender, "Not the owner of the locker");
        require(!userLocker.isActive, "Locker is still active");
        //require((block.timestamp + 1 days) <= _lockingTime, "Locker must have a locking time of at least one day");

        userLocker.tokenAddress = _tokenAddress;
        userLocker.tokenAmount = _tokenAmount;
        userLocker.endLock = _lockingTime;
        userLocker.delegationAmount = _delegationAmount;
        userLocker.isActive = true;

        userLocker.rewardRate = _tokenAmount / (_lockingTime - block.timestamp);
        userLocker.lastUpdated = block.timestamp; 
  
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, address(this), _tokenAmount);
    }

    function increaseDeposit(uint _lockerID, uint _tokenAmount) external existingLocker(_lockerID) {
        Locker storage userLocker = lockerByIndex[_lockerID];
        require(userLocker.owner == msg.sender, "Not the owner of the locker");
        require(userLocker.isActive, "Locker not active");

        IERC20(userLocker.tokenAddress).transfer(address(this), _tokenAmount);
        userLocker.tokenAmount += _tokenAmount;
    }

    function withdrawFromLocker(uint _lockerID) external existingLocker(_lockerID) {
        Locker storage userLocker = lockerByIndex[_lockerID];
        require(userLocker.owner == msg.sender, "Not the owner of the locker");
        require(userLocker.isActive, "Locker not active");
        require(userLocker.endLock > block.timestamp, "Locker not unlocked yet");
        
        uint pendingAmount = userLocker.tokenAmount;

        userLocker.isActive = false;
        for (uint i = 0; i < userLocker.delegators.length ; i++) {
            delegators[userLocker.delegators[i]][_lockerID].delegationEnded = true;    
        }

        delete userLocker.delegators;
        delete userLocker.tokenAddress;
        delete userLocker.tokenAmount;
        delete userLocker.delegationAmount;
        delete userLocker.rewardRate;
        delete userLocker.lastUpdated;
        delete userLocker.rewardPerTokenStored;

        IERC20(userLocker.tokenAddress).safeTransfer(msg.sender, pendingAmount);
    }


    function delegateToLocker(address _lockerManager, uint _lockerID, uint _delegationAmount, uint _slot) external existingLocker(_lockerID)  {
        require(_delegationAmount > 0, "Delegation must be > 0");
        Locker storage locker = lockerByIndex[_lockerID];
        require(locker.owner == _lockerManager, "Not the owner of the locker");
        //require((block.timestamp + 1 days) <= locker.endLock, "Locker must have a locking time of at least one day");
        require(locker.isActive, "Locker not active");
        Delegator storage delegator = delegators[msg.sender][_lockerID];
        require(!delegator.exist, "Already delegating to this locker");
        _updateReward(_lockerID, msg.sender);

        TwabDelegator _twabDelegator = TwabDelegator(twabDelegator);
        _twabDelegator.updateDelegatee(msg.sender, _slot, _lockerManager, uint96(locker.endLock));
        _twabDelegator.fundDelegation(msg.sender, _slot, _delegationAmount);

        delegators[msg.sender][_lockerID] = Delegator(true, false, _slot, _delegationAmount, 0, 0);            
        delegator.delegatedAmount += _delegationAmount;    
        locker.delegators.push(msg.sender);
    }

    //modifier delegatorExist(uint _lockerID, address _user, uint _delegationAmount) {
    //    if (delegators[_user][_lockerID].delegatedAmount == 0) {
    //        delegators[msg.sender][_lockerID] = Delegator(0, 0, 0, 0);
    //    }
    //    _;
    //}

    // Rewards

    function _updateReward(uint _lockerID, address _user) internal {
        Locker storage locker = lockerByIndex[_lockerID];
        
        locker.rewardPerTokenStored = rewardPerToken(_lockerID);
        locker.lastUpdated = lastTimeRewardApplicable(_lockerID);

        Delegator storage delegator = delegators[_user][_lockerID];
        delegator.rewards = earned(_lockerID, _user);
        delegator.rewardPerTokenPaid = locker.rewardPerTokenStored;
    }

    function earned(uint _lockerID, address _user) public view returns (uint) {
        Delegator memory delegator = delegators[_user][_lockerID];
        return
            ((delegator.delegatedAmount *
                (rewardPerToken(_lockerID) - delegator.rewardPerTokenPaid)) / 1e18) +
            delegator.rewards;
    }

    
    function rewardPerToken(uint _lockerID) public view returns (uint) {
        Locker memory locker = lockerByIndex[_lockerID];
        return
            locker.rewardPerTokenStored +
            (locker.rewardRate * (lastTimeRewardApplicable(_lockerID) - locker.lastUpdated) * 1e18) /
            locker.tokenAmount;
    }


    function lastTimeRewardApplicable(uint _lockerID) public view existingLocker(_lockerID) returns (uint) {
        Locker memory locker = lockerByIndex[_lockerID];
        return _min(locker.endLock, block.timestamp);
    }

    function getReward(uint _lockerID) external existingLocker(_lockerID) {
        Delegator storage delegator = delegators[msg.sender][_lockerID];
        require(delegator.exist, "Not a delegator of this locker");
        _updateReward(_lockerID, msg.sender);
        uint reward = delegator.rewards;
        if (reward > 0) {
            delegator.rewards = 0;
            IERC20(lockerByIndex[_lockerID].tokenAddress).safeTransfer(msg.sender, reward);
        }
        if (delegator.delegationEnded) {
            TwabDelegator(TwabDelegator).transferDelegationTo(delegator.slot, delegator.rewards, msg.sender);
            delete delegators[msg.sender][_lockerID];
        }
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }

}
