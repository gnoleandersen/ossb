//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "hardhat/console.sol";

// Use openzeppelin to inherit battle-tested implementations (ERC20, ERC721, etc)
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * A smart contract that allows changing a state variable of the contract and tracking the changes
 * It also allows the owner to withdraw the Ether in the contract
 * @author BuidlGuidl
 */
contract YourContract is Ownable {
	using SafeERC20 for IERC20;

	struct Task {
		string taskUrl; // Location of task 
		address reviewer; // The one who can determine if this task has been completed, able to set to approved or canceled status
		uint8 reviewerPercentage; // Percentage of funds that go to reviewer, set at creation, payed out when worker claims funds
		address approvedWorker; // The worker who is able to claim funds when approved, can be set before or after work is submitted
		// mapping(address => uint) totalFunding; // TokenAddress => amount deposited - zero address for ETH - can be derived from funding below
		mapping(address => bool) hasFundingType; // Used for making sure fundingType only contains unique items
		address[] fundingType; // Token addresses for each asset funding
		mapping(address => bool) hasFunderAddress; // Used for making sure funderAddresses only contains unique items
		address[] funderAddresses; // Unique funder addresses
		mapping(address => mapping(address => uint)) funding; // FunderAddress => tokenAddress => amount
		uint creationTime; // May include this to refund users after certain time has passed
		bool approved; // Has task been reviewed and accepted, worker can be payed out
		bool canceled; // Everyone is refunded when a task moves to this state
		bool complete; // All funds have been allocated
	}

	// State Variables
	uint8 public protocolTakeRate = 0; // Percentage that protocol takes from every bounty claim
	uint8 public maxProtocolTakeRate = 50; // Protocol won't be able to take more than this / 1000 of a bounty - 5% at default level
	uint32 public unlockPeriod = 63072000; // Two years in seconds - Anyone can cancel a task after this time period - uint32 maximimum is 136 years
	address public protocolVault; // Need to review use of vault

	uint public currentTaskIndex;
	mapping(uint => Task) public tasks;
	mapping(address => mapping(address => uint)) withdrawableFunds; // fundOwner => tokenAddress => amount, can be withdrawn by fundOwner at anytime
	mapping(address => uint) totalTokenBalance;

	// Events
	event TaskCreated (uint indexed index, string taskUrl, address reviewer);
	event TaskFunded (uint indexed index, uint amount, address token);
	event TaskCanceled (uint indexed index);
	event TaskApproved (uint indexed index, address worker);
	event TaskFinalized (uint indexed index);
	event Withdraw (address indexed receiver, uint amount, address token);
	event WorkSubmitted (uint indexed index, address worker, string workUrl);
	event ApprovedWorkerSet (uint indexed index, address worker);
	// Governance Events
	event TakeRateAdjusted (uint8 takeRate);
	event MaxTakeRateLowered (uint8 maxTakeRate);
	event UnlockPeriodAdjusted (uint32 unlockPeriod);

	// Functions
	constructor(uint8 _protocolTakeRate, address _protocolVault) {
		require(_protocolTakeRate <= maxProtocolTakeRate, "Protocol percent exceeds maximum");
		require(_protocolVault != address(0), "Protocol vault cannot be zero address");
		protocolTakeRate = _protocolTakeRate;	
		protocolVault = _protocolVault;
	}

	// Main Workflows
	function createTask(string memory taskUrl, address reviewer, uint8 reviewerPercentage) external {
		require(reviewer != address(0), "Reviewer address cannot be the zero address");
		require(reviewerPercentage <= 100, "Reviewer Percentage cannot exceed 100%");
		_createTask(taskUrl, reviewer, reviewerPercentage);
	}

	function createAndFundTask(string memory taskUrl, address reviewer, uint8 reviewerPercentage, uint amount, address token) external payable {
		require(reviewer != address(0), "Reviewer address cannot be the zero address");
		require(reviewerPercentage <= 100, "Reviewer Percentage cannot exceed 100%");
		uint index = _createTask(taskUrl, reviewer, reviewerPercentage);
		_fundTask(index, amount, token);
	}

	function fundTask(uint taskIndex, uint amount, address token) external payable {
		require(currentTaskIndex > taskIndex, "A task does not exist at that index");
		_fundTask(taskIndex, amount, token);
	}

	function withdraw(uint amount, address tokenAddress) external {
		uint balance = withdrawableFunds[msg.sender][tokenAddress];
		require(amount <= balance, "Specified amount is greater than funds");
		balance -= amount; // Verify that this updates state - review
		// Remove funds from total balance mapping
		totalTokenBalance[tokenAddress] -= amount;
		if (tokenAddress == address(0)){
			// ETH
			(bool sent,) = payable(msg.sender).call{value: amount}("");
			require(sent, "Failed to send");
		} else {
			IERC20(tokenAddress).safeTransfer(msg.sender, amount);
		}
		
		emit Withdraw(msg.sender, amount, tokenAddress);
	}

	function _createTask(string memory taskUrl, address reviewer, uint8 reviewerPercentage) internal returns (uint idx) {
		idx = currentTaskIndex;
		Task storage task = tasks[idx];
		task.taskUrl = taskUrl;
		task.reviewer = reviewer;
		task.reviewerPercentage = reviewerPercentage;
		task.creationTime = block.timestamp;

		// Increment index for next entry
		currentTaskIndex ++;

		// Emit event
		emit TaskCreated(idx, taskUrl, reviewer);

		// returning the idx in case other processes need it to further modify the task
		return idx;
	}

	function _fundTask(uint taskIndex, uint amount, address token) internal {
		Task storage task = tasks[taskIndex];
		require(!task.complete || !task.canceled, "Task is in a final state, cannot fund it");

		// Transfer value
		if (token == address(0)) {
			require(amount > 0 && msg.value == amount, "Amount not set");
			// Must be ETH
			( bool sent, ) = payable(address(this)).call{value: msg.value}("");
			require(sent, "Failed to send Ether");
		} else {
			require(amount > 0, "Amount not set");
			IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
		}
		// Update State
		_addFunderAndFunds(task, token, amount);

		emit TaskFunded(taskIndex, amount, token);
	}

	function _addFunderAndFunds(Task storage task, address token, uint amount) internal {
		// Check if token address is already recorded
		if (!task.hasFundingType[token]) {
			task.hasFundingType[token] = true;
			task.fundingType.push(token);
		}
		// Check if funder address is already recorded
		if (!task.hasFunderAddress[msg.sender]){
			task.hasFunderAddress[msg.sender] = true;
			task.funderAddresses.push(msg.sender);
		}
		// Add funds to task
		task.funding[msg.sender][token] += amount;
		// Add funds to total balance mapping
		totalTokenBalance[token] += amount;
	}

	function submitWork(uint taskIndex, string calldata workUrl) external {
		emit WorkSubmitted(taskIndex, msg.sender, workUrl);
	}
	
	// Big Payouts when this is called - take heed
	function cancelTask(uint taskIndex) external {
		Task storage task = tasks[taskIndex];
		require(msg.sender == task.reviewer || block.timestamp - unlockPeriod > task.creationTime, "Unlock period has not completed, you are not the reviewer");
		task.canceled = true;
		// Refund all funders
		for (uint i; i < task.funderAddresses.length; i ++) {
			for (uint h; h < task.fundingType.length; h ++) {
				address funder = task.funderAddresses[i];
				address token = task.fundingType[h];
				uint amount = task.funding[funder][token];
				if (amount > 0) {
					withdrawableFunds[funder][token] += amount;
				}
			}
		}
		emit TaskCanceled(taskIndex);
	}

	// Anyone can do this if its in the right state
	function finalizeTask(uint taskIndex) external {
		Task storage task = tasks[taskIndex];
		require(!task.canceled, "Cannot finalize canceled task");
		require(!task.complete, "Task has already been finalized");
		require(task.approved, "Task must be approved");
		task.complete = true;
		for (uint h; h < task.fundingType.length; h ++) {
			address token = task.fundingType[h];
			uint totalAmount;
			for (uint i; i < task.funderAddresses.length; i ++) {
				address funder = task.funderAddresses[i];
				totalAmount += task.funding[funder][token];
			}
			_divyUp(totalAmount, token, task.reviewer, task.approvedWorker, task.reviewerPercentage);
		}
		emit TaskFinalized(taskIndex);
	}

	// Need to review math here to confirm tokens don't get stuck in the contract
	function _divyUp(uint amount, address token, address reviewer, address worker, uint reviewerPercentage) internal {
		if (protocolTakeRate > 0) {
			uint protocolShare = amount * protocolTakeRate / 1000; // By dividing by 1000 this allows us to adjust the take rate to be as granular as 0.1%
			withdrawableFunds[protocolVault][token] += protocolShare;
			amount = amount - protocolShare;
		}
		if (reviewerPercentage > 0) {
			uint reviewerShare = amount * reviewerPercentage / 100;
			withdrawableFunds[reviewer][token] += reviewerShare;
			amount = amount - reviewerShare;
		}
		
		withdrawableFunds[worker][token] += amount;
	}

	// Reviewer only functions
	function approveTask(uint taskIndex, address approvedWorker) external {
		Task storage task = tasks[taskIndex];
		require(msg.sender == task.reviewer, "Only the reviewer can approve");
		require(approvedWorker != address(0), "ApprovedWorker cannot be zero address");
		task.approvedWorker = approvedWorker;
		task.approved = true;

		emit TaskApproved(taskIndex, approvedWorker);
	}

	function setApprovedWorker(uint taskIndex, address approvedWorker) external {
		Task storage task = tasks[taskIndex];
		require(msg.sender == task.reviewer, "Only the reviewer can set the approved worker");
		task.approvedWorker = approvedWorker;

		emit ApprovedWorkerSet(taskIndex, approvedWorker);
	}

	// Views
	function getWithdrawableBalance(address token) external view returns (uint) {
		return withdrawableFunds[msg.sender][token];
	}

	function getTask(uint taskIndex) external view returns (string memory, address, uint8, address, address[] memory, address[] memory, uint, bool, bool, bool) {
		return (tasks[taskIndex].taskUrl, tasks[taskIndex].reviewer, tasks[taskIndex].reviewerPercentage, tasks[taskIndex].approvedWorker, tasks[taskIndex].fundingType, tasks[taskIndex].funderAddresses, tasks[taskIndex].creationTime, tasks[taskIndex].approved, tasks[taskIndex].canceled, tasks[taskIndex].complete);
	}

	function getTaskFunding(uint taskIndex) external view returns (address[] memory, uint[] memory) {
		uint[] memory amounts;
		for (uint h; h < tasks[taskIndex].fundingType.length; h ++) {
			address token = tasks[taskIndex].fundingType[h];
			for (uint i; i < tasks[taskIndex].funderAddresses.length; i ++) {
				address funder = tasks[taskIndex].funderAddresses[i];
				amounts[h] += tasks[taskIndex].funding[funder][token];
			}
		}
		return (tasks[taskIndex].fundingType, amounts);
	}

	// Governance
	function adjustTakeRate(uint8 takeRate) external onlyOwner {
		require(takeRate <= maxProtocolTakeRate, "takeRate exceeds maximum");
		protocolTakeRate = takeRate;

		emit TakeRateAdjusted(takeRate);
	}
	
	function permanentlyLowerMaxTakeRate(uint8 takeRate) external onlyOwner {
		require(takeRate < maxProtocolTakeRate, "TakeRate is higher than maximum allows");
		maxProtocolTakeRate = takeRate;
		// If the current protocol take rate is greater than the new max then adjust it
		if (protocolTakeRate > takeRate){
			protocolTakeRate = takeRate;
			emit TakeRateAdjusted(takeRate);
		}

		emit MaxTakeRateLowered(takeRate);
	}

	function adjustUnlockPeriod(uint32 _unlockPeriod) external onlyOwner {
		unlockPeriod = _unlockPeriod;

		emit UnlockPeriodAdjusted(unlockPeriod);
	}

	function withdrawStuckTokens(address tokenAddress) external onlyOwner {
		uint trackedBalance = totalTokenBalance[tokenAddress];
		if (tokenAddress == address(0)) {
			uint inContract = address(this).balance;
			uint stuck = inContract - trackedBalance;
			(bool sent,) = payable(owner()).call{value: stuck}("");
			require(sent, "Failed to send excess to owner");
		} else {
			IERC20 token = IERC20(tokenAddress);
			uint inContract = token.balanceOf(address(this));
			uint stuck = inContract - trackedBalance;
			token.safeTransfer(owner(), stuck);
		}
	}

	receive() external payable {}
	fallback() external payable {}
}
