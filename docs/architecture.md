# Ovia Protocol — Architecture (v1)

> Status: draft · Scope: escrow core (`OviaEscrow.sol`)

## 1. Overview

Ovia v1 is a **non-custodial escrow and auto-settlement protocol** for work agreements between two parties: a **client** (payer) and a **freelancer** (deliverer). Funds are locked in a channel at creation and can only move along paths both parties agreed to in advance — encoded in the contract, not in a platform's terms of service.

The v1 design deliberately avoids oracles, arbitrators, and staking. Every dispute path resolves through either **time** (deadlines and review windows) or **mutual agreement** (split resolutions). This keeps the trust assumptions minimal and the attack surface small. Richer proof verification (attestations, oracle feeds, zk-proofs of delivery) is a v2 concern and plugs in behind the same channel interface.

## 2. Roles

| Role | Capabilities |
|---|---|
| Client | Creates & funds channel, approves or rejects proofs, refunds expired channels, proposes/accepts resolutions |
| Freelancer | Submits proofs, proposes/accepts resolutions |
| Anyone | Triggers `release` once the review window lapses (keeper-friendly) |
| Owner | Sets protocol fee (≤ 5% hard cap) and fee recipient; **cannot touch channel funds** |

## 3. Channel state machine

```
                createChannel (funds locked)
                          │
                          ▼
        ┌────────────► FUNDED ◄───────────┐
        │                 │               │
        │        submitProof (freelancer) │ reject (client,
        │                 │               │ within review window)
        │                 ▼               │
        │          PROOF_SUBMITTED ───────┘
        │           │           │
        │   approve │           │ release (anyone,
        │  (client) │           │ after review window)
        │           ▼           ▼
        │         SETTLED ◄── SETTLED
        │
        │  refundExpired (client, deadline passed
        │  AND no proof ever submitted)
        │
        ▼
    REFUNDED

  From FUNDED or PROOF_SUBMITTED, either party may proposeResolution(bps);
  when the counterparty accepts, the channel moves to SETTLED at that split.
```

## 4. Settlement paths

1. **Approve** — client confirms delivery → full payout to freelancer, instantly.
2. **Auto-release** — client stays silent for the full review window → anyone can trigger full payout. Silence is consent; this is what removes the "net-30 + chase the invoice" problem.
3. **Mutual resolution** — either party proposes a split in basis points (0–10000 to the freelancer); the counterparty accepts → payout at that split. This is the entire dispute mechanism in v1.
4. **Expired refund** — the delivery deadline passes and **no proof was ever submitted** → client reclaims everything unilaterally.

The protocol fee (if enabled) applies only to the freelancer's share, never to client refunds.

## 5. Griefing analysis

| Attack | Mitigation |
|---|---|
| Client ignores a valid proof to freeze payment | Auto-release after the review window; silence pays out |
| Client rejects at the last second, then claims an expired-deadline refund | `refundExpired` is blocked forever once any proof has been submitted |
| Client rejects endlessly to stall | Funds are equally frozen for the client; rejection count is public (reputation signal); the split-resolution path is the pressure valve |
| Freelancer submits a junk proof to start the clock | Client rejects within the review window at negligible cost; repeated junk shows in `rejections` |
| Reentrancy on payout | Checks-effects-interactions + mutex guard; state set to `Settled` before any transfer |
| Owner rug | Owner can only adjust the fee (hard-capped at 5%) and its recipient; no path to channel funds |

Known v1 limitations, accepted consciously:

- **Fee-on-transfer / rebasing ERC20s are unsupported.** The contract assumes `amount` in equals `amount` out. Documented, not defended — use vanilla tokens (USDC, WETH).
- **A mutual stalemate can lock funds indefinitely.** If both parties refuse every resolution, nothing moves. This is by design: no third party can be given power over the funds without reintroducing trust. v2 may add opt-in arbitration.
- **Proof hashes are opaque to the contract.** v1 verifies *agreement about* a proof, not the proof itself. The `proofHash` convention (e.g. keccak256 of the deliverable or an IPFS CID) lives at the SDK layer.

## 6. Reputation (v1)

Two on-chain counters per freelancer — `jobsCompleted` and `volumeSettled` — plus a complete event stream (`ChannelSettled`, `ProofRejected`, …) that any indexer can turn into a richer graph. A dedicated reputation contract with client-side scores, decay, and cross-channel identity is scheduled for v2.

## 7. Deployment target

Primary target: **Base** (testnet: Base Sepolia). Low fees suit small work contracts; the existing Ovia Labs infrastructure (Alchemy) already covers Base RPC.

## 8. Roadmap to v2

- Pluggable `IProofVerifier` modules (attestations / EAS, oracle-verified delivery, API webhooks via signed messages)
- Milestone channels (multiple funded tranches per agreement)
- Dedicated reputation graph contract
- Opt-in arbitration module (both parties pre-select an arbiter at channel creation)
- Meta-transaction support so freelancers without gas can submit proofs
