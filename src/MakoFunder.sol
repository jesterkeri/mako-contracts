// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @title MakoFunder
/// @notice Holds MON the owner deposits and tops up the newest operator key, at most once per UTC
/// day and never above `cap` for the listed keys together. Plan: OFFCHAIN_MATCHING_PLAN.md §6.3
/// ([r27] funder contract).
///
/// @dev Not upgradeable, no owner transfer. The only outgoing transfers are `topUp`, `withdraw` and
/// `close`. Every function but `receive` is owner-only. The owner's wallet is trusted: it can withdraw
/// the whole deposit, so the deposit is the most a defect or a lost owner key can cost.
contract MakoFunder {
    /// @dev At most this many operator keys are listed at once (plan §6.3).
    uint256 public constant MAX_KEYS = 4;

    address public immutable owner;
    uint256 public cap;
    /// @dev Operator keys not yet retired.
    address[] private _keys;
    /// @dev Every key ever listed, so a retired key can never be listed again.
    mapping(address => bool) public used;
    mapping(address => bool) public listed;
    /// @dev The newest key, or the zero address after it is retired and before the next `addKey`.
    address public recipient;
    /// @dev UTC day of the last top-up; at deployment, the UTC day of deployment.
    uint256 public lastDay;
    uint256 public lastTopUpBlock;
    bool public closed;

    error NotOwner();
    error Closed();
    error WrongDay();
    error SameDay();
    error NoRecipient();
    error BadBlock();
    error AtCap();
    error Underfunded();
    error SendFailed();
    error ZeroAddress();
    error KeyUsed();
    error TooManyKeys();
    error NotListed();

    event Deposit(address indexed from, uint256 amount);
    event TopUp(address indexed recipient, uint256 sent, uint256 day, uint256 r);
    event KeyAdded(address indexed key);
    event KeyRetired(address indexed key);
    event CapSet(uint256 cap);
    event Withdrawn(address indexed to, uint256 amount);
    event ClosedTo(address indexed to, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 cap_) {
        owner = msg.sender;
        cap = cap_;
        lastDay = block.timestamp / 1 days;
        emit CapSet(cap_);
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /// @param r the block the helper reconciled at; `amount` is the helper's figure at `r`.
    /// @param day the UTC day the owner meant, so a call held back cannot mine on a later day.
    function topUp(uint256 r, uint256 amount, uint256 day) external onlyOwner {
        if (closed) revert Closed();
        if (block.timestamp / 1 days != day) revert WrongDay();
        if (day <= lastDay) revert SameDay();
        address to = recipient;
        if (to == address(0)) revert NoRecipient();
        if (r < lastTopUpBlock || r >= block.number) revert BadBlock();

        uint256 sum = keysBalance();
        if (sum >= cap) revert AtCap();
        uint256 room = cap - sum;
        uint256 sent = amount < room ? amount : room;
        if (address(this).balance < sent) revert Underfunded();

        lastDay = day;
        lastTopUpBlock = block.number;
        emit TopUp(to, sent, day, r);
        (bool ok,) = to.call{value: sent}("");
        if (!ok) revert SendFailed();
    }

    function addKey(address k) external onlyOwner {
        if (k == address(0)) revert ZeroAddress();
        if (used[k]) revert KeyUsed();
        if (_keys.length >= MAX_KEYS) revert TooManyKeys();
        used[k] = true;
        listed[k] = true;
        _keys.push(k);
        recipient = k;
        emit KeyAdded(k);
    }

    function retireKey(address k) external onlyOwner {
        if (!listed[k]) revert NotListed();
        listed[k] = false;
        uint256 n = _keys.length;
        for (uint256 i = 0; i < n; i++) {
            if (_keys[i] == k) {
                _keys[i] = _keys[n - 1];
                _keys.pop();
                break;
            }
        }
        if (recipient == k) recipient = address(0);
        emit KeyRetired(k);
    }

    /// @dev Applies to the next top-up only.
    function setCap(uint256 c) external onlyOwner {
        cap = c;
        emit CapSet(c);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert Underfunded();
        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    /// @notice Sends the whole balance to `to` and makes every later `topUp` revert `Closed`.
    function close(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        closed = true;
        uint256 amount = address(this).balance;
        emit ClosedTo(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert SendFailed();
    }

    /// @notice Sum of the balances of every listed key.
    function keysBalance() public view returns (uint256 sum) {
        uint256 n = _keys.length;
        for (uint256 i = 0; i < n; i++) {
            sum += _keys[i].balance;
        }
    }

    function keys() external view returns (address[] memory) {
        return _keys;
    }
}
