// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OviaEscrow, IERC20} from "../src/OviaEscrow.sol";

/// @dev Minimal ERC20 for testing the token path.
contract MockERC20 {
    string public name = "Mock USD";
    string public symbol = "mUSD";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OviaEscrowTest is Test {
    OviaEscrow escrow;
    MockERC20 token;

    address client = makeAddr("client");
    address freelancer = makeAddr("freelancer");
    address treasury = makeAddr("treasury");
    address rando = makeAddr("rando");

    uint16 constant FEE_BPS = 100; // 1%
    uint256 constant AMOUNT = 1 ether;
    uint32 constant REVIEW = 3 days;

    function setUp() public {
        escrow = new OviaEscrow(FEE_BPS, treasury);
        token = new MockERC20();
        vm.deal(client, 100 ether);
        vm.deal(rando, 1 ether);
    }

    // -- helpers ----------------------------------------------------------

    function _createEthChannel() internal returns (uint256 id) {
        vm.prank(client);
        id = escrow.createChannel{value: AMOUNT}(
            freelancer, address(0), AMOUNT, uint64(block.timestamp + 7 days), REVIEW
        );
    }

    function _submitProof(uint256 id) internal {
        vm.prank(freelancer);
        escrow.submitProof(id, keccak256("delivery-v1"));
    }

    // -- happy path --------------------------------------------------------

    function test_CreateSubmitApprove_SettlesWithFee() public {
        uint256 id = _createEthChannel();
        _submitProof(id);

        vm.prank(client);
        escrow.approve(id);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(freelancer.balance, AMOUNT - fee, "freelancer net payout");
        assertEq(treasury.balance, fee, "protocol fee");
        assertEq(escrow.jobsCompleted(freelancer), 1);
        assertEq(escrow.volumeSettled(freelancer), AMOUNT);
        assertEq(uint8(escrow.getChannel(id).state), uint8(OviaEscrow.State.Settled));
    }

    function test_AutoRelease_AfterReviewPeriod_ByAnyone() public {
        uint256 id = _createEthChannel();
        _submitProof(id);

        // Too early: review window still open.
        vm.prank(rando);
        vm.expectRevert(OviaEscrow.ReviewWindowOpen.selector);
        escrow.release(id);

        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(rando);
        escrow.release(id);

        uint256 fee = (AMOUNT * FEE_BPS) / 10_000;
        assertEq(freelancer.balance, AMOUNT - fee);
    }

    function test_Erc20Channel_SettlesCorrectly() public {
        token.mint(client, 1_000e6);
        vm.startPrank(client);
        token.approve(address(escrow), 500e6);
        uint256 id = escrow.createChannel(
            freelancer, address(token), 500e6, uint64(block.timestamp + 7 days), REVIEW
        );
        vm.stopPrank();

        _submitProof(id);
        vm.prank(client);
        escrow.approve(id);

        uint256 fee = (500e6 * FEE_BPS) / 10_000;
        assertEq(token.balanceOf(freelancer), 500e6 - fee);
        assertEq(token.balanceOf(treasury), fee);
    }

    // -- reject & resolution -------------------------------------------------

    function test_Reject_ReturnsToFunded_AllowsResubmit() public {
        uint256 id = _createEthChannel();
        _submitProof(id);

        vm.prank(client);
        escrow.reject(id);
        assertEq(uint8(escrow.getChannel(id).state), uint8(OviaEscrow.State.Funded));
        assertEq(escrow.getChannel(id).rejections, 1);

        // Resubmission allowed even past the original delivery deadline.
        vm.warp(block.timestamp + 30 days);
        vm.prank(freelancer);
        escrow.submitProof(id, keccak256("delivery-v2"));
        assertEq(uint8(escrow.getChannel(id).state), uint8(OviaEscrow.State.ProofSubmitted));
    }

    function test_Reject_AfterReviewWindow_Reverts() public {
        uint256 id = _createEthChannel();
        _submitProof(id);

        vm.warp(block.timestamp + REVIEW + 1);
        vm.prank(client);
        vm.expectRevert(OviaEscrow.ReviewWindowClosed.selector);
        escrow.reject(id);
    }

    function test_Resolution_SplitPayout() public {
        uint256 id = _createEthChannel();
        _submitProof(id);
        vm.prank(client);
        escrow.reject(id);

        // Freelancer proposes 60/40 in their favour; client accepts.
        vm.prank(freelancer);
        escrow.proposeResolution(id, 6000);
        vm.prank(client);
        escrow.acceptResolution(id);

        uint256 gross = (AMOUNT * 6000) / 10_000;
        uint256 fee = (gross * FEE_BPS) / 10_000;
        assertEq(freelancer.balance, gross - fee, "freelancer split");
        assertEq(client.balance, 100 ether - AMOUNT + (AMOUNT - gross), "client refund");
        assertEq(treasury.balance, fee);
    }

    function test_Resolution_ProposerCannotAcceptOwn() public {
        uint256 id = _createEthChannel();
        vm.prank(client);
        escrow.proposeResolution(id, 0);

        vm.prank(client);
        vm.expectRevert(OviaEscrow.CannotAcceptOwnResolution.selector);
        escrow.acceptResolution(id);
    }

    // -- refunds & griefing protection ----------------------------------------

    function test_RefundExpired_OnlyWithoutAnyProof() public {
        uint256 id = _createEthChannel();

        // Before deadline: refund not possible.
        vm.prank(client);
        vm.expectRevert(OviaEscrow.DeadlineNotPassed.selector);
        escrow.refundExpired(id);

        vm.warp(block.timestamp + 8 days);
        vm.prank(client);
        escrow.refundExpired(id);
        assertEq(client.balance, 100 ether, "full refund");
    }

    function test_RefundExpired_BlockedIfProofWasEverSubmitted() public {
        uint256 id = _createEthChannel();
        _submitProof(id);
        vm.prank(client);
        escrow.reject(id); // back to Funded, but a proof existed

        vm.warp(block.timestamp + 30 days);
        vm.prank(client);
        vm.expectRevert(OviaEscrow.ProofWasSubmitted.selector);
        escrow.refundExpired(id);
    }

    // -- access control & params ----------------------------------------------

    function test_OnlyFreelancerCanSubmitProof() public {
        uint256 id = _createEthChannel();
        vm.prank(rando);
        vm.expectRevert(OviaEscrow.NotFreelancer.selector);
        escrow.submitProof(id, keccak256("x"));
    }

    function test_OnlyClientCanApprove() public {
        uint256 id = _createEthChannel();
        _submitProof(id);
        vm.prank(freelancer);
        vm.expectRevert(OviaEscrow.NotClient.selector);
        escrow.approve(id);
    }

    function test_CreateChannel_ParamValidation() public {
        vm.startPrank(client);

        vm.expectRevert(OviaEscrow.InvalidParams.selector); // self-deal
        escrow.createChannel{value: 1 ether}(
            client, address(0), 1 ether, uint64(block.timestamp + 1 days), REVIEW
        );

        vm.expectRevert(OviaEscrow.InvalidParams.selector); // msg.value mismatch
        escrow.createChannel{value: 0.5 ether}(
            freelancer, address(0), 1 ether, uint64(block.timestamp + 1 days), REVIEW
        );

        vm.expectRevert(OviaEscrow.InvalidParams.selector); // review period too short
        escrow.createChannel{value: 1 ether}(
            freelancer, address(0), 1 ether, uint64(block.timestamp + 1 days), 10 minutes
        );

        vm.stopPrank();
    }

    function test_FeeCap_Enforced() public {
        vm.expectRevert(OviaEscrow.InvalidParams.selector);
        new OviaEscrow(501, treasury);

        vm.expectRevert(OviaEscrow.NotOwner.selector);
        vm.prank(rando);
        escrow.setFee(50, treasury);
    }
}
