// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {BloxToken} from "src/BloxToken.sol";
import {BloxPermitDigest} from "./helpers/BloxPermitDigest.sol";

/// @dev All token holders are tracked. The handler deploys the real token, retains 60%, and
/// distributes 10% to each of four signers by real transfers. No storage writes or token deals.
/// Model values are updated from requested operations, never copied from token getters.
contract BloxTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant ACTOR_COUNT = 5;

    BloxToken public immutable token;
    address public immutable outsider;
    address[5] public actors;
    uint256[5] internal keys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;

    uint256 public directVolume;
    uint256 public delegatedVolume;
    uint256 public permitCount;
    uint256 public failureCount;

    struct SignedPermit {
        address spender;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bool exists;
    }

    mapping(address => SignedPermit) internal lastPermit;

    constructor() {
        token = new BloxToken();
        actors[0] = address(this);
        outsider = makeAddr("invariant/unapproved outsider");
        expectedBalance[address(this)] = SUPPLY;
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        for (uint256 i = 1; i < ACTOR_COUNT; ++i) {
            (actors[i], keys[i]) = makeAddrAndKey(string.concat("invariant/signer/", vm.toString(i)));
            assertTrue(token.transfer(actors[i], SUPPLY / 10));
            _recordTransfer(address(this), actors[i], SUPPLY / 10);
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        directVolume += amount;
    }

    function transferEntireBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = expectedBalance[from];
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _recordTransfer(from, to, amount);
        directVolume += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), value);
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    /// @dev Uses the existing allowance so earlier approvals, permits and revocations matter.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = bound(amountSeed, 0, available);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _recordTransfer(owner, to, amount);
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        delegatedVolume += amount;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 value, uint256 ttlSeed) external {
        uint256 ownerIndex = bound(ownerSeed, 1, ACTOR_COUNT - 1);
        _permit(ownerIndex, _actor(spenderSeed), value, vm.getBlockTimestamp() + bound(ttlSeed, 0, 30 days));
    }

    function replayPermit(uint256 ownerSeed) external {
        uint256 ownerIndex = bound(ownerSeed, 1, ACTOR_COUNT - 1);
        address owner = actors[ownerIndex];
        // Make this action exercise a real replay even if no permit has been selected yet.
        if (!lastPermit[owner].exists) _permit(ownerIndex, actors[0], 1, vm.getBlockTimestamp() + 1 days);
        SignedPermit memory signed = lastPermit[owner];
        if (vm.getBlockTimestamp() > signed.deadline) {
            vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, signed.deadline));
        } else {
            vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        }
        vm.prank(outsider);
        token.permit(owner, signed.spender, signed.value, signed.deadline, signed.v, signed.r, signed.s);
        ++failureCount;
    }

    function expiredPermit(uint256 ownerSeed, uint256 spenderSeed, uint256 value) external {
        uint256 ownerIndex = bound(ownerSeed, 1, ACTOR_COUNT - 1);
        address owner = actors[ownerIndex];
        address spender = _actor(spenderSeed);
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerIndex, spender, value, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        vm.prank(outsider);
        token.permit(owner, spender, value, deadline, v, r, s);
        ++failureCount;
    }

    function overdraw(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = held + bound(excessSeed, 1, type(uint256).max - held);
        address to = _actor(toSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        ++failureCount;
    }

    /// @dev Sufficient approval followed by an invalid transfer must roll back allowance spending.
    function overdrawWithApproval(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = held + bound(excessSeed, 1, type(uint256).max - held);
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        ++failureCount;
    }

    function unauthorizedTransferFrom(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, amount));
        vm.prank(outsider);
        token.transferFrom(owner, to, amount);
        ++failureCount;
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(from);
        token.transfer(address(0), amount);
        ++failureCount;
    }

    function attemptAdmin(uint256 callerSeed, uint256 victimSeed, uint256 amount, uint8 operation) external {
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        bytes memory data;
        operation = uint8(bound(operation, 0, 3));
        if (operation == 0) data = abi.encodeWithSignature("mint(address,uint256)", victim, amount);
        else if (operation == 1) data = abi.encodeWithSignature("burnFrom(address,uint256)", victim, amount);
        else if (operation == 2) data = abi.encodeWithSignature("pause()");
        else data = abi.encodeWithSignature("transferOwnership(address)", victim);
        vm.prank(caller);
        (bool success,) = address(token).call(data);
        assertFalse(success, "unexpected privileged entry point");
        ++failureCount;
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, 365 days));
    }

    function _approve(address owner, address spender, uint256 value) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, value));
        expectedAllowance[owner][spender] = value;
    }

    function _permit(uint256 ownerIndex, address spender, uint256 value, uint256 deadline) internal {
        address owner = actors[ownerIndex];
        (uint8 v, bytes32 r, bytes32 s) = _sign(ownerIndex, spender, value, deadline);
        vm.prank(outsider);
        token.permit(owner, spender, value, deadline, v, r, s);
        expectedAllowance[owner][spender] = value;
        ++expectedNonce[owner];
        ++permitCount;
        lastPermit[owner] = SignedPermit(spender, value, deadline, v, r, s, true);
    }

    function _sign(uint256 ownerIndex, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        address owner = actors[ownerIndex];
        return vm.sign(
            keys[ownerIndex],
            BloxPermitDigest.digest(
                address(token), vm.getChainId(), owner, spender, value, expectedNonce[owner], deadline
            )
        );
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, ACTOR_COUNT - 1)];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract BloxTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    BloxTokenHandler internal handler;
    BloxToken internal token;

    function setUp() public {
        vm.warp(1 days);
        handler = new BloxTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferEntireBalance.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.approveInfinite.selector;
        selectors[4] = handler.revoke.selector;
        selectors[5] = handler.transferFrom.selector;
        selectors[6] = handler.permit.selector;
        selectors[7] = handler.replayPermit.selector;
        selectors[8] = handler.expiredPermit.selector;
        selectors[9] = handler.overdraw.selector;
        selectors[10] = handler.overdrawWithApproval.selector;
        selectors[11] = handler.unauthorizedTransferFrom.selector;
        selectors[12] = handler.transferToZero.selector;
        selectors[13] = handler.attemptAdmin.selector;
        selectors[14] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixed supply is required by the brief; every possible successful recipient is tracked.
    function invariant_supplyEqualsSumOfAllTrackedBalances() public view {
        uint256 held;
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            held += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), SUPPLY, "supply changed after deployment");
        assertEq(held, SUPPLY, "tokens created, destroyed, taxed or sent to an untracked recipient");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(handler.outsider()), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @dev Conservation alone cannot detect funds moved between the wrong two accounts.
    function invariant_eachBalanceMatchesAuthorizedNetTransfers() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "wrong account balance");
        }
    }

    function invariant_allowancesMatchApprovalsPermitsAndSuccessfulSpending() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < handler.ACTOR_COUNT(); ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(owner, handler.outsider()), 0, "relayer gained spending rights");
            assertEq(token.allowance(owner, address(0)), 0);
        }
    }

    function invariant_noncesCountOnlySuccessfulPermitsForThatOwner() public view {
        for (uint256 i; i < handler.ACTOR_COUNT(); ++i) {
            address actor = handler.actors(i);
            assertEq(token.nonces(actor), handler.expectedNonce(actor), "nonce consumed or reset incorrectly");
        }
        assertEq(token.nonces(handler.outsider()), 0);
        assertEq(token.nonces(address(0)), 0);
    }

    /// @dev Deterministic reachability check: positive transfers, each failure action, and both
    /// finite and infinite approvals run even if a random campaign happens to choose many zeroes.
    function test_handlerExercisesMeaningfulSequences() public {
        handler.transfer(0, 1, 100);
        handler.approve(1, 2, 99);
        handler.transferFrom(1, 2, 3, 50);
        handler.approveInfinite(3, 4);
        handler.transferFrom(3, 4, 1, 1);
        handler.revoke(3, 4);
        handler.transferFrom(3, 4, 1, 100); // bounded to zero after revocation
        handler.permit(1, 2, 51, 1 days);
        handler.transferFrom(1, 2, 3, 51);
        handler.replayPermit(1);
        handler.expiredPermit(2, 3, 100);
        handler.overdraw(0, 1, 1);
        handler.overdrawWithApproval(1, 2, 3, 1);
        handler.unauthorizedTransferFrom(0, 1, 1);
        handler.transferToZero(0, 1);
        for (uint8 i; i < 4; ++i) {
            handler.attemptAdmin(0, 1, 1, i);
        }
        handler.transferEntireBalance(4, 0);
        handler.advanceTime(2 days);
        handler.replayPermit(1); // the saved signature is now expired as well as consumed
        assertGt(handler.directVolume(), 100);
        assertEq(handler.delegatedVolume(), 102);
        assertEq(handler.permitCount(), 1);
        assertEq(handler.failureCount(), 11);
        invariant_supplyEqualsSumOfAllTrackedBalances();
        invariant_eachBalanceMatchesAuthorizedNetTransfers();
        invariant_allowancesMatchApprovalsPermitsAndSuccessfulSpending();
        invariant_noncesCountOnlySuccessfulPermitsForThatOwner();
    }
}
