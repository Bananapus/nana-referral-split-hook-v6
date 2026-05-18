# Style Guide

This repo follows the Juicebox V6 ecosystem style guide. See [`nana-core-v6/STYLE_GUIDE.md`](https://github.com/Bananapus/nana-core-v6/blob/main/STYLE_GUIDE.md) for the canonical version — when in doubt, match what `nana-core-v6` does.

## Highlights specific to this repo

- One contract per file. The contract here is small enough that this is trivial.
- Named arguments at every call site with more than two parameters.
- Errors are typed (`error JBReferralSplitHook_*`), not string reverts.
- Events are emitted from the contract that owns the state mutation. `Deposit`/`Push`/`Skipped` are emitted here, not from the controller or the distributor.
- Solidity `0.8.28` pinned in contracts/libraries; `^0.8.0` in interfaces/structs.
