# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Single split-hook contract attached to the fee project's reserved-token group |
| Control posture | Constructor-set immutables; no admin keys, no pause, no upgradeability |
| Highest-risk actions | Mis-wiring the split, mis-pairing terminal/store/distributor at deploy, missing sucker MINT_TOKENS permission |
| Recovery posture | Almost everything is recoverable through re-deployment of a fresh hook with corrected immutables — no state migration needed since the volume ledger lives on `JBTerminalStore`, not here |

## Purpose

`nana-referral-split-hook-v6` is the small, opinionated router that turns the fee project's reserved-token stream into per-referrer rewards. Administration is intentionally minimal: this is the kind of contract you deploy once per `(TERMINAL, FEE_PROJECT_ID)` pair, wire into a ruleset, and stop touching.

## Control Model

- All authority is encoded into the constructor's immutable arguments. There is no admin key, no role assignment after deploy, no pause, no upgrade path.
- Authorization on `processSplitWith` is **caller-driven**: the function checks that `msg.sender == DIRECTORY.controllerOf(FEE_PROJECT_ID)` and that the in-flight split belongs to `FEE_PROJECT_ID`.
- Authorization on `bridgeRemote` and `claimAndPush` is **caller-driven + sucker-driven**: the caller supplies a sucker; the hook verifies it's a registered sucker of the fee project and that its `peerChainId()` matches the asserted chain.
- Authorization on `burnUnbridgeableCreditFor` is **state-driven**: the hook iterates the fee project's registered suckers and refuses to burn if ANY peer to the asserted chain. There's no role check.

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Fee project owner | Owns project NFT for `FEE_PROJECT_ID` | Wiring the hook into reserved-token splits, managing suckers, granting sucker `MINT_TOKENS` permission | Not a role the hook checks — it's a role required upstream to put the hook in place |
| Permissionless caller | Any address | `pushTo`, `bridgeRemote`, `claimAndPush`, `burnUnbridgeableCreditFor` | All four settle-side entrypoints are permissionless; correctness comes from on-chain checks, not access control |
| Controller | `DIRECTORY.controllerOf(FEE_PROJECT_ID)` | Only legal caller of `processSplitWith` | Whoever holds the controller for the fee project authorizes deposits |

## Privileged Surfaces

- **`processSplitWith`** — only the fee project's current controller can call this. A controller swap on `FEE_PROJECT_ID` swaps the deposit authority. Auditors should follow `JBDirectory.controllerOf(FEE_PROJECT_ID)` to know who's actually live.
- **`bridgeRemote` and `claimAndPush`** — anyone can call. The sucker registry + peerChainId pair are the trust anchor: if the registry is compromised, value can be misrouted.
- **`burnUnbridgeableCreditFor`** — anyone can call. The on-chain sucker iteration prevents griefing legitimate referrers; the only way to grief is to compromise the registry or the peer-chain lookup.
- **Constructor parameters** — `TERMINAL`, `STORE`, `DIRECTORY`, `TOKENS`, `DISTRIBUTOR`, `SUCKER_REGISTRY`, `FEE_PROJECT_ID` are immutable. Any of them being wrong at deploy makes the hook permanently mis-routed.

## Immutable And One-Way

- All immutables are set in the constructor and cannot be changed.
- `pushedLocallyOf[refProjectId]` and `bridgedOutOf[chainId][refProjectId]` are monotonic high-water marks — they only ever grow.
- `totalDeposited` is monotonic via `processSplitWith` — only the controller can grow it, nothing can shrink it.
- A `bridgeRemote` insertion into the sucker's outbox is irreversible once the sucker's bridge runs.
- A `claimAndPush` settlement consumes the sucker leaf (executed bitmap set) — that leaf is single-use forever, regardless of whether the destination side burned or forwarded.

## Operational Notes

- After deploying the hook, the fee project owner must:
  1. Queue a ruleset whose reserved-token group's `splits[]` includes `{percent: X, hook: hook, projectId: 0, beneficiary: address(0)}` for the carve-out.
  2. Grant the fee project's suckers `MINT_TOKENS` permission so `claim` can mint destination fee-project tokens to the hook. The sucker registry does NOT do this automatically.
- Run a same-chain `pushTo` happy-path against a referrer with a deployed ERC-20 before relying on the hook in production. The store-mocked unit tests cover the wiring, but a live `sendReservedTokensToSplitsOf` proves the controller permissions and split table are correct.
- Cross-chain claims need real terminal-token funding on the sucker (for `_handleClaim`'s `addToBalance`). The bridge moves these naturally; in tests, fund explicitly via `vm.deal`/`mint`.

## Recovery

- **Wrong constructor immutables** — redeploy. The fee project's ruleset's split table needs to point at the new hook address. `feeVolumeByReferralOf` is unaffected (it lives on `JBTerminalStore`), so historical credit is preserved across re-deployments.
- **Hook deployed without a working `IJBDistributor`** — redeploy. Pending deposits in the old hook are stranded as fee-project tokens at that address; recovery requires governance to transfer them (`burnTokensOf` against `address(oldHook)` is callable only by the oldHook itself, so this is a one-way loss unless governance writes a recovery script).
- **Missing sucker `MINT_TOKENS` permission** — grant it. `claimAndPush` reverts in this state with `JBPermissioned_Unauthorized`. After granting, retry the claim — the leaf is still in the inbox.
- **Unbridgeable credit accumulating in the pool** — anyone calls `burnUnbridgeableCreditFor(chainId, projectId)`. Bridged terminal-token value already in the fee project's balance flows pro-rata to existing fee-token holders.

## Admin Boundaries

- The hook **does not** create or modify the volume ledger (`JBTerminalStore.feeVolumeByReferralOf`). Anything that looks like a volume problem is an upstream bug.
- The hook **does not** decide what the fee project's reserved percent is, who the fee project owner is, or which ruleset is currently active. It reacts to whatever the controller passes in.
- The hook **does not** govern the distributor's vesting rounds, snapshot timing, or staker eligibility. It funds the distributor; the distributor decides who can claim and when.
- The hook **does not** deploy suckers, map sucker tokens, or set sucker peers. It consumes the sucker registry as a read-only source of truth.

## Source Map

- `src/JBReferralSplitHook.sol` — the contract
- `src/interfaces/IJBReferralSplitHook.sol` — interface (events + errors + view signatures + entrypoints)
