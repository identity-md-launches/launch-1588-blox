// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {BloxToken} from "src/BloxToken.sol";
import {BloxPermitDigest} from "./helpers/BloxPermitDigest.sol";

/// forge-config: default.fuzz.runs = 1000
contract BloxTokenPermitTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant INITIAL_ALLOWANCE = 23;
    uint256 internal constant PERMIT_CURVE_ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    BloxToken internal token;
    address internal owner;
    uint256 internal ownerKey;
    address internal spender;
    address internal recipient;
    address internal relayer;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(1 days);
        token = new BloxToken();
        (owner, ownerKey) = makeAddrAndKey("permit/owner");
        spender = makeAddr("permit/spender");
        recipient = makeAddr("permit/recipient");
        relayer = makeAddr("permit/relayer");
        token.transfer(owner, SUPPLY);
        vm.startPrank(owner);
        token.approve(spender, INITIAL_ALLOWANCE);
        token.approve(recipient, 31);
        vm.stopPrank();
    }

    function test_domainMatchesIndependentEIP712Encoding() public view {
        assertEq(token.DOMAIN_SEPARATOR(), BloxPermitDigest.domain(address(token), vm.getChainId()));
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Blox");
        assertEq(version, "1");
        assertEq(chainId, vm.getChainId());
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_permitAtExactDeadlineIsAcceptedAndRelayerGainsNoAuthority() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, deadline);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(owner, spender, 10);
        vm.prank(relayer);
        token.permit(owner, spender, 10, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), 10);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, relayer), 0);
        assertEq(token.balanceOf(owner), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, relayer, 0, 1));
        vm.prank(relayer);
        token.transferFrom(owner, relayer, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, 10));
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(owner), SUPPLY - 10);
        assertEq(token.balanceOf(recipient), 10);
        assertEq(token.nonces(owner), 1, "spending must not consume a permit nonce");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_permitMaxAllowanceAndDeadlineSupportFullSupplySpending() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, type(uint256).max, 0, type(uint256).max);
        token.permit(owner, spender, type(uint256).max, type(uint256).max, v, r, s);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, SUPPLY));
        assertEq(token.allowance(owner, spender), type(uint256).max);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.nonces(owner), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroValuePermitRevokesAllowance() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 0, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 0, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.nonces(owner), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        assertEq(token.balanceOf(owner), SUPPLY);
    }

    function test_sequentialPermitsReplaceAllowanceAndUseSuccessiveNonces() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 100, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 100, vm.getBlockTimestamp(), v, r, s);
        (v, r, s) = _sign(spender, 7, 1, vm.getBlockTimestamp());
        token.permit(owner, spender, 7, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.allowance(owner, spender), 7);
        assertEq(token.allowance(owner, recipient), 31);
        assertEq(token.nonces(owner), 2);
        assertEq(token.nonces(spender), 0);
        assertEq(token.nonces(recipient), 0);
        assertEq(token.nonces(relayer), 0);
        assertEq(token.balanceOf(owner), SUPPLY);
    }

    function test_spendingAndDirectApprovalDoNotInvalidateNextSignedNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 19, 0, vm.getBlockTimestamp());
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        vm.prank(owner);
        token.approve(spender, 0);
        assertEq(token.nonces(owner), 0);
        token.permit(owner, spender, 19, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.allowance(owner, spender), 19);
        assertEq(token.nonces(owner), 1);
        assertEq(token.balanceOf(owner), SUPPLY - 1);
        assertEq(token.balanceOf(recipient), 1);
    }

    function test_replayCannotRestoreAnAlreadySpentAllowance() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        vm.prank(spender);
        token.transferFrom(owner, recipient, 10);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 0);
        assertEq(token.balanceOf(owner), SUPPLY - 10);
        assertEq(token.balanceOf(recipient), 10);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_expiredPermitPreservesExistingAllowanceAndNonce() public {
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(owner, spender, 10, deadline, v, r, s);
        _assertRejectedPermitLeftStateIntact();
    }

    function test_permitWithZeroSpenderRollsBackNonceAndAllowsRetry() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(address(0), 10, 0, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(owner, address(0), 10, vm.getBlockTimestamp(), v, r, s);
        _assertRejectedPermitLeftStateIntact();
        assertEq(token.allowance(owner, address(0)), 0);
        (v, r, s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 10);
    }

    function test_zeroOwnerCannotUseAnUnrecoverableSignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 10, vm.getBlockTimestamp(), 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertRejectedPermitLeftStateIntact();
    }

    function test_invalidVIsRejectedWithoutConsumingNonce() public {
        (, bytes32 r, bytes32 s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), 0, r, s);
        _assertRejectedPermitLeftStateIntact();
    }

    function test_malleableHighSSignatureIsRejectedWithoutConsumingNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        bytes32 highS = bytes32(PERMIT_CURVE_ORDER - uint256(s));
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v == 27 ? 28 : 27, r, highS);
        _assertRejectedPermitLeftStateIntact();
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 10);
    }

    function test_signatureForAnotherDeploymentIsRejected() public {
        BloxToken other = new BloxToken();
        bytes32 digest =
            BloxPermitDigest.digest(address(other), vm.getChainId(), owner, spender, 10, 0, vm.getBlockTimestamp());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        assertNotEq(other.DOMAIN_SEPARATOR(), token.DOMAIN_SEPARATOR());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        _assertRejectedPermitLeftStateIntact();
    }

    function test_chainIdChangeRejectsOldSignatureAndAcceptsNewDomain() public {
        uint256 oldChainId = vm.getChainId();
        bytes32 oldDomain = token.DOMAIN_SEPARATOR();
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        uint256 newChainId = oldChainId == 1 ? 2 : 1;
        vm.chainId(newChainId);
        assertEq(token.DOMAIN_SEPARATOR(), BloxPermitDigest.domain(address(token), newChainId));
        assertNotEq(token.DOMAIN_SEPARATOR(), oldDomain);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        _assertRejectedPermitLeftStateIntact();
        (v, r, s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 10);
        vm.chainId(oldChainId);
        assertEq(token.DOMAIN_SEPARATOR(), oldDomain);
    }

    function test_permitNonceIsScopedToEachOwner() public {
        (address secondOwner, uint256 secondKey) = makeAddrAndKey("permit/secondOwner");
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        bytes32 digest = BloxPermitDigest.digest(
            address(token), vm.getChainId(), secondOwner, spender, 20, 0, vm.getBlockTimestamp()
        );
        (v, r, s) = vm.sign(secondKey, digest);
        token.permit(secondOwner, spender, 20, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.nonces(secondOwner), 1);
        assertEq(token.allowance(owner, spender), 10);
        assertEq(token.allowance(secondOwner, spender), 20);
        assertEq(token.balanceOf(secondOwner), 0, "permit must not mint tokens");
        assertEq(token.balanceOf(owner), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_validPermitSetsExactAllowanceThenSpends(uint256 value, uint256 amount, uint256 ttl) public {
        ttl = bound(ttl, 0, 365 days);
        uint256 deadline = vm.getBlockTimestamp() + ttl;
        amount = bound(amount, 0, value < SUPPLY ? value : SUPPLY);
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, value, 0, deadline);
        vm.prank(relayer);
        token.permit(owner, spender, value, deadline, v, r, s);
        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
        assertEq(token.balanceOf(owner), SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, recipient, amount));
        assertEq(token.allowance(owner, spender), value == type(uint256).max ? value : value - amount);
        assertEq(token.balanceOf(owner), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.allowance(owner, recipient), 31);
        assertEq(token.nonces(owner), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_futureNonceIsRejectedAndCurrentNonceRemainsUsable(uint256 nonce) public {
        nonce = bound(nonce, 1, type(uint256).max);
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, 10, nonce, vm.getBlockTimestamp());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        _assertRejectedPermitLeftStateIntact();
        (v, r, s) = _sign(spender, 10, 0, vm.getBlockTimestamp());
        token.permit(owner, spender, 10, vm.getBlockTimestamp(), v, r, s);
        assertEq(token.nonces(owner), 1);
        assertEq(token.allowance(owner, spender), 10);
    }

    function testFuzz_changingAnySignedFieldIsRejected(uint8 field, uint256 value) public {
        field = uint8(bound(field, 0, 3));
        value = bound(value, 0, type(uint256).max - 1);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _sign(spender, value, 0, deadline);
        address submittedOwner = field == 0 ? recipient : owner;
        address submittedSpender = field == 1 ? recipient : spender;
        uint256 submittedValue = field == 2 ? value + 1 : value;
        uint256 submittedDeadline = field == 3 ? deadline + 1 : deadline;
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(submittedOwner, submittedSpender, submittedValue, submittedDeadline, v, r, s);
        _assertRejectedPermitLeftStateIntact();
        assertEq(token.nonces(recipient), 0);
        assertEq(token.allowance(recipient, spender), 0);
    }

    function _sign(address approvedSpender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(
            ownerKey,
            BloxPermitDigest.digest(address(token), vm.getChainId(), owner, approvedSpender, value, nonce, deadline)
        );
    }

    function _assertRejectedPermitLeftStateIntact() internal view {
        assertEq(token.nonces(owner), 0, "rejection consumed nonce");
        assertEq(token.allowance(owner, spender), INITIAL_ALLOWANCE, "rejection changed allowance");
        assertEq(token.allowance(owner, recipient), 31, "rejection changed unrelated allowance");
        assertEq(token.allowance(owner, relayer), 0);
        assertEq(token.balanceOf(owner), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
