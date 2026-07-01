# Ovia Smart Contracts

Core escrow & auto-settlement logic for the Ovia protocol. Built with Hardhat (runs natively on Windows, macOS and Linux).

## Contracts

| Contract | Description |
|---|---|
| `src/OviaEscrow.sol` | Escrow channels: create/fund → proof-of-delivery → approve / auto-release / reject → settle. Includes a mutual split-resolution mechanism and minimal on-chain reputation counters. |
| `src/mocks/MockERC20.sol` | Test-only ERC20 for the token path. |

See [`../docs/architecture.md`](../docs/architecture.md) for the full state machine and design rationale.

## Setup

Requires Node.js 18+.

```bash
cd contracts
npm install
npm test
```

## Deploy (Base Sepolia)

Copy `.env.example` to `.env` and fill in `ALCHEMY_API_KEY`, `PRIVATE_KEY` (a funded testnet key) and optionally `BASESCAN_API_KEY`, `FEE_BPS`, `FEE_RECIPIENT`. Then:

```bash
npm run deploy:testnet
```

The script prints the deployed address plus the exact `hardhat verify` command for Basescan. Fee is hard-capped at 500 bps (5%); pass `FEE_BPS=0` to run fee-free.

## Status

- [x] Escrow contract (v1)
- [x] Hardhat test suite (13 tests)
- [ ] Testnet deployment (Base Sepolia)
- [ ] Audit / review pass
- [ ] Mainnet deployment
