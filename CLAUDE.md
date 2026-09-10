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
doing it at once — is asserted in `test/unit/curves/LinearCurveMath.t.sol`, so a reversed rounding fails loudly.

For the step curve the rounding is **one ceiling over the exact bucket sum**, never one per bucket.
The number of buckets a slice touches changes as the supply crosses a boundary, so per-bucket
ceilings would let `cost(s, d)` fall by a wei as `s` rose by one — adjacent prices near the origin
differ by less than 2e18 wei — and the conformance suite's monotonicity test catches exactly that.
With a single ceiling the sum is monotone, `ceil(a) + ceil(b) >= ceil(a + b)` makes splitting never
cheaper, and a non-zero first price makes the result never zero. Keep it that way.

**3. Checks, effects, interactions, and `nonReentrant` on anything that touches an external contract.**
Write all state before any external call. `mint`, `burn`, `burnFor`, `harvest`, `stake`,
`initiateUnstake` and `unstake` all carry the guard.

**4. `burn` and `burnFor` must never become pausable.** Redemption is a promise to users and the pause
switch must not be able to reach it. `test_Burn_SucceedsWhilePaused` encodes this as an executable
assertion; if you add a shared modifier, check it did not sweep redemption in with it.

**5. Roles, not owners.** `AccessControlUpgradeable` with one role per responsibility:
`DEFAULT_ADMIN_ROLE` (grant/revoke, `setFoundation`, `setCurve`, `setCap`), `PAUSER_ROLE` (pause/unpause only),
`RESCUE_ROLE` (`burnFor` only), `MINTER_BURNER_ROLE` (held solely by the vault), and beacon
ownership (upgrades). Deployment puts admin, pauser and the beacons on the deploying account and
`RESCUE_ROLE` on nobody, so the rescue path opens as an explicit act of governance.

**`DEFAULT_ADMIN_ROLE` on the vault is an upgrade-grade key and must go to the same multisig as
beacon ownership.** It was not always: before the curve moved out of the vault, admin could not touch
pricing at all, and separating it from the upgrade key was a real boundary. `setCurve` and `setCap`
erase that boundary — between them they can reprice all future issuance and lift the supply ceiling
without limit, which is the same economic power an upgrade has. Treating admin as a lesser key
because it once was is the mistake this paragraph exists to prevent.

`./handover.sh grant` then `./handover.sh renounce` moves them, in two transactions on purpose:
`grant` leaves the deployer in place so the targets can be confirmed to respond, and `renounce`
re-reads governance from the chain and refuses unless they already hold everything. Beacon
ownership is one-step `Ownable` with no acceptance step, so that precondition is its only safety
net. Never collapse the two steps.

**6. `SafeERC20` for every external token.**

**7. Never write `require(newCap >= supply)` in `setCap`, and never forbid `setCap(0)`.** Lowering
the cap below the live supply is the supported way to close issuance — burn-only mode — and it is
wanted precisely in an emergency, which is when a guard like that would block it. It reads as a
safety check and is the most natural wrong instinct here, so it is called out by name. Burn-only
needs no mode flag: `mint`'s `supplyAfter > cap` check is simply always true once `cap < supply`,
and nothing else consults the cap. `test_SetCap_MayGoBelowTheLiveSupply` and `test_SetCap_MayBeZero`
fail if anyone adds one.

Note what burn-only does **not** stop: `harvest` is gated by `pause`, not by the cap, so
`setCap(0)` closes issuance while the sweep keeps running. `pause()` is the wind-down switch;
`setCap(0)` on its own is not.

**8. Do not add redundant state.** A field that mirrors something another contract already knows is a
liability, not a safety net — it costs gas on every write and creates a divergence that has to be
handled. The vault reads `iAI.totalSupply()` directly for exactly this reason; a mirrored `supply`
counter with a fail-closed check was removed because the check was also read by `burn`, so any
divergence would have bricked the one path that must always work.

`LinearMintCurve.anchorCap` and `.target` are not an exception to this, and neither are
`ExponentialMintCurve.base`, `.exponent` and `.target`. They are `immutable`, so they cannot drift
from anything — nothing reads them to make a decision, and they enforce nothing. They record how the
slope, or the table, was derived, which is the only way the published parameters stay readable on
chain now that the vault's own cap is a separate, adjustable number.

`ExponentialMintCurve`'s table is storage, and that is not redundant state either: it *is* the
curve. It is written once by the constructor and there is no function that writes it again — no
setter, no owner, no proxy — so it is as immutable as an `immutable` field, which Solidity cannot
give an array. The property to preserve is "no write path exists", and it is checkable from the
ABI. Do not add one, however administrative it looks; a different table is a different curve and
goes in by `deployCurve` + `setCurve`, where the history list records it.

## Storage and upgrades

Every contract uses **ERC-7201 namespaced storage** and sits behind its **own `UpgradeableBeacon`**,
so one upgrade cannot reach the others. Implementations call `_disableInitializers()` in their
constructor; initializer calldata rides in each proxy's constructor so deploy and init are one
transaction (split in two, anyone could initialize the proxy first and own the curve).

**Adding storage:** append to the end of the namespaced struct. Never reorder, never remove, never
change a type.

**`IAIVault`'s struct was rewritten once, deliberately, and that licence has expired.** The curve
and cap refactor reordered and retyped every field. It was safe only because mainnet did not exist
yet and Galileo was redeployed from scratch rather than upgraded — the append-only rule applies from
that deployment onward. The reason it must: pointing a new implementation at an *old* proxy after a
rewrite fails silently and plausibly. The new `curve` reads the old `r0` (an address with no code),
the new `cap` reads the old `slope` (a ceiling of about two iAI), and `positions` lands on a
different base slot so every position reads zero — every `burn` reverts `BurnExceedsPosition` and
the collateral is stuck. Changing the namespace string does not help; the positions still read zero.
**Never point a new implementation at a proxy from before the rewrite.**

**Pricing is no longer inside the beacon.** `IAIVault` stores a curve address and calls it; the
maths lives in a separate immutable contract. So an upgrade rehearsal that only compared the vault's
own numbers would miss the one thing an upgrade can still do to reprice the system — repoint
`curve`. `UpgradeChecker` snapshots that address for exactly this reason.

**Before any upgrade touches a live chain, rehearse it on a fork.** This is not optional and it is
not replaced by a unit test:

```bash
./upgrade.sh rehearse vault      # forks the configured chain, upgrades there, compares state
./upgrade.sh vault               # only after the rehearsal passes
```

The rehearsal snapshots the curve address and cap, the accounting totals, live pricing and the
positions named in `CHECK_ACCOUNTS`, upgrades, and reverts on any drift; it also diffs
`forge inspect <Contract> storageLayout`. On a live upgrade, set `CHECK_ACCOUNTS` to the largest
holders.

There is deliberately **no on-chain self-check** for upgrade safety. A guard a contract computes
about itself is only sound while it reads the right storage slots, which is precisely what is in
doubt when a layout has shifted — it would report "fine" in the exact case it exists to catch.

## Scripts: chain work and disk work are separate

Every script splits in two, and the split is load-bearing:

- The part that touches a chain is an `internal` function on an abstract contract —
  `IAIDeployer` (system wiring, mock collateral), `AccountFunder` (deriving and funding),
  `UpgradeChecker` (capture, compare, point a beacon), `RoleHandover` (moving governance off the
  deployer). No file access, no environment reads.
- The `*.s.sol` script is a thin shell around it: read the parameters, call the function, write
  the result back.

That is what lets the tests reach the logic without a filesystem. It also keeps the deployment
described in exactly one place — the fixture and the script call the same function, so they
cannot drift.

The abstract halves must stay `internal` functions on inherited contracts, never deployed
helpers. `BeaconProxy` delegatecalls `initialize` during construction, so `msg.sender` there is
whoever ran the `new`; calling out to a separate deployer contract would hand
`DEFAULT_ADMIN_ROLE` to that contract instead of to the deploying account.

## Testing

Three layers, all required to stay green:

- **`test/unit/`** — per-function behaviour, golden vectors for the curve, full revert and
  permission matrices, and the scripts' chain work via the abstract halves above.

  **`test/unit/curves/CurveConformance.t.sol` is the gate on `IMintCurve`.** It is an abstract
  suite stating the behaviours a signature cannot: `cost` rounds up and is never zero, it is
  monotonic in supply, splitting a mint is never cheaper, a quote is affordable, and the curve is
  evaluable across the domain it declares. It is written entirely in terms of `cost`,
  `quoteForValue` and `maxSafeSupply`, so it applies unchanged to a curve of any shape and a curve
  cannot pass it by reporting figures that agree with each other while disagreeing with what it
  charges. **A new curve is not fit to point the vault at until it inherits this and passes.**
  **Unit tests never touch the filesystem.** Not `vm.readFile`, `vm.writeJson`, `vm.createDir`,
  `vm.projectRoot`, or `vm.setEnv` — the last one because it writes the *process* environment,
  which parallel test contracts share. Check it with:

  ```bash
  grep -rnE "vm\.(readFile|writeFile|readJson|writeJson|createDir|readDir|projectRoot|setEnv)" \
      test/unit test/sim test/Base.t.sol && echo "unit tests must not touch files"
  ```
- **`test/sim/`** — a seeded randomized simulation against a shadow model. The shadow recomputes the
  curve with plain checked arithmetic instead of `Math.mulDiv`, so a rounding regression shows up as
  a disagreement; it evaluates the same algebraic expansion the contract does, and the algebra is
  pinned separately by golden vectors computed outside this codebase. State is compared after *every*
  step so a mismatch names the operation that caused it. Coverage counters are asserted at the end,
  so a run that degenerates into no-ops fails instead of passing vacuously.

  Pausing, cap changes, curve swaps and rejected operations are all part of the operation mix. That
  makes "redemption is never gated" a property held across the whole run rather than one assertion,
  against both switches: a 10k-operation run redeems ~670 times while paused and ~580 times with the
  cap below the live supply. It also checks **which** error each guard raises from whatever state the
  run has reached — `_opMint` draws its amount without reference to the cap and lets the shadow
  decide whether the mint should be refused, which is a stronger statement than a `supply <= cap`
  assertion and, unlike one, survives burn-only mode.

  Curve swaps go in both directions and alternate between the two shapes: every odd swap installs a
  random, monotone step table (coarse — 38 buckets of 500 iAI, so its top clears twice the cap and
  `_opSetCap` never meets it) and every even one a linear curve. The shadow tracks the kind in force
  and prices each mint accordingly, so a mint after a swap is priced at the new curve while a burn of
  a pre-swap position is still settled at that position's own average — requirement 1, checked wei
  for wei thousands of times from states no hand-written test reaches, across a change of shape. The
  step shadow is the same bucket walk with one hand-rolled ceiling; the production table's provenance
  is pinned by golden vectors, not here.

  Adding an operation redraws the entire deterministic sequence, including the sub-sampling inside
  `_opRejection`. Make simulation changes in one pass, then re-run 10k **and** 100k and recalibrate
  the coverage floors against what the new sequence actually produces. Rejected operations deliberately take no state snapshot: the EVM already
  rolls back a reverted frame, and the shadow is not advanced for a rejected operation, so the
  per-step comparison already fails if the contract kept anything.
There is deliberately **no Foundry `invariant_` layer**. It was considered and dropped: the seeded
simulation already runs the same invariants over 100k operations, and an empty `test/invariant/`
directory beside a dead `[profile.default.invariant]` block is worse than neither. If it is ever
added back, add the tests and the config together.

- **`test/script/`** — the only place that touches disk, and only for what genuinely needs it:
  reading the parameter file, writing the addresses back, and the artifact the account script
  produces. Real bugs were found here (`vm.writeJson`'s silent no-op on a missing key), so it
  cannot be dropped — but everything that does not need a file belongs in `test/unit/`.

**The unit fixture must keep building the system through `IAIDeployer`.** `test/Base.t.sol` inherits
the same abstract contract the deploy script does, so every test run rehearses the real deployment
including its post-deploy assertions. Writing the wiring out by hand in the fixture is how a suite
stays green against a topology the script no longer produces — that exact drift once hid a deployment
that granted no `PAUSER_ROLE`, which would have shipped the system permanently paused with nobody able
to open it.

Two Foundry behaviours worth knowing before writing tests here:

- **The filesystem is not rolled back between tests**, only EVM state — and tests within one
  contract run **in parallel** (measured: three tests entered in the same millisecond, 4.8s wall
  against 14.5s CPU). So any test that writes files needs a path of its own, or two of them race
  over the same file and the suite goes flaky rather than failing honestly.
- **An argument is evaluated before the call it belongs to**, so anything that makes an external
  call in an argument position steals the `vm.prank` or `vm.expectRevert` intended for the outer
  call. `vault.grantRole(vault.PAUSER_ROLE(), x)` pranks `PAUSER_ROLE()`; `beacon.upgradeTo(address(
  new Impl()))` pranks the deployment. This has cost time three times in this repo. Hoist role
  constants and freshly deployed addresses into locals first.
- **`vm.getRecordedLogs()` drains the buffer.** A second call after the same `vm.recordLogs()`
  returns an empty array, so a helper that fetches internally can only be used once per
  transaction. A test needing two events out of one call must fetch the logs itself and search the
  array — that is what `_onlyIn` is for in `test/unit/Events.t.sol`.
- **`setUp()` runs once**, and every test starts from a snapshot of the state it left. A value
  computed there is therefore identical in every test — including `vm.randomUint()`, which does vary
  when called from a test body but not from `setUp`. That is why the script tests take the directory
  name as an argument (`_bootstrap("some-name")`) instead of generating one: it cannot be derived in
  `setUp`, and a generated name would also change every run, so a failed test could not be inspected
  at a known path.
- **`vm.setEnv` writes the process environment, which parallel test contracts share.** Scripts
  therefore take per-instance overrides (`setDeploymentDir`, `setParams`); `DEPLOYMENT_PATH` and the
  other environment variables remain for the command line.

## Deployment records

`deployments/iai-<chainId>.json` is both the input and the output: hand-written parameters go in, and
the addresses a run produced come back to the same file. Start from `iai-example.json`.

**Tests cannot write into `deployments/`.** The default profile grants read-write only on
`./cache`, so a test that forgets to redirect a script fails with a permission error rather than
overwriting a deployment record. `run.sh` and `upgrade.sh` set `FOUNDRY_PROFILE=deploy`, which
differs from the default in `fs_permissions` alone — same solc, same `via_ir`, same optimizer, so
it cannot produce different bytecode. Run `forge script` by hand with that profile set.

**Write the whole document, never a single key.** Foundry's three-argument
`vm.writeJson(value, path, ".Key")` **silently does nothing** when the key does not already exist —
no error, no warning. Seed the output object from the current file and write it in one go:

```solidity
string memory obj = "iai";
vm.serializeJson(obj, json);              // keep everything already recorded
vm.serializeAddress(obj, "IAIVault", d.vault);
string memory finalJson = vm.serializeAddress(obj, "MintCurve", d.curve);
vm.writeJson(finalJson, path);            // only the LAST serialize call returns the document
```

Note the last line's comment: `vm.serializeXxx` returns the completed document only from the final
call, so capturing it early silently drops everything serialized afterwards.

**A rehearsal must not be able to write the real deployment record.** `./upgrade.sh rehearse`
calls the same entry point a real upgrade does, and that entry point records the implementation
address it just deployed — on a fork, an address that exists nowhere else. It used to write that
into the live record, replacing a working implementation with one that has no code, and nothing
said so until `./run.sh check` refused to pass. The rehearsal now redirects `DEPLOYMENT_PATH` to a
throwaway copy under `cache/`, so the snapshot and the record it produces both die with it. Any
future script that both forks and records needs the same treatment.

**Never `forge script --resume` a script that writes its own record.** These scripts write the
deployment file during *simulation*, before broadcasting. `--resume` re-simulates from scratch and
then sends only the transactions the previous broadcast never got to — so the record ends up naming
a fresh set of addresses that were never deployed, while the pending transactions land on the
previous set. It has happened: a run died on 0G's null-receipt flakiness after deploying every
contract but before three role grants, and the resume left the record pointing at phantoms while
correctly finishing the real system. `./run.sh check` caught it, which is what it is for.

Recover by reading the true addresses out of `broadcast/<Script>/<chainId>/run-<ts>.json` — the
`CREATE` entries carry `contractName` and `contractAddress` in deployment order — writing them back
into the record, and then running `./run.sh check` so the chain, not the file, has the last word.
The alternative, simply rerunning the whole deployment, is also fine and is usually quicker to
reason about.

**Curves are recorded by kind as well as by role.** A record carries `MintCurveKind` (which kind is
in force), `MintCurve` (its address), the address again under the kind's own name —
`ExponentialMintCurve` (the default) and `LinearMintCurve` — and `MintCurveHistory`, every
curve the record has ever named. `./run.sh setCurve <kind>` reads the kind key.

Each of those answers a different question, and conflating them has already caused two bugs:

- The **kind key holds the newest curve of that kind**, not the active one. `deployCurve` and
  `setCurve` are two steps on purpose, and between them the two disagree — so **`checkDeployment`
  must compare the active curve against `MintCurve` only.** Requiring it to equal the kind key made
  `./run.sh check` fail by construction in the window where an operator most wants to inspect a
  curve before putting it in service.
- A same-kind redeploy overwrites the kind key, which is why `MintCurveHistory` exists. A superseded
  curve still priced real mints and is still live on chain; reconciling those mints needs its
  address.

**A curve's constructor cannot validate its own parameters, and must not pretend to.** `slope` is
derived *from* `target`, so composing `deriveSlope` with `lockedAt` returns the target it started
from — every triple that survives `deriveSlope` hits its own target by construction. The
consistency check in `LinearMintCurve`'s constructor is therefore provably unreachable from any
caller, and that is fine: what it guards is that the two formulas stay inverses of one another.
Edit either so they stop agreeing and the next deployment fails instead of shipping a curve whose
published `target` is not the 0G it accounts for.

Its tolerance is `LinearCurveMath.maxFlooringGap(cap)` — the exact quantum a single flooring step
can lose, `cap^2 / (2*WAD^2) + 1` — and never a round number. The quantum is quadratic in the
anchor: about 4.3e7 wei-0G at 9,270 iAI and 5e15 at 100,000,000 iAI. A constant picked for one
anchor is blind at the other or rejects well-formed curves whose relative error is around 1e-19.
The bound lives beside the formulas it is derived from, so the golden vectors cover it and there is
only one definition of `WAD`.

**A curve's parameters belong to the curve, and the record says so.** Everything a curve needs to
be constructed sits under `CurveParams.<Kind>` — for the linear curve, `R0`, `AnchorCap` and
`Target`; for the exponential curve, `Base`, `Exponent`, `Target`, `BucketWidth` and the 371-entry
`Prices` array. This is the one nested object in an otherwise flat file, and it earns the exception:
those keys are meaningless to any other curve, and each kind has its own block rather than
piling more top-level keys into a shared namespace. `Cap` stays at the top level because it is the
*vault's* ceiling, not a curve's.

**`Prices` is derived, never edited.** `./run.sh genCurve` runs `script/curve/gen_exponential_table.py`,
which derives the table from `Base`, `Exponent`, `Target`, `BucketWidth` and the record's `Cap`
(60-digit `decimal`, each price rounded up to the wei, each bucket priced at its upper bound) and
writes the block. `./run.sh check` and `./run.sh deployCurve` run the same script in `--check` mode
first, so a table that disagrees with the parameters beside it cannot be deployed or pass a check;
`checkDeployment` then compares the deployed curve under the kind key against the record's table
entry by entry. Every integer in the block is WAD-scaled and stored as a decimal string like the
rest of the file — `Exponent` is `3419000000000000000` for 3.419; the cubic power is part of the
formula, not a parameter. The unit tests cannot read the record, so `--solidity` also emits
`test/unit/curves/ExponentialTable.sol`, and `test/script/Deploy.t.sol` asserts the two agree;
regenerate both whenever the parameters change. The golden vectors in
`test/unit/curves/ExponentialMintCurve.t.sol` were computed with `mpmath`, independently of the
generator, and may not be edited to follow it.

**The exponential curve's domain is its table, and the cap must fit inside it.** `maxSafeSupply()`
is the table's top (9,275 iAI for the shipped parameters), so `setCap` above it is refused while
that curve is in force, and `setCurve` to it is refused while the cap is above it. Raising the
target is therefore always `genCurve` → `deployCurve` → `setCurve` → `setCap`, in that order. The
test fixture stays on the linear curve for exactly this reason: `CapChange.t.sol` raises the cap to
twice `CAP`, which the table cannot price. Exponential coverage lives in its own suite, in
`CurveSwap.t.sol`, in `Deploy.t.sol` and in the simulation's alternating swaps.

`AnchorCap` and `Cap` start life as the same number and then part company. `Cap` moves with
`setCap`; `AnchorCap` is the supply a curve's slope was derived against, burned into the curve at
construction. They shared a key once, so deploying a curve after any cap change silently derived a
*different* curve from the same published `R0` and `Target` — double the cap and the slope came out
271850478687441015 instead of 2021598247004348741, with every number involved still looking
plausible. **Never feed the vault's cap to a curve constructor.**

The same split runs through the code: `Config` carries only what every deployment needs, each curve
kind gets its own parameter struct (`LinearCurveParams`, `ExponentialCurveParams`), and `IAIDeployer`
exposes one typed `_deploy<Kind>Curve` rather than one function switching on a name. A name-switched deployer has to accept the union of every
curve's parameters, so each new curve widens a struct the others then carry fields they have no use
for — and a caller filling in the wrong subset gets a curve that constructs cleanly and prices
differently. The name-to-parameter-shape mapping lives in exactly one place, `_curveOfKind` in
`IAI.s.sol`, because that is the half that reads records.

**Deploy scripts that touch collateral must be idempotent.** `Mock.s.sol` reuses an already-recorded
`MockA0G` instead of deploying a new one. An unconditional redeploy is silent and total: every
balance ever minted stays in the old token while the new system points at an empty one, nothing
reverts, and on a testnet with funded accounts it destroys all of them. Redeploying the *system*
against existing collateral is a supported operation and is how the testnet gets a rebuilt vault
without re-funding accounts.

There is one way past that guard, `./run.sh redeployMock`, for the case the guard cannot serve:
the mock itself has to change shape. It is a separate named entry point rather than a flag,
because nothing should reach it by rerunning a deployment, and it prints what it abandons before
it does anything. Using it commits you to the rest of the sequence — the vault caches its
collateral address at `initialize` and has no setter, so a new token means a new vault, which
means the whole system is redeployed and the accounts refunded from the new token.

**A mock's share price comes from the oracle, never from what it holds.** `MockA0G` is an ERC-4626
over W0G, and the only conversion input it overrides is `totalAssets() = totalSupply() *
oracle.getValue() / 1e18` — which is exactly, and only, what the real token (Mellow's
`SourceCore`) overrides. Everything else is OpenZeppelin's and follows from that one number.
Deriving the price from the balance held instead would break an identity that holds on mainnet:
`oracle.getValue()`, `convertToAssets(1e18)` and `totalAssets/totalSupply` are all the same
number there, because W0G is one-for-one with 0G. A caller sizing a deposit from `previewDeposit`
would then be handed an amount the vault values differently. It also means the unrestricted
faucet is harmless to the accounting: minting shares with nothing behind them leaves
`totalAssets` consistent, because it was never counting the balance.

## Secrets

- **`deployments/test-accounts-*.json` contains private keys** and is gitignored. `Accounts.s.sol`
  refuses to run on mainnet and refuses to enumerate the deployer's own key — publishing that would
  hand over `DEFAULT_ADMIN_ROLE` and the beacons along with the test accounts. This is a real hazard
  with the stock anvil mnemonic, whose account 0 is the usual local deployer.
- `config.sh` and `.env` are gitignored; commit `config.example.sh` and `.env.example` instead.
- Nothing else in `deployments/` is secret — those files are meant to be committed and shared.
- **Never print a private key, mnemonic, or any other secret into the conversation, into a commit
  message, into a PR body, or into terminal output that gets pasted around.** This applies to keys
  that look disposable: a testnet key is still a key, and one that reaches a chat log or a public
  repository has to be treated as compromised and rotated. When a secret has to be shown to prove
  something, show a derived public value instead — an address, a checksum, or a count. Read `.env`
  and the account files only as far as the task actually requires, and never echo their contents.

## Accepted risks

Decisions, not oversights. They are recorded here so nobody has to rediscover them, and so a future
change that quietly "fixes" one gets discussed rather than merged.

**R1 — the a0G oracle's write key can drain the vault.** Upstream `setValue` has no bounds, no
monotonicity requirement, no rate limit and no timelock. Set the rate absurdly high, mint to the cap
for dust, restore it, redeem: the collateral is gone. iAI does not defend against this, because the
root cause is the combination of yield-bearing collateral and recording curve value rather than
deposited tokens — both deliberate. **Operational requirement:** monitor the oracle's `ValueSet`
events and `pause()` on any move outside the expected daily band. `pause()` stops minting but not
redemption, so the window between alert and human response is the exposure. Note the cap is not a
bound on this: it is adjustable upward, so "mint to the cap" is not a fixed quantity of damage.

**R2 — a mint and an immediate full burn costs 1 wei.** Round-trips are effectively free, so a large
mint can be front-run for position. Accepted; slippage protection is the only defence, and the
contracts are upgradeable if a holding period ever becomes necessary.

**R3 — if the a0G oracle stops updating for 21 days, `mint`, `burn`, `harvest` and every quote
revert.** An external dependency. Note that setting the upstream `maxAge` to zero freezes the system
permanently rather than temporarily.

**R4 — `totalLocked0G` can exceed the curve's `target`, and has no computable upper bound.** A
redeemer releases 0G at their own average rate while the freed supply is resold at the marginal
rate, so churn ratchets the total upward. The old figure of "roughly 213.9M 0G" was derived from a
fixed `(r0, cap, target)` and is no longer a bound of any kind: the cap can be raised and the curve
replaced with a dearer one, both without limit. **Never write `require(totalLocked0G <= target)`**,
and do not reintroduce a numeric ceiling in its place.

**R5 — a falling exchange rate leaves late redeemers short.** The harvest sweep goes quiet and
redemption becomes first come, first served. Accepted on the premise that a0G does not depreciate;
`test_RateFall_SweepGoesQuietButLateRedeemersAreLeftShort` pins the actual behaviour so it is a known
quantity rather than a surprise. Lowering the cap to wind the system down makes this worse rather
than better — the sweep is gated by `pause`, not by the cap, so it keeps running. Use `pause()`.

**R6 — governance can reprice all future issuance, and lower the curve at existing holders' profit.**
`setCurve` takes any contract satisfying `IMintCurve`. Lowering the curve lets an existing holder
burn and re-mint at a profit: they release 0G at their own average and buy the same supply back
cheaper. Measured — dropping `r0` from 4,330 to 2,000 lets a 100-iAI holder extract 238,439 0G.
Solvency is unaffected (the vault only ever pays out what a position holds), but the same supply
then sits on less collateral and the foundation's future harvest shrinks. Accepted deliberately:
no on-chain restriction on the direction of a swap, and no record of the price difference.
`test_Swap_DownwardsIsArbitrageableByExistingHolders` pins it.

**R7 — the supply ceiling is adjustable without limit.** `setCap` accepts anything up to the curve's
declared arithmetic domain. Raising it dilutes nothing directly, but it removes the ceiling every
other figure here was quoted against, R1 and R4 included.

**R8 — a curve can be discriminatory or mutable; the vault cannot tell.** `IMintCurve`'s functions
are `view`, so a curve reaches the vault by `STATICCALL` and cannot write state or reenter — that
much is structural. `view` is not `pure`, though: a curve may read `block.timestamp` or `tx.origin`
and price differently per transaction or per originator. `msg.sender` at the curve is the vault, but
`tx.origin` is the user, so a curve that is free for one address and ruinous for everyone else is
constructible and invisible from the vault. Likewise "a curve is an immutable value" is a property
of the deployment convention, not of the type: the vault cannot distinguish `LinearMintCurve` from a
proxy in front of one. **Read the deployed bytecode of any curve before pointing the vault at it.**

What a bad curve structurally *cannot* do is take collateral. `mint` derives both the amount it
records and the amount it collects from the same single return value, so the vault can never record
more than it collected, and `_settle` never consults a curve at all — existing positions are out of
reach from the curve side. A curve returning zero is caught by the vault's own `delta0G == 0` guard
rather than trusted not to.

**R9 — `IAI` has no supply cap of its own any more, so `MINTER_BURNER_ROLE` is unbounded.** The
token used to carry a hard cap as a second, independent line of defence; the cap moved into the
vault to become adjustable, and the token's was removed rather than left to contradict it. What is
given up is real, and it is more than "extra tokens": `iai.totalSupply()` is the vault's pricing
input, so iAI minted outside the vault raises the curve for everyone, can push the supply past the
cap and force burn-only from the token side, and leaves supply the vault has no position behind —
which is the premise `_settle`'s arithmetic rests on.

The mitigation got cheap in the same change, though, and should be taken: **`IAI` now has no
admin-settable state at all**, so `DEFAULT_ADMIN_ROLE` on the token does nothing except grant
`MINTER_BURNER_ROLE`. Renouncing it, or moving it behind a timelock, costs nothing operationally.
That was not true before.

## Conventions

- Comments explain *why*, and inline the substance rather than pointing at a document the reader may
  not have. No `see plan §2.A`.
- NatSpec: document every `@param`. The external ABI is documented on the **interfaces**;
  implementations use `@inheritdoc` plus any implementation-specific `@dev`.
- Solidity NatSpec allows only `@custom:*` tags on struct fields — use plain `///` for those.
- Commits and PR bodies carry no AI or tooling attribution, and no personal information.
