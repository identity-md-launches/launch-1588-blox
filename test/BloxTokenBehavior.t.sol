// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BloxToken} from "src/BloxToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract BloxTokenBehaviorTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    BloxToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;
    address internal outsider;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new BloxToken();
        alice = makeAddr("behavior/alice");
        bob = makeAddr("behavior/bob");
        spender = makeAddr("behavior/spender");
        outsider = makeAddr("behavior/outsider");
    }

    function test_constructorEmitsExactlyOneMintAndNoOtherLogs() public {
        vm.recordLogs();
        BloxToken fresh = new BloxToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    function test_transferZeroFromEmptyAccountEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOneWeiAndThenTheEntireRemainingSupply() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 1);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertTrue(token.transfer(alice, SUPPLY - 1));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferEntireSupplyDoesNotMintOrBurn() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(alice, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferMaxUintRevertsWithBalancesIntact() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroValueTransferToZeroStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalCanBeMaxUintWithoutOwningTokens() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, type(uint256).max);
        vm.prank(alice);
        assertTrue(token.approve(spender, type(uint256).max));
        assertEq(token.allowance(alice, spender), type(uint256).max);
        assertEq(token.allowance(spender, alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalReplacesExistingValueAndRevocationTakesEffect() public {
        assertTrue(token.approve(spender, type(uint256).max));
        assertTrue(token.approve(spender, 2));
        assertEq(token.allowance(address(this), spender), 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_finiteAllowanceIsExhaustedAcrossMultipleTransfers() public {
        token.approve(spender, SUPPLY);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), SUPPLY - 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), bob, SUPPLY - 1);
        assertTrue(token.transferFrom(address(this), bob, SUPPLY - 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), bob, 1);
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteAllowanceSurvivesRepeatedSpending() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertTrue(token.transferFrom(address(this), bob, SUPPLY - 1));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), SUPPLY - 1);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_zeroTransferFromWithoutAllowanceSucceedsAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferFromConsumesFiniteAllowanceButPreservesBalance() public {
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRequiresAllowanceEvenWhenCallerIsTheOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        token.approve(address(this), 1);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_failedTransferFromToZeroRestoresFiniteAllowance() public {
        token.approve(spender, 7);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 7);
        assertEq(token.allowance(address(this), spender), 7);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromZeroSenderWithZeroAmountCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceBelongsToExactOwnerAndSpender() public {
        token.transfer(alice, 10);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, 1));
        vm.prank(outsider);
        token.transferFrom(address(this), bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_directTransfersDoNotConsumeApprovalOrPermitNonce() public {
        token.approve(spender, 11);
        token.transfer(alice, 10);
        assertEq(token.allowance(address(this), spender), 11);
        assertEq(token.nonces(address(this)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
        assertEq(token.balanceOf(alice), 10);
    }

    function test_ethAndUnknownCallsAreRejectedWithoutChangingSupply() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool accepted,) = address(token).call{value: 1 wei}("");
        assertFalse(accepted);
        assertEq(alice.balance, 1 ether);
        assertEq(address(token).balance, 0);
        (accepted,) = address(token).call(hex"ffffffff");
        assertFalse(accepted);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRoundTripRestoresBothBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferPreservesBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_overdrawRevertsAtomically(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY);
        extra = bound(extra, 1, type(uint256).max - held);
        token.transfer(alice, held);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, held + extra)
        );
        vm.prank(alice);
        token.transfer(bob, held + extra);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedTransferFromRestoresSpentAllowance(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY);
        extra = bound(extra, 1, type(uint256).max - held);
        uint256 requested = held + extra;
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, requested);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, requested));
        vm.prank(spender);
        token.transferFrom(alice, bob, requested);
        assertEq(token.allowance(alice, spender), requested, "failed transfer consumed allowance");
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceCannotMoveFundedBalance(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        excess = bound(excess, 1, SUPPLY - allowed);
        token.approve(spender, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + excess)
        );
        vm.prank(spender);
        token.transferFrom(address(this), alice, allowed + excess);
        assertEq(token.allowance(address(this), spender), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approvalReplacementDoesNotAddOrMoveTokens(uint256 first, uint256 second) public {
        token.approve(spender, first);
        token.approve(bob, 42);
        token.approve(spender, second);
        assertEq(token.allowance(address(this), spender), second);
        assertEq(token.allowance(address(this), bob), 42);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.nonces(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransfersEqualOneTransfer(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        BloxToken comparison = new BloxToken();
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, total - first));
        assertTrue(comparison.transfer(alice, total));
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(alice), comparison.balanceOf(alice));
        assertEq(token.balanceOf(address(this)), comparison.balanceOf(address(this)));
        assertEq(token.totalSupply(), SUPPLY);
    }
}
