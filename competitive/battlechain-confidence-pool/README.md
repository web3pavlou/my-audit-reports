# BattleChain Confidence Pool — Competitive Audit (Invariant Testing)

> **Status:** CodeHawks competitive audit — July 2026.
> This folder publishes my invariant-testing harness (my own work product) and the methodology
> behind it; All invariant test runs were successful with a 99% coverage of the basic contract ConfidencePool.sol && ConfidencePoolFactory.sol

## Engagement

- **Type:** Competitive audit — [CodeHawks](https://codehawks.cyfrin.io)
- **Target:** `ConfidencePool` + `ConfidencePoolFactory` (BattleChain Safe Harbor "confidence pools") and their parent contracts.
- **Tooling:** [Echidna](https://github.com/crytic/echidna) (stateful, assertion mode) + Foundry.
- **Contest repo:** https://github.com/CodeHawks-Contests/2026-07-bc-confidence-pools
- **My submissions / profile:** `https://profiles.cyfrin.io/u/darnwebr22`

## Scope

- **`ConfidencePool`** (EIP-1167 minimal clone) — staking, the k=2 time-weighted bonus accounting, the CORRUPTED bounty/sweep paths, lazy risk-window observation, and resolution + claims.
- **`ConfidencePoolFactory`** (UUPS proxy) — deterministic clone creation, the stake-token allowlist, and the owner levers.
- **Parents (trust boundary, read-only):** the `AttackRegistry` state machine, `Agreement`, `BattleChainSafeHarborRegistry`.

## Approach

Rather than a prose report, the core of this review is a pair of **stateful Echidna harnesses** that drive the system through its full lifecycle (stake -> risk window -> resolution -> claims/sweeps) and assert safety and accounting properties on every step. Reverts from the contract's own gates are treated as dead-end transactions; only a broken `assert()` fails a run.

- **`HCore.sol`** — pool-level handlers + properties, built on a shared `EchidnaSetup` base (mocks, the UUPS factory, one pinned pool, rotating actors, and a bonus contributor / moderator / poker).
- **`ConfidencePoolFactoryE2E.sol`** — factory/clone-level handlers + properties, sharing the same `EchidnaSetup` base.

## Invariant catalog

**Pool (`HCore`)**

| ID | Property |
|----|----------|
| SOL-1 | Phase-indexed solvency: `balanceOf(pool) >= liabilities(phase)` at all times. |
| SOL-2 | Whole-ledger token conservation: `sum(watched wallets) == mintedTotal`. |
| ACC-2 | k=2 sums stay within provable overflow headroom (bounded by expiry^2 * staked). |
| ACC-3 | Global vs per-user identity: `sumStakeTime/Sq == sum(clamp(userSums))` (mirrors `_clampUserSums`). |
| DST-1 | Bonus never over-distributed: `claimedBonus <= snapshotTotalBonus`. |
| DST-2 | Full distribution leaves only integer dust (`< actors` wei). |
| DST-3 | No observed risk window => no staker bonus is ever paid. |
| COR-1 | Attacker never paid beyond entitlement: `bountyClaimed <= bountyEntitlement`. |
| COR-2 | The good-faith attacker-claim deadline is never extendable. |
| LAT-1 | Risk-window markers are write-once and ordered (`start <= end`). |
| LAT-2 | Config locks are one-way; a locked `expiry` is frozen. |
| LAT-3 | Resolution finality: outcome + snapshots freeze once `claimsStarted`. |
| LAT-4 | A claim is forever: `hasClaimed` never clears; claimant can't re-enter. |
| ACL-1 | Ownership always returns to the owner with no dangling pending transfer. |
| ACL-2 | The five setter-less config fields never drift (birth-hash check). |

**Factory (`ConfidencePoolFactoryE2E`)**

| ID | Property |
|----|----------|
| P1 | After a successful `createPool`, the pool is initialized and registered (atomic). |
| P2 | Deterministic address (`created == predicted`); `poolCount` increments by exactly 1. |
| P4 | Standing pool-isolation: no factory action ever reaches into a live pool's config. |
| -- | Config-mirror: every `createPool` argument lands verbatim in pool storage. |
| -- | Gates revert **by selector**: `ExpiryTooSoon`, `StakeTokenNotAllowed`, `EnforcedPause`. |

## Running

These files run inside a checkout of the contest repo. Clone it, drop the four files into `test/echidna/`, then:

```bash
echidna test/echidna/HCore.sol --contract HCore --config test/echidna/HCore.yaml
echidna test/echidna/ConfidencePoolFactoryE2E.sol --contract ConfidencePoolFactoryE2E --config test/echidna/HCore.yaml
```

Assertion mode; `testLimit` in the config is a smoke budget — raise it (5M+) for soak runs.

## Files

| File | What it is |
|------|-----------|
| `echidna/EchidnaSetup.sol` | Shared harness base: mocks, the UUPS factory, one pinned pool, actors, carousels. |
| `echidna/HCore.sol` | Pool handlers + the SOL / ACC / DST / COR / LAT / ACL properties above. |
| `echidna/ConfidencePoolFactoryE2E.sol` | Factory/clone handlers + the P1-P4 properties above. |
| `echidna/HCore.yaml` | Echidna config (assertion mode, seq length, corpus, time/block drift). |

## A note on IP

The harness in this folder is my own work. The contracts under audit are (c) the protocol / sponsor and are **not** vendored here — see the official contest repository above. To run locally, drop these files into that project's `test/echidna/` directory.

---

*Part of [my-audit-reports](../../README.md) — a public track record of my smart-contract security work.*
