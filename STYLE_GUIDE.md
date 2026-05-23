# Style Guide

How we write Solidity and organize repos across the Juicebox V6 ecosystem. `nana-core-v6` is the gold standard — when in doubt, match what it does.

## File Organization

```
src/
├── Contract.sol              # Main contracts in root
├── abstract/                 # Base contracts (JBPermissioned, JBControlled)
├── enums/                    # One enum per file
├── interfaces/               # One interface per file, prefixed with I
├── libraries/                # Pure/view logic, prefixed with JB
├── periphery/                # Utility contracts (deadlines, price feeds)
└── structs/                  # One struct per file, prefixed with JB
```

One contract/interface/struct/enum per file. Name the file after the type it contains.

This repo only ships one contract (`JBReferralSplitHook`) and its interface (`IJBReferralSplitHook`). The `structs/` and `libraries/` directories are absent because the hook owns no project-specific structs and inlines its handful of pure helpers as `private` functions.

## Pragma Versions

```solidity
// Contracts — pin to exact version
pragma solidity 0.8.28;

// Interfaces, structs, enums — caret for forward compatibility
pragma solidity ^0.8.0;

// Libraries — pin to exact version like contracts
pragma solidity 0.8.28;
```

## Imports

Named imports only. Grouped by source, alphabetized within each group:

```solidity
// External packages (alphabetized)
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

// Cross-repo interfaces (alphabetized within each package)
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminalStore} from "@bananapus/core-v6/src/interfaces/IJBTerminalStore.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IJBTokens} from "@bananapus/core-v6/src/interfaces/IJBTokens.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IJBDistributor} from "@bananapus/distributor-v6/src/interfaces/IJBDistributor.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBClaim} from "@bananapus/suckers-v6/src/structs/JBClaim.sol";

// Local interfaces
import {IJBReferralSplitHook} from "./interfaces/IJBReferralSplitHook.sol";
```

## Contract Structure

Section banners divide the contract into a fixed ordering. Every contract with 50+ lines uses these banners:

```solidity
/// @notice One-line description.
contract JBExample is JBPermissioned, IJBExample {
    // A library that does X.
    using SomeLib for SomeType;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JBExample_SomethingFailed(uint256 amount);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    uint256 public constant override FEE = 25;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    uint256 internal constant _FEE_BENEFICIARY_PROJECT_ID = 1;

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    IJBDirectory public immutable override DIRECTORY;

    //*********************************************************************//
    // -------------- internal immutable stored properties -------------- //
    //*********************************************************************//

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------- private stored properties -------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ------------------------- receive / fallback ---------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//
}
```

**Section order:**
1. Custom errors
2. Public constants
3. Internal constants
4. Private constants
5. Public immutable stored properties
6. Internal immutable stored properties
7. Public stored properties
8. Internal stored properties
9. Private stored properties
10. Transient stored properties
11. Constructor
12. Modifiers
13. Receive / fallback
14. External transactions
15. External views
16. Public views
17. Public transactions
18. Internal transactions
19. Internal helpers
20. Internal views
21. Private helpers

Use these additional section labels where they better match the contents of the block:
- `internal functions` is accepted as equivalent to `internal helpers`
- `events` and `structs` are acceptable in specialized contracts that define them explicitly

Functions are alphabetized within each section.

## Interface Structure

```solidity
/// @notice One-line description.
interface IJBExample is IJBBase {
    // Events (with full NatSpec)

    /// @notice Emitted when X happens.
    /// @param projectId The ID of the project.
    /// @param amount The amount transferred.
    event SomethingHappened(uint256 indexed projectId, uint256 amount);

    // Views (alphabetized)

    /// @notice The directory of terminals and controllers.
    function DIRECTORY() external view returns (IJBDirectory);

    // State-changing functions (alphabetized)

    /// @notice Does the thing.
    /// @param projectId The ID of the project.
    /// @return result The result.
    function doThing(uint256 projectId) external returns (uint256 result);
}
```

**Rules:**
- Events first, then views, then state-changing functions
- Errors live in the interface in this repo (matches the existing convention — see `IJBReferralSplitHook`) so consumers can `expectRevert` without importing the implementation
- Full NatSpec on every event, function, and parameter
- Alphabetized within each group

## Naming

| Thing | Convention | Example |
|-------|-----------|---------|
| Contract | PascalCase | `JBReferralSplitHook` |
| Interface | `I` + PascalCase | `IJBReferralSplitHook` |
| Library | PascalCase | `JBCashOuts` |
| Struct | PascalCase | `JBSplitHookContext` |
| Enum | PascalCase | `JBApprovalStatus` |
| Enum value | PascalCase | `ApprovalExpected` |
| Error | `ContractName_ErrorName` | `JBReferralSplitHook_NotASucker` |
| Public constant | `ALL_CAPS` | `FEE`, `MAX_FEE` |
| Internal constant | `_ALL_CAPS` | `_FEE_HOLDING_SECONDS` |
| Public immutable | `ALL_CAPS` | `DIRECTORY`, `FEE_PROJECT_ID` |
| Public/external function | `camelCase` | `bridgeRemote`, `claimAndPush` |
| Internal/private function | `_camelCase` | `_pendingDeltaFor` |
| Internal storage | `_camelCase` | n/a in this repo (no internal storage) |
| Function parameter | `camelCase` (no underscores) | `referralProjectId`, `referralChainId` |

## NatSpec

**Contracts:**
```solidity
/// @notice One-line description of what the contract does.
contract JBExample is IJBExample {
```

**Functions:**
```solidity
/// @notice Bridge a cross-chain referrer's accrued pro-rata share through the fee project's sucker.
/// @param referralChainId The referrer's home EIP-155 chain ID. Must NOT equal `block.chainid`.
/// @param referralProjectId The referring project on that chain.
/// @param sucker The fee project's sucker pair to use.
/// @param terminalToken The terminal token to cash out into.
/// @return bridged The number of fee-project tokens cashed out into the sucker.
function bridgeRemote(
    uint256 referralChainId,
    uint256 referralProjectId,
    IJBSucker sucker,
    address terminalToken
)
    external
    returns (uint256 bridged);
```

**Structs:**
```solidity
/// @custom:member duration The number of seconds the ruleset lasts for. 0 means it never expires.
/// @custom:member weight How many tokens to mint per unit paid (18 decimals).
struct JBRulesetConfig {
    uint32 duration;
    uint112 weight;
}
```

**Mappings:**
```solidity
/// @notice High-water mark of fee-project tokens cashed out via `bridgeRemote` (or burned via
/// `burnUnbridgeableCreditFor`) for a cross-chain referrer.
/// @custom:param referralChainId The referrer's home chain ID.
/// @custom:param referralProjectId The referring project's projectId on `referralChainId`.
mapping(uint256 referralChainId => mapping(uint256 referralProjectId => uint256)) public override bridgedOutOf;
```

## Numbers

Use underscores for thousands separators:

```solidity
uint256 internal constant _FEE_HOLDING_SECONDS = 2_419_200; // 28 days
uint32 public constant MAX_WEIGHT_CUT_PERCENT = 1_000_000_000;
uint256 public constant MAX_RESERVED_PERCENT = 10_000;
```

## Function Calls

Use named arguments for all function calls with 2 or more arguments — in both `src/` and `script/`:

```solidity
// Good — named arguments
IERC20(token).safeTransferFrom({from: msg.sender, to: address(this), value: amount});
DISTRIBUTOR.fund({hook: address(refToken), token: IERC20(address(feeToken)), amount: amount});

// Bad — positional arguments with 2+ args
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
```

Single-argument calls use positional style: `_burn(amount)`.

This also applies to constructor calls, struct literals, and inherited/library calls (e.g., OZ `_mint`, `_safeMint`, `safeTransfer`, `allowance`, `Clones.cloneDeterministic`).

Named argument keys must use **camelCase** — never underscores. If a function's parameter names use underscores, rename them to camelCase first.

## Multiline Signatures

```solidity
function claimAndPush(
    uint256 originChainId,
    uint256 referralProjectId,
    IJBSucker sucker,
    JBClaim calldata claimData
)
    external
    override
    returns (uint256 pushed)
{
```

Modifiers and return types go on their own indented lines.

## Error Handling

- Validate inputs with explicit `revert` + custom error
- Use `try-catch` only for external calls to untrusted contracts (hooks, fee processing)
- Always include relevant context in error parameters
- Errors are typed (`error JBReferralSplitHook_*`), not string reverts

```solidity
// Direct validation
if (referralProjectId == 0 || referralProjectId == FEE_PROJECT_ID) {
    revert JBReferralSplitHook_InvalidReferralProjectId();
}

// External call where reversion is expected behavior (the leaf has the wrong metadata, etc.)
if (claimData.leaf.metadata != expectedMetadata) {
    revert JBReferralSplitHook_LeafMetadataMismatch({expected: expectedMetadata, got: claimData.leaf.metadata});
}
```

---

## DevOps

### foundry.toml

Standard config across all repos:

```toml
[profile.default]
solc = '0.8.28'
evm_version = 'cancun'
optimizer_runs = 200
libs = ["node_modules", "lib"]
fs_permissions = [{ access = "read-write", path = "./"}]

[fuzz]
runs = 4096

[invariant]
runs = 1024
depth = 100
fail_on_revert = false

[fmt]
number_underscore = "thousands"
multiline_func_header = "all"
wrap_comments = true
```

**Optional sections (add only when needed):**
- `[rpc_endpoints]` — repos with fork tests. Maps named endpoints to env vars (e.g. `ethereum = "${RPC_ETHEREUM_MAINNET}"`).
- `[profile.ci_sizes]` — only when CI needs different optimizer settings than defaults for the size check step.

**Common variations:**
- `via_ir = true` when hitting stack-too-deep
- `optimizer = false` when optimization causes stack-too-deep
- `optimizer_runs` reduced when deep struct nesting causes stack-too-deep at 200 runs

### CI Workflows

Every repo has at minimum `test.yml` and `lint.yml`:

**test.yml:**
```yaml
name: test
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  forge-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: actions/setup-node@v4
        with:
          node-version: 25.9.0
      - name: Install npm dependencies
        run: npm install --omit=dev
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Run tests
        run: forge test --deny notes --fail-fast --summary --detailed --skip "*/script/**"
        env:
          RPC_ETHEREUM_MAINNET: ${{ secrets.RPC_ETHEREUM_MAINNET }}
      - name: Check contract sizes
        run: forge build --deny notes --sizes --skip "*/test/**" --skip "*/script/**" --skip SphinxUtils
```

**lint.yml:**
```yaml
name: lint
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  forge-fmt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      - name: Check formatting
        run: forge fmt --check
```

Build and lint commands must be clean: no warnings and no notes. CI uses `forge build --deny notes ...` so any new compiler or linter warning fails the PR. Only exclude a lint in `foundry.toml` when it is intentional for the repo's domain, and keep `exclude_lints` sorted alphabetically.

### package.json

```json
{
  "name": "@bananapus/referral-split-hook-v6",
  "version": "x.x.x",
  "license": "MIT",
  "repository": { "type": "git", "url": "git+https://github.com/Bananapus/nana-referral-split-hook-v6.git" },
  "engines": { "node": ">=20.0.0" },
  "scripts": {
    "test": "forge test",
    "coverage": "forge coverage --match-path \"./src/*.sol\" --report lcov --report summary"
  },
  "dependencies": { ... },
  "devDependencies": {
    "@sphinx-labs/plugins": "0.33.3"
  }
}
```

**Scoping:** `@bananapus/` for Bananapus repos, `@rev-net/` for revnet, `@croptop/` for croptop, `@bannynet/` for banny, `@ballkidz/` for defifa.

### remappings.txt

Every repo has a `remappings.txt` as the **single source of truth** for import remappings. Never add remappings to `foundry.toml`.

**Principle:** Import paths in Solidity source must match npm package names exactly. With `libs = ["node_modules", "lib"]`, Foundry auto-resolves `@scope/package/path/File.sol` → `node_modules/@scope/package/path/File.sol`. No remapping needed for packages installed as real directories.

**Minimal content** (most repos):

```
forge-std/=lib/forge-std/src/
```

Only add extra remappings for:
- **`forge-std`** — always needed (git submodule with `src/` subdirectory)
- **Repo-specific `lib/` submodules** that have no npm package
- **Symlinked npm packages** — need explicit `@scope/package/=node_modules/@scope/package/` entries
- **Nested transitive deps** — e.g., `@chainlink/contracts-ccip/` nested inside `@bananapus/suckers-v6/node_modules/`

### Linting

Solar (Foundry's built-in linter) runs automatically during `forge build`. It scans all `.sol` files in `libs` directories, including `node_modules`.

**All test helpers must use relative imports** (e.g. `../../src/JBReferralSplitHook.sol`), not bare `src/` imports. This ensures solar can resolve paths when the helper is consumed via npm in downstream repos.

### Fork Tests

The cross-chain end-to-end tests for this hook live in `deploy-all-v6/test/fork/ReferralRewardCrossChainFork.t.sol`. They run on a single mainnet fork with mocked OP messengers — the test file mocks `xDomainMessageSender` to drive `prepare → toRemote → fromRemote → claim` round-trips deterministically without needing two real forks.

When adding new fork tests, declare RPC endpoints in `[rpc_endpoints]` of `foundry.toml` and let them hard-fail if the env var is missing — no skip guards. CI failures should be explicit.

### Formatting

Run `forge fmt` before committing. The `[fmt]` config in `foundry.toml` enforces:
- Thousands separators on numbers (`1_000_000`)
- Multiline function headers when multiple parameters
- Wrapped comments at reasonable width

CI checks formatting via `forge fmt --check`.

### Branching

- `main` is the primary branch
- Feature branches for PRs
- All PRs trigger test + lint workflows
- Submodule checkout with `--recursive` in CI

### Dependencies

- Solidity dependencies via npm (`node_modules/`)
- `forge-std` as a git submodule in `lib/`
- Sphinx plugins as a devDependency
- Cross-repo references use `file:../sibling-repo` in local development
- Published npm dependencies are pinned to exact versions

### Contract Size Checks

CI runs `forge build --sizes` to catch contracts approaching the 24KB limit. `JBReferralSplitHook` is well below that ceiling (small, single-purpose), but the check stays in CI as a guard against future bloat.

---

## Highlights specific to this repo

- **Single contract, single interface.** Errors live in the interface so test callers can use `selector` matchers without importing the implementation. Events live in the interface for the same reason.
- **Cross-chain naming convention is load-bearing.** `referralProjectId` ALWAYS refers to the referrer's projectId on the referrer's home chain (`referralChainId`), never to a numerically-matching projectId on some other chain. Every signature, every NatSpec block, and every storage slot in the hook interprets the field this way.
- **Two parallel high-water-mark ledgers.** `pushedLocallyOf` tracks same-chain forwards; `bridgedOutOf` tracks cross-chain bridges AND burns of unbridgeable credit. They share neither storage nor semantics — keep them physically separate to avoid the indexer ambiguity that v0.0.2 had.
- **Burn-over-strand is policy, not optional.** If a settlement path can't be reached, burn the fee-project tokens. The only exception is same-chain `pushTo` with no ERC-20, which defers (recoverable when the referrer tokenizes). See `RISKS.md` and the `jb-referral-hook-deferral-vs-stranding` design doc for the full matrix.
