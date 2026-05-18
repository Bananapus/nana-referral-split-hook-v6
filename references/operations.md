# Operations Reference

Operator-facing notes for deploying, wiring, and maintaining a `JBReferralSplitHook`.

## Deploy

The deploy script reads six environment variables:

| Variable | Description |
| --- | --- |
| `DIRECTORY_ADDRESS` | Address of the deployed `JBDirectory`. |
| `TERMINAL_STORE_ADDRESS` | Address of the deployed `JBTerminalStore`. |
| `TOKENS_ADDRESS` | Address of the deployed `JBTokens`. |
| `DISTRIBUTOR_ADDRESS` | Address of the `IJBDistributor` you want to forward into (typically `JBTokenDistributor`). |
| `TERMINAL_ADDRESS` | The `JBMultiTerminal` instance whose volume ledger this hook reads from. |
| `FEE_PROJECT_ID` | The project ID receiving fees (1 in canonical deployments). |

```bash
source .env
npm run deploy:mainnets   # or deploy:testnets
```

If you need a hook for a different terminal in the same deployment, run the script again with a different `TERMINAL_ADDRESS`.

## Wire Into Fee Project's Reserved Splits

The hook does nothing until the fee project lists it as a reserved-token split. The fee project owner queues a new ruleset with:

```solidity
JBSplit({
  preferAddToBalance: false,
  percent: <chosen carve-out, in 9-decimal basis>,
  projectId: 0,         // tokens are minted to the hook, not paid into a project
  beneficiary: payable(0),
  lockedUntil: 0,
  hook: IJBSplitHook(address(deployedHook))
})
```

with `groupId = 1` (reserved tokens).

## Decommissioning

To stop new deposits: the fee project queues a new ruleset whose reserved splits omit this hook. The change applies at the next cycle.

Existing balances remain claimable indefinitely — `pushTo` continues to work for any referrer that still has un-pushed accrued volume.

## Common Failure Modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `processSplitWith` reverts `JBReferralSplitHook_Unauthorized` | Wrong controller deployed/configured for fee project | Verify `DIRECTORY.controllerOf(FEE_PROJECT_ID)` returns the canonical controller |
| `processSplitWith` reverts `JBReferralSplitHook_TokenMismatch` | Fee project token changed; hook is stale | Redeploy or update the wiring to ensure `context.token` matches |
| `pushTo` emits `Skipped("no token")` | Referring project hasn't issued an ERC-20 | Referring project calls `JBController.deployERC20For(...)`; re-run `pushTo` |
| `pushTo` emits `Skipped("caught up")` | Referrer's `entitled` hasn't grown since last push | Wait for more deposits or more attributed volume |
| `pushTo` reverts inside `DISTRIBUTOR.fund` | Distributor rejected the deposit (paused, malformed token, etc.) | Check distributor state; pushed-of mutation reverts atomically so retry is safe |
