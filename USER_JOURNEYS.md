# User Journeys

## Repo Purpose

This repo routes the fee project's reserved-token allocation to active referrers. It splits the same pool three ways depending on where the referrer lives: same-chain holders are pushed straight into the local distributor; cross-chain referrers are bridged through the fee project's sucker; credit for chains the project never reached is permissionlessly burned to the surplus.

## Primary Actors

- **Fee project owner** wires the hook into the reserved-token split group and grants suckers `MINT_TOKENS` permission.
- **Frontend operator / keeper** indexes referral activity and triggers `pushTo`, `bridgeRemote`, `claimAndPush`, and `burnUnbridgeableCreditFor`.
- **Referring project's holder** receives vesting rewards through the configured distributor.
- **Cross-chain settler** runs the destination-side `claimAndPush` after a bridge round-trip.
- **Auditor / indexer** verifies pro-rata math and burn invariants from event logs and storage reads.

## Key Surfaces

- `JBReferralSplitHook.processSplitWith` — controller-only entrypoint that grows `totalDeposited`
- `JBReferralSplitHook.pushTo` — same-chain forward to the distributor
- `JBReferralSplitHook.bridgeRemote` — cross-chain cash-out into the fee project's sucker outbox
- `JBReferralSplitHook.claimAndPush` — settle a bridged credit on the destination chain
- `JBReferralSplitHook.burnUnbridgeableCreditFor` — permissionless burn for credits on chains with no sucker pair
- `JBTerminalStore.feeVolumeByReferralOf` / `totalFeeVolumeOf` — the upstream volume ledger (normalized to NATIVE_TOKEN 18-dec)

## Journey 1: Fee Project Owner Wires The Hook Into Reserved Splits

**Actor:** fee project owner.

**Intent:** route a configurable carve-out of the fee project's reserved-token allocation through the referral system.

**Preconditions**
- `JBReferralSplitHook` is deployed at the CREATE2-deterministic address used across chains
- `JBTokenDistributor` is deployed and the hook's `DISTRIBUTOR` immutable points at it
- The fee project's ERC-20 is deployed (`JBController.deployERC20For(...)`)

**Main Flow**
1. Queue a new ruleset for the fee project whose reserved-token group includes the hook:
   - `groupId = JBSplitGroupIds.RESERVED_TOKENS` (= 1)
   - `hook = address(JBReferralSplitHook)`
   - `percent` = the carve-out (e.g. 30% of reserved tokens)
2. Once the ruleset takes effect, every `sendReservedTokensToSplitsOf(FEE_PROJECT_ID)` call routes the carve-out into the hook's `processSplitWith`, growing `totalDeposited`.

**Failure Modes**
- Wrong `groupId` → tokens never reach the hook
- Missing controller authorization → `processSplitWith` reverts (`JBReferralSplitHook_Unauthorized`)

**Postconditions**
- Reserved-token distributions continuously fund the hook's pool.

## Journey 2: Frontend Operator Drives Per-Referrer Pushes

**Actor:** frontend or keeper.

**Intent:** turn accumulated credit into actual distributions for each known referrer, on the right chain.

**Preconditions**
- The fee project's reserved tokens have been distributed at least once (`totalDeposited > 0`)
- The operator can read `feeVolumeByReferralOf` and `suckersOf(FEE_PROJECT_ID)` to plan routing

**Main Flow**
1. Index `JBTerminalStore.ReferralCredit(terminal, chainId, refId, amount, newTotal)` events to identify active referrers.
2. For each `(chainId, refId)`:
   - If `chainId == block.chainid`: call `hook.pushTo(chainId, refId)`. The hook forwards `entitled - pushedLocallyOf[refId]` to the distributor.
   - If `chainId != block.chainid` AND a sucker exists peered to `chainId`: call `hook.bridgeRemote(chainId, refId, sucker, terminalToken)`. The hook cashes out the entitled share via the sucker, inserting a leaf into the outbox.
   - If `chainId != block.chainid` AND NO sucker peers to `chainId`: anyone calls `hook.burnUnbridgeableCreditFor(chainId, refId)`. The hook burns the entitled fee-project tokens.
3. After a `bridgeRemote` round-trip, the destination-side hook (same address by CREATE2 convention) calls `claimAndPush(originChainId, refId, sucker, claimData)` to settle.

**Failure Modes**
- Wrong sucker peer (`SuckerPeerMismatch`) — caller bug, retry with the right sucker
- No sucker for chain → use `burnUnbridgeableCreditFor` instead
- Sucker exists but caller calls burn anyway → `SuckerExistsForChain` revert

**Postconditions**
- Per-referrer high-water marks (`pushedLocallyOf` or `bridgedOutOf`) advance; the distributor / outbox / fee-project surplus reflects the settled value.

## Journey 3: Referring Project's Holder Claims Vested Rewards

**Actor:** holder of a referring project's IVotes token.

**Intent:** collect the share of fees attributed to their project.

**Preconditions**
- The referring project has a deployed IVotes-compatible ERC-20
- The holder has delegated (even to themselves) — undelegated balances dilute participation but never claim
- Someone (anyone) has called `pushTo` or `claimAndPush` for the referring project recently enough to fund the distributor

**Main Flow**
1. Wait for someone to call `pushTo` (same-chain) or `claimAndPush` (cross-chain settled) for the referring project — or call it yourself.
2. The distributor's per-hook `_balanceOf` grows by the pushed amount.
3. On the next vesting round, your delegated voting power is snapshotted via `IVotes.getPastVotes`.
4. Call `JBTokenDistributor.beginVesting(refToken, [tokenIdFromAddress], [feeToken])` to start vesting.
5. After the configured vesting horizon, call `collectVestedRewards(refToken, [tokenIdFromAddress], [feeToken], beneficiary)` to receive your pro-rata share.

**Failure Modes**
- Not delegated → `getPastVotes` returns 0 → no claimable share
- Wrong tokenId encoding → distributor rejects (token distributor encodes the staker's address as `uint256(uint160(staker))`)

**Postconditions**
- Fee-project tokens transfer to your wallet, weighted by `delegated / totalSupply` of the referring project's ERC-20.

## Journey 4: Cross-Chain Settler Claims A Bridged Credit

**Actor:** anyone with the merkle proof for an inbox leaf.

**Intent:** settle a cross-chain bridged credit on the destination chain.

**Preconditions**
- A `bridgeRemote` call already inserted a leaf into the source sucker's outbox
- The source sucker's `toRemote` has delivered the root to the destination sucker's inbox (real bridge — OP, Base, Arbitrum, CCIP, etc.)
- The destination sucker has `MINT_TOKENS` permission on the fee project
- The destination's local twin (`TOKENS.tokenOf(refProjectId)`) is either deployed (forward path) or absent (burn path) — both are acceptable

**Main Flow**
1. Build the `JBClaim` struct: `{token, leaf: {index, beneficiary, projectTokenCount, terminalTokenAmount, metadata}, proof}`.
2. Confirm `leaf.beneficiary == address(this)` (the hook on the destination chain).
3. Call `hook.claimAndPush(originChainId, refProjectId, sucker, claimData)`. The hook calls `sucker.claim`, which validates the proof, mints fee-project tokens to the hook, and adds the bridged terminal tokens to the fee project's balance.
4. If the local twin's IVotes token exists, the hook forwards the freshly-minted fee-project tokens to the local distributor.
5. If the local twin doesn't exist, the hook burns the freshly-minted fee-project tokens — the bridged terminal-token value remains in the fee project's balance as pro-rata surplus.

**Failure Modes**
- Leaf metadata mismatch (`LeafMetadataMismatch`) — caller asserted the wrong projectId
- Leaf already consumed (`LeafAlreadyExecuted` from the sucker) — single-use
- Sucker lacks `MINT_TOKENS` permission — grant and retry

**Postconditions**
- Sucker leaf is permanently consumed. Either the local twin's distributor balance grew, or the fee project's surplus grew via burn.

## Journey 5: Auditor / Indexer Verifies A Push

**Actor:** auditor or off-chain indexer.

**Intent:** confirm the hook's per-referrer settlements match the pro-rata math.

**Preconditions**
- Indexer has read access to `JBTerminalStore`, the hook, and event logs

**Main Flow**
1. Read `JBTerminalStore.totalFeeVolumeOf(terminal)` and `JBTerminalStore.feeVolumeByReferralOf(terminal, chainId, refId)`.
2. Read `JBReferralSplitHook.totalDeposited()`, `pushedLocallyOf(refId)`, `bridgedOutOf(chainId, refId)`.
3. Predict the next push/bridge/burn amount:
   - Same-chain: `mulDiv(totalDeposited, refVol_local, totalVol) - pushedLocallyOf[refId]`
   - Cross-chain: `mulDiv(totalDeposited, refVol_chain, totalVol) - bridgedOutOf[chainId][refId]`
   - Clamp at 0.
4. Cross-check against the latest `Push`, `BridgedRemote`, `ClaimedRemote`, `BurnedOnStrand`, or `BurnedUnbridgeable` event.

**Postconditions**
- The indexer can audit any per-referrer flow against on-chain state without trusting the hook's emitted events alone.

## Trust Boundaries

- The hook trusts `JBDirectory.controllerOf(FEE_PROJECT_ID)` to gate `processSplitWith`.
- The hook trusts `JBTerminalStore` to publish a coherent, currency-normalized volume ledger.
- The hook trusts `JBSuckerRegistry.suckersOf` + each sucker's `peerChainId()` to identify destinations.
- The hook trusts the sucker's merkle proof + the leaf's `metadata` payload to authenticate cross-chain claims.
- The hook trusts the destination-side `TOKENS.tokenOf(refProjectId)` to either be a real IVotes ERC-20 or `address(0)`.

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) when the question is "how did the volume ledger record this?".
- Use [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) when the question is about bridge mechanics (prepare, toRemote, fromRemote, claim).
- Use [nana-distributor-v6](../nana-distributor-v6/USER_JOURNEYS.md) when the question is about staker collection, vesting timing, or undelegated dilution.
