// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {BloxToken} from "../src/BloxToken.sol";

/// @dev Stands in for the IdentityMD ProjectFactory: the address that deploys the token and so
///      receives the whole supply. It only forwards tokens when the test tells it to.
contract FactoryStub {
    function deployToken() external returns (BloxToken) {
        return new BloxToken();
    }

    function move(BloxToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract BloxTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1_000;

    FactoryStub factory;
    BloxToken token;

    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant POOL_MANAGER = address(0x900C);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    uint256 constant SIGNER_KEY = 0xA11CE;
    address signer;

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deployToken();
        signer = vm.addr(SIGNER_KEY);
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Blox");
        assertEq(token.symbol(), "BLOX");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_wholeSupplyIsMintedOnceToTheDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test harness must hold nothing");
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_deployerIsMsgSenderNotTxOrigin() public {
        // Deploy from an arbitrary EOA with a different tx.origin: the supply follows msg.sender.
        vm.prank(ALICE, BOB);
        BloxToken fresh = new BloxToken();
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(fresh.balanceOf(BOB), 0);
    }

    function test_constructorEmitsASingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new BloxToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Logo provenance recorded on chain
    // ---------------------------------------------------------------------------------------------

    function test_logoIsTheXProfilePictureByContentHash() public view {
        assertEq(token.logoURI(), "ipfs://QmWJsrdD9smahpdyqjBzDBodJkJJGNznMA2Wrh15R1hhCp");
        assertEq(token.LOGO_URI(), token.logoURI());
        assertEq(token.LOGO_SHA256(), 0xc2aeb53e69e10a7a4654a97ce8b26bd0a99a843d024ad6f09f6f7d235ca2eaec);
        assertEq(token.LOGO_SOURCE(), "https://x.com/blox_imd");
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: everything arrives whole, nothing is taxed
    // ---------------------------------------------------------------------------------------------

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryCanPayOutTheWholeSupply() public {
        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 pool = (SUPPLY * 8_800) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertTrue(factory.move(token, POOL_MANAGER, pool));
        assertTrue(factory.move(token, ALICE, remainder));
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(ALICE), SUPPLY);
    }

    function testFuzz_transferConservesSupplyExactly(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(factory.move(token, to, amount));
        assertEq(token.balanceOf(to), amount, "transfer arrived short or long");
        assertEq(token.balanceOf(address(factory)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromConservesSupplyExactly(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(address(factory));
        token.approve(ALICE, amount);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(factory), BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.allowance(address(factory), ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths
    // ---------------------------------------------------------------------------------------------

    function test_transferMoreThanBalanceReverts() public {
        factory.move(token, ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 1 ether + 1)
        );
        token.transfer(BOB, 1 ether + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(factory), ALICE, 1);
    }

    function test_transferFromBeyondAllowanceReverts() public {
        vm.prank(address(factory));
        token.approve(ALICE, 5);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 5, 6));
        token.transferFrom(address(factory), BOB, 6);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged hand: nothing mints, pauses, freezes, seizes or burns someone else's balance
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        factory.move(token, ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(address(factory));
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, address(factory), 1));
        assertFalse(moved, "the deployer pulled from a holder without allowance");
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // EIP-2612 permit
    // ---------------------------------------------------------------------------------------------

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function test_permitSetsAllowanceAndBumpsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 123, 0, deadline));
        token.permit(signer, BOB, 123, deadline, v, r, s);
        assertEq(token.allowance(signer, BOB), 123);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitWithWrongSignerReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, _permitDigest(signer, BOB, 123, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, vm.addr(0xB0B), signer));
        token.permit(signer, BOB, 123, deadline, v, r, s);
        assertEq(token.allowance(signer, BOB), 0);
    }

    function test_permitAfterDeadlineReverts() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 123, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, BOB, 123, deadline, v, r, s);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _permitDigest(signer, BOB, 123, 0, deadline));
        token.permit(signer, BOB, 123, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, BOB, 123, deadline, v, r, s);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
}
