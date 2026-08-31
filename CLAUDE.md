# CLAUDE.md — 0g-iai-contracts

Guidance for anyone (human or agent) working in this repository. `README.md` explains what the system
does; this file explains how to change it without breaking it.

## Build and test

```bash
forge build
forge test                                          # full suite, a few seconds
forge test --match-path test/unit/IAIVault.t.sol -vv
SIM_LONG=1 SIM_OPS=100000 forge test --match-test test_Sim_Long   # long simulation, minutes
forge build --sizes                                 # contract size check
```

Foundry only. Solidity 0.8.25, cancun, `via_ir`, optimizer 200. OpenZeppelin v5.3.0 for everything —
do not hand-roll access control, pausing, reentrancy guards, safe transfers, or fixed-point maths.

## Engineering rules

These are not style preferences. Each one exists because the alternative has a concrete failure mode.

**1. Never divide twice, and never divide before multiplying.** Every ratio goes through
`Math.mulDiv(a, b, c, rounding)`, whose 512-bit intermediate removes the overflow question entirely.

**2. Every rounding decision favours the protocol.** Value entering the vault rounds **up**; value
leaving rounds **down**. State the direction and the reason in the NatSpec at each site, and cover it
with a test. The aggregate consequence — splitting a mint into many is strictly more expensive than
doing it at once — is asserted in `test/unit/MintCurve.t.sol`, so a reversed rounding fails loudly.

**3. Checks, effects, interactions, and `nonReentrant` on anything that touches an external contract.**
Write all state before any external call. `mint`, `burn`, `burnFor`, `harvest`, `stake`,
`initiateUnstake` and `unstake` all carry the guard.

**4. `burn` and `burnFor` must never become pausable.** Redemption is a promise to users and the pause
switch must not be able to reach it. `test_Burn_SucceedsWhilePaused` encodes this as an executable
assertion; if you add a shared modifier, check it did not sweep redemption in with it.

**5. Roles, not owners.** `AccessControlUpgradeable` with one role per responsibility:
`DEFAULT_ADMIN_ROLE` (grant/revoke, `setFoundation`), `PAUSER_ROLE` (pause/unpause only),
`RESCUE_ROLE` (`burnFor` only), `MINTER_BURNER_ROLE` (held solely by the vault), and beacon
ownership (upgrades). Deployment puts the first three and the beacons on the deploying account;
they are handed to the multisig before launch.

**6. `SafeERC20` for every external token.**

**7. Do not add redundant state.** A field that mirrors something another contract already knows is a
liability, not a safety net — it costs gas on every write and creates a divergence that has to be
handled. The vault reads `iAI.totalSupply()` directly for exactly this reason; a mirrored `supply`
counter with a fail-closed check was removed because the check was also read by `burn`, so any
divergence would have bricked the one path that must always work.

## Storage and upgrades

Every contract uses **ERC-7201 namespaced storage** and sits behind its **own `UpgradeableBeacon`**,
so one upgrade cannot reach the others. Implementations call `_disableInitializers()` in their
constructor; initializer calldata rides in each proxy's constructor so deploy and init are one
transaction (split in two, anyone could initialize the proxy first and own the curve).

**Adding storage:** append to the end of the namespaced struct. Never reorder, never remove, never
change a type.

**Before any upgrade touches a live chain, rehearse it on a fork.** This is not optional and it is
not replaced by a unit test:

```bash
./upgrade.sh rehearse vault      # forks the configured chain, upgrades there, compares state
./upgrade.sh vault               # only after the rehearsal passes
```

The rehearsal snapshots the curve constants, the accounting totals, live pricing and the positions
named in `CHECK_ACCOUNTS`, upgrades, and reverts on any drift; it also diffs
`forge inspect <Contract> storageLayout`. On a live upgrade, set `CHECK_ACCOUNTS` to the largest
holders.

There is deliberately **no on-chain self-check** for upgrade safety. A guard a contract computes
about itself is only sound while it reads the right storage slots, which is precisely what is in
doubt when a layout has shifted — it would report "fine" in the exact case it exists to catch.

## Testing

Three layers, all required to stay green:

- **`test/unit/`** — per-function behaviour, golden vectors for the curve, and full revert and
  permission matrices.
- **`test/sim/`** — a seeded randomized simulation against a shadow model. The shadow **recomputes
  the curve independently**, with plain checked arithmetic instead of `Math.mulDiv`; a shadow that
  called the same helper would only prove the code equals itself. State is compared after *every*
  step so a mismatch names the operation that caused it. Coverage counters are asserted at the end,
  so a run that degenerates into no-ops fails instead of passing vacuously.
- **`test/script/`** — the deployment, upgrade and account scripts, run the way an operator runs them.

**The unit fixture must keep building the system through `IAIDeployer`.** `test/Base.t.sol` inherits
the same abstract contract the deploy script does, so every test run rehearses the real deployment
including its post-deploy assertions. Writing the wiring out by hand in the fixture is how a suite
stays green against a topology the script no longer produces — that exact drift once hid a deployment
that granted no `PAUSER_ROLE`, which would have shipped the system permanently paused with nobody able
to open it.

Two Foundry behaviours worth knowing before writing tests here:

- **The filesystem is not rolled back between tests**, only EVM state. Tests that write files need
  their own directory, and `vm.randomUint()` will not give you one — it is seeded per test, so every
  test in a contract gets the same value.
- **`vm.setEnv` writes the process environment, which parallel test contracts share.** Scripts
  therefore take per-instance overrides (`setDeploymentDir`, `setParams`); `DEPLOYMENT_PATH` and the
  other environment variables remain for the command line.

## Deployment records

`deployments/iai-<chainId>.json` is both the input and the output: hand-written parameters go in, and
the addresses a run produced come back to the same file. Start from `iai-example.json`.

**Write the whole document, never a single key.** Foundry's three-argument
`vm.writeJson(value, path, ".Key")` **silently does nothing** when the key does not already exist —
no error, no warning. Seed the output object from the current file and write it in one go:

```solidity
string memory obj = "iai";
vm.serializeJson(obj, json);              // keep everything already recorded
vm.serializeAddress(obj, "IAIVault", d.vault);
string memory finalJson = vm.serializeString(obj, "Slope", vm.toString(d.slope));
vm.writeJson(finalJson, path);            // only the LAST serialize call returns the document
```

Note the last line's comment: `vm.serializeXxx` returns the completed document only from the final
call, so capturing it early silently drops everything serialized afterwards.

## Secrets

- **`deployments/test-accounts-*.json` contains private keys** and is gitignored. `Accounts.s.sol`
  refuses to run on mainnet and refuses to enumerate the deployer's own key — publishing that would
  hand over `DEFAULT_ADMIN_ROLE` and the beacons along with the test accounts. This is a real hazard
  with the stock anvil mnemonic, whose account 0 is the usual local deployer.
- `config.sh` and `.env` are gitignored; commit `config.example.sh` and `.env.example` instead.
- Nothing else in `deployments/` is secret — those files are meant to be committed and shared.

## Accepted risks

Decisions, not oversights. They are recorded here so nobody has to rediscover them, and so a future
change that quietly "fixes" one gets discussed rather than merged.

**R1 — the a0G oracle's write key can drain the vault.** Upstream `setValue` has no bounds, no
monotonicity requirement, no rate limit and no timelock. Set the rate absurdly high, mint to the cap
for dust, restore it, redeem: the collateral is gone. iAI does not defend against this, because the
root cause is the combination of yield-bearing collateral and recording curve value rather than
deposited tokens — both deliberate. **Operational requirement:** monitor the oracle's `ValueSet`
events and `pause()` on any move outside the expected daily band. `pause()` stops minting but not
redemption, so the window between alert and human response is the exposure.

**R2 — a mint and an immediate full burn costs 1 wei.** Round-trips are effectively free, so a large
mint can be front-run for position. Accepted; slippage protection is the only defence, and the
contracts are upgradeable if a holding period ever becomes necessary.

**R3 — if the a0G oracle stops updating for 21 days, `mint`, `burn`, `harvest` and every quote
revert.** An external dependency. Note that setting the upstream `maxAge` to zero freezes the system
permanently rather than temporarily.

**R4 — `totalLocked0G` can exceed `target`, up to roughly 213.9M 0G.** A redeemer releases 0G at
their own average rate while the freed supply is resold at the marginal rate, so churn ratchets the
total upward. **Never write `require(totalLocked0G <= target)`.**

**R5 — a falling exchange rate leaves late redeemers short.** The harvest sweep goes quiet and
redemption becomes first come, first served. Accepted on the premise that a0G does not depreciate;
`test_RateFall_SweepGoesQuietButLateRedeemersAreLeftShort` pins the actual behaviour so it is a known
quantity rather than a surprise.

## Conventions

- Comments explain *why*, and inline the substance rather than pointing at a document the reader may
  not have. No `see plan §2.A`.
- NatSpec: document every `@param`. The external ABI is documented on the **interfaces**;
  implementations use `@inheritdoc` plus any implementation-specific `@dev`.
- Solidity NatSpec allows only `@custom:*` tags on struct fields — use plain `///` for those.
- Commits and PR bodies carry no AI or tooling attribution, and no personal information.
