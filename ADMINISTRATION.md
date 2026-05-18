# Administration

## Roles

This contract has no admin role. There is no owner, no pause, no upgrade path. Once deployed and wired into the fee project's reserved-token splits, behavior is deterministic.

## Operational Levers

The only operational lever is the fee project's split configuration:

- **Adding the hook**: the fee project owner adds `JBReferralSplitHook` as a split with `groupId = 1` (reserved tokens), `hook = address(JBReferralSplitHook)`, and a `percent` chosen for the desired carve-out.
- **Removing the hook**: the fee project owner queues a new ruleset whose reserved-token splits omit this hook. Any tokens already deposited remain claimable via `pushTo` indefinitely.
- **Adjusting the carve-out**: queue a new ruleset with a different `percent` for the hook's split. The change applies starting at the next cycle.

## Maintenance

- No regular maintenance required.
- `pushTo(referralProjectId)` is permissionless — anyone (the referring project's owner, a keeper, a frontend) can trigger forwarding.
- If a referring project tokenizes after some deposits have already flowed, a `pushTo` call after tokenization will release their accumulated share.

## Monitoring

- `Deposit(amount, newTotalDeposited)` — every reserved-token split that reaches this hook.
- `Push(referralProjectId, referralToken, amount)` — every successful forward to the distributor.
- `Skipped(referralProjectId, reason)` — pushes that no-op (credit-only project, dust below `pushedOf`, etc.).

Off-chain consumers indexing these events can drive automated `pushTo` calls.
