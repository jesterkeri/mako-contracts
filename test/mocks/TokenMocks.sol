// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice The badly-behaved tokens N22 requires the entry path to survive.
///
/// @dev N22 says only EXACT USDC is credited: an entry whose balance increase differs from the
/// amount must revert before any state is written, and false-returning, reverting, no-return and
/// fee-on-transfer tokens must all be handled. Each of those is a separate contract here, because a
/// single configurable mock tends to be tested in only one of its modes.
///
/// The real USDC is pinned by address AND runtime code hash in `SPEC.md` §4, and the deploy script
/// asserts both. These mocks exist to prove the contract's handling is correct anyway, since a
/// pinned address is a deployment-time fact and this is a code-time property.

/// @notice Well-behaved, returns `true`. 6 decimals, like the real USDC.
contract MockUSDC {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Moves the tokens but returns nothing, like several legacy ERC20s.
/// @dev Must be ACCEPTED: the balance check is what makes it safe to use without a return value.
contract NoReturnUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        assembly {
            return(0, 0)
        }
    }
}

/// @notice Returns `false` and moves nothing.
contract FalseReturnUSDC is MockUSDC {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// @notice Reverts outright.
contract RevertingUSDC is MockUSDC {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert("nope");
    }
}

/// @notice Takes a 1% cut in transit, so the contract receives less than `amount`.
/// @dev The case a plain `transferFrom` would credit in full while holding less, leaving the last
/// claimant short. Must revert.
contract FeeOnTransferUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 fee = amount / 100;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[address(0xdead)] += fee;
        return true;
    }
}

/// @notice Moves the tokens but returns one byte, which is neither empty nor a bool.
/// @dev Must fail with the contract's own error rather than a bare `abi.decode` panic.
contract MalformedReturnUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allocateInternal(from, to, amount);
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }

    function allocateInternal(address from, address to, uint256 amount) internal {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Credits MORE than the amount, so the balance increase overshoots.
/// @dev The mirror of fee-on-transfer, and the reason the check is `==` rather than `>=`. A `>=`
/// check would credit the entrant with `amount` while the contract holds more, quietly turning the
/// surplus into treasury dust nobody accounted for.
contract OvershootUSDC is MockUSDC {
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount + 1;
        return true;
    }
}

/// @notice Sends one unit less than asked on `transfer`, so an OUTBOUND payment falls short.
/// @dev The mirror of fee-on-transfer. Without the outbound balance check the accounting records a
/// full payout while the recipient received less, and the books stop matching the balance.
contract ShortTransferUSDC is MockUSDC {
    bool public shortchange;

    function setShortchange(bool yes) external {
        shortchange = yes;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        uint256 sent = shortchange ? amount - 1 : amount;
        balanceOf[msg.sender] -= sent;
        balanceOf[to] += sent;
        return true;
    }
}

/// @notice Calls back into a target during `transfer`, to prove every value-moving path is guarded.
/// @dev N8 wants one reentrancy test per value-moving function. The callback is set per test, so the
/// same token can attack `claim`, `withdrawTreasury` and `enter`.
contract ReentrantUSDC is MockUSDC {
    address public target;
    bytes public payload;
    bool public armed;
    bytes public lastRevert;

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
        armed = true;
    }

    function _attack() internal {
        if (!armed) return;
        armed = false;
        (bool ok, bytes memory ret) = target.call(payload);
        // Record rather than bubble: the test asserts the re-entrant call was REFUSED, and the outer
        // call is then free to complete so the test can check nothing was paid twice.
        if (!ok) lastRevert = ret;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _attack();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _attack();
        return true;
    }
}
