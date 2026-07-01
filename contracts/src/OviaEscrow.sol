// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal ERC20 interface — kept local to avoid external dependencies in v1.
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/**
 * @title  OviaEscrow
 * @author Ovia Labs
 * @notice Trustless escrow & auto-settlement channels between a client and a freelancer.
 *
 *         Core flow (v1):
 *           1. Client creates + funds a channel (ETH or any ERC20).
 *           2. Freelancer submits a proof-of-delivery hash.
 *           3. Client approves  -> instant settlement to freelancer.
 *              Client is silent -> anyone can trigger auto-release after the review period.
 *              Client rejects   -> channel returns to Funded; freelancer may resubmit,
 *                                  or either party proposes a split resolution that the
 *                                  counterparty accepts.
 *
 *         Design rules that prevent griefing (see docs/architecture.md):
 *           - Unilateral client refund is ONLY possible when the delivery deadline has
 *             passed AND no proof was ever submitted.
 *           - Once a proof exists, funds can only move via approval, auto-release,
 *             or a mutually accepted resolution.
 */
contract OviaEscrow {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum State {
        None,           // channel does not exist
        Funded,         // funds locked, awaiting proof (also the post-reject state)
        ProofSubmitted, // proof delivered, review window running
        Settled,        // paid out (fully or via accepted split)
        Refunded        // fully refunded to client (deadline expired, no proof)
    }

    struct Channel {
        address client;
        address freelancer;
        address token;            // address(0) = native ETH
        uint256 amount;           // total escrowed amount
        uint64  deliveryDeadline; // unix timestamp by which the FIRST proof must arrive
        uint32  reviewPeriod;     // seconds the client has to approve/reject a proof
        uint64  proofSubmittedAt; // timestamp of the latest proof submission
        bytes32 proofHash;        // latest proof-of-delivery hash (e.g. keccak256 of deliverable / IPFS CID)
        uint16  rejections;       // number of times the client rejected a proof
        State   state;
    }

    struct Resolution {
        address proposer;         // client or freelancer
        uint16  freelancerBps;    // share of `amount` for the freelancer, in basis points (0–10000)
        bool    active;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 public nextChannelId = 1;
    mapping(uint256 => Channel) public channels;
    mapping(uint256 => Resolution) public resolutions;

    // Minimal on-chain reputation (v1). A richer reputation graph moves to its
    // own contract in v2; events below already feed any off-chain indexer.
    mapping(address => uint64)  public jobsCompleted;   // freelancer: settled channels
    mapping(address => uint256) public volumeSettled;   // freelancer: total value received (per-token mixing avoided off-chain via events)

    // Protocol fee (charged on the freelancer payout only).
    uint16 public constant MAX_FEE_BPS = 500; // hard cap: 5%
    uint16 public feeBps;
    address public feeRecipient;
    address public owner;

    // Reentrancy guard.
    uint256 private _locked = 1;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ChannelCreated(
        uint256 indexed channelId,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 amount,
        uint64 deliveryDeadline,
        uint32 reviewPeriod
    );
    event ProofSubmitted(uint256 indexed channelId, bytes32 proofHash, uint64 timestamp);
    event ProofRejected(uint256 indexed channelId, uint16 rejectionCount);
    event ChannelSettled(
        uint256 indexed channelId,
        uint256 freelancerPaid,
        uint256 clientRefunded,
        uint256 fee
    );
    event ChannelRefunded(uint256 indexed channelId, uint256 amount);
    event ResolutionProposed(uint256 indexed channelId, address indexed proposer, uint16 freelancerBps);
    event ResolutionWithdrawn(uint256 indexed channelId);
    event ResolutionAccepted(uint256 indexed channelId, uint16 freelancerBps);
    event FeeUpdated(uint16 feeBps, address feeRecipient);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotClient();
    error NotFreelancer();
    error NotParticipant();
    error NotOwner();
    error InvalidState();
    error InvalidParams();
    error DeadlineNotPassed();
    error ProofWasSubmitted();
    error ReviewWindowClosed();
    error ReviewWindowOpen();
    error NoActiveResolution();
    error CannotAcceptOwnResolution();
    error TransferFailed();
    error Reentrancy();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(uint16 _feeBps, address _feeRecipient) {
        if (_feeBps > MAX_FEE_BPS) revert InvalidParams();
        if (_feeBps > 0 && _feeRecipient == address(0)) revert InvalidParams();
        owner = msg.sender;
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeUpdated(_feeBps, _feeRecipient);
    }

    // ---------------------------------------------------------------------
    // Channel lifecycle
    // ---------------------------------------------------------------------

    /**
     * @notice Create and fund a channel in a single transaction.
     * @param freelancer       Counterparty that will deliver the work.
     * @param token            ERC20 token address, or address(0) for native ETH.
     * @param amount           Amount to escrow (msg.value for ETH).
     * @param deliveryDeadline Unix timestamp by which the first proof must be submitted.
     * @param reviewPeriod     Seconds the client has to review each proof (1 hour – 30 days).
     */
    function createChannel(
        address freelancer,
        address token,
        uint256 amount,
        uint64 deliveryDeadline,
        uint32 reviewPeriod
    ) external payable nonReentrant returns (uint256 channelId) {
        if (freelancer == address(0) || freelancer == msg.sender) revert InvalidParams();
        if (amount == 0) revert InvalidParams();
        if (deliveryDeadline <= block.timestamp) revert InvalidParams();
        if (reviewPeriod < 1 hours || reviewPeriod > 30 days) revert InvalidParams();

        if (token == address(0)) {
            if (msg.value != amount) revert InvalidParams();
        } else {
            if (msg.value != 0) revert InvalidParams();
            if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
                revert TransferFailed();
            }
        }

        channelId = nextChannelId++;
        channels[channelId] = Channel({
            client: msg.sender,
            freelancer: freelancer,
            token: token,
            amount: amount,
            deliveryDeadline: deliveryDeadline,
            reviewPeriod: reviewPeriod,
            proofSubmittedAt: 0,
            proofHash: bytes32(0),
            rejections: 0,
            state: State.Funded
        });

        emit ChannelCreated(
            channelId, msg.sender, freelancer, token, amount, deliveryDeadline, reviewPeriod
        );
    }

    /**
     * @notice Freelancer submits (or resubmits after a rejection) a proof-of-delivery hash.
     * @dev    The first proof must arrive before the delivery deadline. Resubmissions after
     *         a rejection are allowed even past the deadline, since the freelancer already
     *         demonstrated delivery intent.
     */
    function submitProof(uint256 channelId, bytes32 proofHash) external {
        Channel storage c = channels[channelId];
        if (msg.sender != c.freelancer) revert NotFreelancer();
        if (c.state != State.Funded) revert InvalidState();
        if (proofHash == bytes32(0)) revert InvalidParams();

        bool isFirstProof = c.proofHash == bytes32(0);
        if (isFirstProof && block.timestamp > c.deliveryDeadline) revert InvalidParams();

        c.proofHash = proofHash;
        c.proofSubmittedAt = uint64(block.timestamp);
        c.state = State.ProofSubmitted;

        emit ProofSubmitted(channelId, proofHash, uint64(block.timestamp));
    }

    /// @notice Client approves the delivered work: instant full settlement to the freelancer.
    function approve(uint256 channelId) external nonReentrant {
        Channel storage c = channels[channelId];
        if (msg.sender != c.client) revert NotClient();
        if (c.state != State.ProofSubmitted) revert InvalidState();

        _settle(channelId, c, 10_000);
    }

    /**
     * @notice Auto-release: if the client neither approved nor rejected within the review
     *         period, anyone may trigger full settlement to the freelancer.
     */
    function release(uint256 channelId) external nonReentrant {
        Channel storage c = channels[channelId];
        if (c.state != State.ProofSubmitted) revert InvalidState();
        if (block.timestamp <= uint256(c.proofSubmittedAt) + c.reviewPeriod) {
            revert ReviewWindowOpen();
        }

        _settle(channelId, c, 10_000);
    }

    /**
     * @notice Client rejects the submitted proof within the review window.
     *         The channel returns to Funded; the freelancer may resubmit, or either
     *         party may propose a split resolution.
     */
    function reject(uint256 channelId) external {
        Channel storage c = channels[channelId];
        if (msg.sender != c.client) revert NotClient();
        if (c.state != State.ProofSubmitted) revert InvalidState();
        if (block.timestamp > uint256(c.proofSubmittedAt) + c.reviewPeriod) {
            revert ReviewWindowClosed();
        }

        c.state = State.Funded;
        unchecked { c.rejections++; }

        emit ProofRejected(channelId, c.rejections);
    }

    /**
     * @notice Full unilateral refund to the client — ONLY when the delivery deadline
     *         passed and no proof was ever submitted. Once any proof exists, funds can
     *         only move via approval, auto-release, or an accepted resolution.
     */
    function refundExpired(uint256 channelId) external nonReentrant {
        Channel storage c = channels[channelId];
        if (msg.sender != c.client) revert NotClient();
        if (c.state != State.Funded) revert InvalidState();
        if (block.timestamp <= c.deliveryDeadline) revert DeadlineNotPassed();
        if (c.proofHash != bytes32(0)) revert ProofWasSubmitted();

        c.state = State.Refunded;
        _transferOut(c.token, c.client, c.amount);

        emit ChannelRefunded(channelId, c.amount);
    }

    // ---------------------------------------------------------------------
    // Mutual resolution (dispute path without oracles)
    // ---------------------------------------------------------------------

    /**
     * @notice Either party proposes to close the channel at a given split.
     *         Proposing again overwrites the previous proposal.
     * @param freelancerBps Share for the freelancer in basis points (0 = full refund
     *        to client, 10000 = full payout to freelancer).
     */
    function proposeResolution(uint256 channelId, uint16 freelancerBps) external {
        Channel storage c = channels[channelId];
        if (msg.sender != c.client && msg.sender != c.freelancer) revert NotParticipant();
        if (c.state != State.Funded && c.state != State.ProofSubmitted) revert InvalidState();
        if (freelancerBps > 10_000) revert InvalidParams();

        resolutions[channelId] =
            Resolution({proposer: msg.sender, freelancerBps: freelancerBps, active: true});

        emit ResolutionProposed(channelId, msg.sender, freelancerBps);
    }

    /// @notice Proposer withdraws their open proposal.
    function withdrawResolution(uint256 channelId) external {
        Resolution storage r = resolutions[channelId];
        if (!r.active) revert NoActiveResolution();
        if (msg.sender != r.proposer) revert NotParticipant();

        delete resolutions[channelId];
        emit ResolutionWithdrawn(channelId);
    }

    /// @notice Counterparty accepts the open proposal: the channel settles at the split.
    function acceptResolution(uint256 channelId) external nonReentrant {
        Channel storage c = channels[channelId];
        Resolution memory r = resolutions[channelId];

        if (!r.active) revert NoActiveResolution();
        if (msg.sender != c.client && msg.sender != c.freelancer) revert NotParticipant();
        if (msg.sender == r.proposer) revert CannotAcceptOwnResolution();
        if (c.state != State.Funded && c.state != State.ProofSubmitted) revert InvalidState();

        delete resolutions[channelId];
        emit ResolutionAccepted(channelId, r.freelancerBps);

        _settle(channelId, c, r.freelancerBps);
    }

    // ---------------------------------------------------------------------
    // Internal settlement
    // ---------------------------------------------------------------------

    /// @dev Settles a channel: `freelancerBps` of `amount` to the freelancer (minus
    ///      protocol fee), remainder back to the client. Follows checks-effects-interactions.
    function _settle(uint256 channelId, Channel storage c, uint16 freelancerBps) internal {
        c.state = State.Settled;

        uint256 freelancerGross = (c.amount * freelancerBps) / 10_000;
        uint256 clientRefund = c.amount - freelancerGross;
        uint256 fee = (freelancerGross * feeBps) / 10_000;
        uint256 freelancerNet = freelancerGross - fee;

        // Reputation (v1: simple counters; the event stream feeds richer graphs).
        if (freelancerGross > 0) {
            unchecked {
                jobsCompleted[c.freelancer]++;
                volumeSettled[c.freelancer] += freelancerGross;
            }
        }

        if (freelancerNet > 0) _transferOut(c.token, c.freelancer, freelancerNet);
        if (clientRefund > 0) _transferOut(c.token, c.client, clientRefund);
        if (fee > 0) _transferOut(c.token, feeRecipient, fee);

        emit ChannelSettled(channelId, freelancerNet, clientRefund, fee);
    }

    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        }
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFee(uint16 _feeBps, address _feeRecipient) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert InvalidParams();
        if (_feeBps > 0 && _feeRecipient == address(0)) revert InvalidParams();
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeUpdated(_feeBps, _feeRecipient);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidParams();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Convenience getter returning the full channel struct.
    function getChannel(uint256 channelId) external view returns (Channel memory) {
        return channels[channelId];
    }

    /// @notice Timestamp after which `release` becomes callable (0 if no proof pending).
    function releasableAt(uint256 channelId) external view returns (uint256) {
        Channel storage c = channels[channelId];
        if (c.state != State.ProofSubmitted) return 0;
        return uint256(c.proofSubmittedAt) + c.reviewPeriod;
    }
}
