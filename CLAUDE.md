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
Write all state before any external call. `mint`, `burn`, `harvest`, `stake`, `initiateUnstake`
and `unstake` all carry the guard.

**4. `burn` must never become pausable.** Redemption is a promise to users and the pause
switch must not be able to reach it. `test_Burn_SucceedsWhilePaused` encodes this as an executable
assertion; if you add a shared modifier, check it did not sweep redemption in with it. `mint` no
longer carries `whenNotPaused` but `whenIssuanceOpen` (rule 5), so that check spans both names --
and it has to be anchored to signatures, because the modifier's own definition and two `@dev`
blocks mention them too, so a plain grep returns five lines on a healthy tree and the rule stops
telling signal from noise:

```bash
grep -nE "^\s*function .*(whenNotPaused|whenIssuanceOpen)" src/IAIVault.sol
```

The right answer is exactly two, `mint` and `harvest`. `burn` must never appear.

**5. Roles, not owners.** `AccessControlUpgradeable` with one role per responsibility:
`DEFAULT_ADMIN_ROLE` (grant/revoke, `setFoundation`, `setCurve`, `setHarvestShare`),
`PAUSER_ROLE` (pause/unpause only),
`PAUSE_EXEMPT_MINTER_ROLE` (`mint` while paused, and nothing else), `MINTER_BURNER_ROLE` (held
solely by the vault), and beacon ownership (upgrades). Deployment puts admin, pauser and the beacons
on the deploying account and `PAUSE_EXEMPT_MINTER_ROLE` on nobody, so the paused-mint path opens as
an explicit act of governance.

**There is deliberately no on-behalf redemption, and no role that can perform one.** `burnFor` and
`RESCUE_ROLE` existed for one case -- a minter whose iAI has gone somewhere unrecoverable, whose
collateral is then stuck forever -- and were removed because nobody has a reason to use them: the
caller has to burn iAI they bought themselves and the collateral goes to the position owner, so a
rescue is pure expenditure for the caller. It also never eliminated the stranding, only moved it
onto whoever sold the rescuer those tokens. Venice's DIEM staking, which this system otherwise
mirrors closely, has no such path either. The stuck case is accepted: it is documented for
integrators, and the vault is beacon-upgradeable, so a specific instance can be addressed then --
by someone who knows the actual case -- rather than by a standing privilege nobody will use.
Do not reintroduce `burnFor` as a convenience.

`PAUSE_EXEMPT_MINTER_ROLE` is a permission for one operation, not a seat, and it is deliberately
**not** part of the handover: `RoleHandover` has no target field for it and the deployment record no
key, so there is nowhere for a stale holder to be written down. Governance grants it with
`./run.sh grantPausedMinter <addr>` and takes it back with `revokePausedMinter`; the handover only
checks that the *deployer* is not left holding it. Its cost to `pause()` is R10.

**`DEFAULT_ADMIN_ROLE` on the vault is an upgrade-grade key and must go to the same multisig as
beacon ownership.** It was not always: before the curve moved out of the vault, admin could not touch
pricing at all, and separating it from the upgrade key was a real boundary. `setCurve` and
`setHarvestShare` erase that boundary — between them they can reprice all future issuance, move the
supply ceiling without limit (it is the curve's, so a swap moves it), and redirect every future wei
of collateral yield, which is the same economic power an upgrade has. Treating admin as a lesser key
because it once was is the mistake this paragraph exists to prevent.

`./handover.sh grant` then `./handover.sh renounce` moves them, in two transactions on purpose:
`grant` leaves the deployer in place so the targets can be confirmed to respond, and `renounce`
re-reads governance from the chain and refuses unless they already hold everything. Beacon
ownership is one-step `Ownable` with no acceptance step, so that precondition is its only safety
net. Never collapse the two steps.

**6. `SafeERC20` for every external token.**

**7. The supply ceiling is the curve's. Never give the vault a cap of its own again, and never
write `require(newCurve.maxSafeSupply() >= supply)` in `setCurve`.** The vault stores no ceiling:
`mint` and every quote read `curve.maxSafeSupply()` (clamped to the vault's hard bound of 2^127) at
the point of use, so the ceiling moves when, and only when, the curve is swapped. A curve whose top
is below the live supply is the supported way to close issuance — burn-only mode — and it is wanted
precisely in an emergency, which is when a guard like that would block it. It reads as a safety
check and is the most natural wrong instinct here, so it is called out by name. Burn-only needs no
mode flag: `mint`'s `supplyAfter > cap` check is simply always true once the ceiling is under the
supply, and nothing else consults it. `test_BurnOnly_ACurveBelowTheLiveSupplyClosesIssuance` and
`test_SetCurve_AcceptsACurveNarrowerThanTheSupply_AndTheCeilingFollows` fail if anyone adds one.

The vault used to carry an adjustable `cap` beside the curve, with `setCap`; it was removed because
it was a second number able to disagree with the first, and because every reason to move it was a
reason to move the curve. What `setCurve` does check of the incoming curve is only that it answers
`maxSafeSupply()` at all, so a contract that cannot is refused now rather than discovered on the
first mint. Its value is not judged.

Note what burn-only does **not** stop: `harvest` is gated by `pause`, not by the ceiling, so a
narrower curve closes issuance while the sweep keeps running. Neither switch is a wind-down on its
own, and they fail in opposite directions: a narrower curve leaves the sweep running, and `pause()`
leaves a `PAUSE_EXEMPT_MINTER_ROLE` holder able to mint. A full stop is `pause()` plus revoking that
role. A curve whose top is zero does close issuance to everyone in one transaction, because the
ceiling check sits inside `mint`'s body rather than in a modifier — but it needs a curve contract
deployed for the purpose, so it is not the switch to reach for first.

**8. Do not add redundant state.** A field that mirrors something another contract already knows is a
liability, not a safety net — it costs gas on every write and creates a divergence that has to be
handled. The vault reads `iAI.totalSupply()` directly for exactly this reason; a mirrored `supply`
counter with a fail-closed check was removed because the check was also read by `burn`, so any
divergence would have bricked the one path that must always work.

`Position.claimA0G` is not an exception either. It records which part of a position's claim keeps
its own appreciation, and that cannot be derived from anything else -- not from `claim0G`, not from
the balance, not from the curve. The thing rule 8 forbids in this area is the *other* design:
storing the foundation's accrued yield as a `pendingHarvest` counter. That mirrors what
`balance - owed` already says, drifts the moment anyone sends a0G to the vault directly, and turns
the sweep into an accrual whose result depends on how often someone advances it.

`LinearMintCurve.target` is not an exception to this, and neither are `ExponentialMintCurve.base`,
`.exponent` and `.target`. They are `immutable`, so they cannot drift from anything — nothing reads
them to make a decision, and they enforce nothing. They record how the slope, or the table, was
derived, which is the only way the published parameters stay readable on chain. (`anchorCap` is
different: it is the linear curve's `maxSafeSupply()`, and so the vault's ceiling while that curve
is in force. The exponential curve's ceiling is `top`, which is `bucketCount * bucketWidth` and
holds no information the table does not.) The 0G budget the table was sized to is recorded only in
the deployment record, never on chain — the contract is configured by the table it is given, and a
`budget` immutable would be a number nothing reads.

`ExponentialMintCurve`'s table is storage, and that is not redundant state either: it *is* the
curve. It is written once by the constructor and there is no function that writes it again — no
setter, no owner, no proxy — so it is as immutable as an `immutable` field, which Solidity cannot
give an array. The property to preserve is "no write path exists", and it is checkable from the
ABI. Do not add one, however administrative it looks; a different table is a different curve and
goes in by `deployCurve` + `setCurve`, where the history list records it.

**9. The obligation is a function of recorded claims, never of the balance.** `harvest` moves the
balance down to what the vault owes; it does not accrue. Write `owed` in terms of `held` -- for
instance the natural-looking `surplus = share * (held - claim0G/rate)` for "only sweep half" -- and
each call takes a cut of what the last one left, so repeated calls drain a surplus that is only
partly the foundation's. `test_Harvest_StaysIdempotentAcrossAChange` pins it: two calls in a row,
and two more across a change of share, all return zero after the first.

**10. A position is reachable only through `_settled`.** It may be several harvest-share changes
behind, and its stored numbers are then stale. A read that skipped the accessor would price a
redemption against a split no longer in force -- silently, with nothing reverting. The mapping is
documented as off limits for that reason; if you add a function that touches a position, go through
the accessor, and if you add a new accessor make it settle too.

## Storage and upgrades

Every contract uses **ERC-7201 namespaced storage** and sits behind its **own `UpgradeableBeacon`**,
so one upgrade cannot reach the others. Implementations call `_disableInitializers()` in their
constructor; initializer calldata rides in each proxy's constructor so deploy and init are one
transaction (split in two, anyone could initialize the proxy first and own the curve).

**Adding storage:** append to the end of the namespaced struct. Never reorder, never remove, never
change a type.

**`IAIVault`'s struct has now been rewritten three times, and the licence is spent again.**
Removing the vault's own `cap` took the second field out of `VaultStorage`, so every field after
`curve` moved up one slot. It was safe only because Galileo was rebuilt from scratch once more and
mainnet still did not exist — the same circumstances, and the same one-time licence, as the two
rewrites below. **The `IAIVaultBeacon` that `deployments/iai-16602.json` named before this rebuild
(`0xD86E78459687f7f58Da6d1CEA20809BD0c7281a0`) must never be pointed at this implementation.**
`foundation` would read the old `cap` (an address of `9270e18`, no code), `iai` the old
`foundation`, and every field from there on is one slot off, so every position reads zero.
Append from here.

**The second rewrite's statement still applies:** The adjustable harvest share reshaped both
`Position` (a second claim and an epoch marker, and `iaiOutstanding` narrowed to `uint128`) and
`VaultStorage` (two fields and an array, inserted before `positions` rather than appended). It was
safe only because Galileo was rebuilt from scratch and mainnet did not exist. Pointing the beacon
from before *that* rebuild at a later implementation fails the same way: `epochs` lands on a slot
that reads zero, so `_settled` underflows on `$.epochs.length - 1` and every `burn` reverts with a
bare panic; `positions` moves two slots, so every position reads zero as well.

**The original statement of this rule, from the curve and cap refactor, still applies verbatim:** The curve
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

The rehearsal snapshots the curve address (which carries the ceiling with it), the accounting
totals, live pricing and the positions named in `CHECK_ACCOUNTS`, upgrades, and reverts on any
drift. On a live upgrade, set
`CHECK_ACCOUNTS` to the largest holders.

**The `forge inspect <Contract> storageLayout` diff printed beside it is decoration, and must not
be read as a layout check.** Every contract here keeps its state in an ERC-7201 struct reached by
assembly, so solc reports *zero* state variables and the command prints an empty table for
`IAIVault`, `IAI` and `CreditRegistry` alike. The diff therefore says "(identical)" across any
layout change at all, including a full rewrite of the namespaced struct -- the exact silent,
plausible failure the section below is about. `upgrade.sh` also runs both sides against the same
working tree, so it could not see a source change even if the table had rows. What does the real
work is the state comparison in `UpgradeChecker`; for layout, read the diff of the struct.

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

  **`test/unit/EpochMath.t.sol` holds the split's arithmetic against a replay.** The library
  reaches the present in one step, by a ratio of running products; the test replays every change
  one at a time, from an implementation that exists only in the test file. They agree to within a
  stated bound -- the replay floors two buckets per step while the shortcut floors once at the end
  -- and exactly, to the wei, when only one change separates the position from the present. Do not
  make the test import the shortcut's algorithm.

  **Be precise about what that buys.** The replay is independent of the *compression* and not of
  the *single step*: it applies the same `V = c + a*r; c' = s*V; a' = (1-s)*V/r`. What holds that
  step honest is elsewhere -- the golden vectors, computed by hand before any of this was written;
  `testFuzz_AChangePreservesValue`, which constrains it without assuming the formula; and
  `testFuzz_SplitKeepsOneMinusShareOfTheDeposit` and
  `testFuzz_SettlementRestoresTheCanonicalCapture`, which pin the economics the formula exists to
  deliver. The last of those replaced an assertion that constructed `claimA0G` from
  `value * (1 - share) / rate` and then checked it equalled `backing * (1 - share)` -- an identity
  of its own arithmetic, which could not have failed. **A capture test has to be applied to
  something a function returned, not to something the test built.**

  **`test/sim/EpochSim.t.sol` is the seeded long run over that arithmetic.** The property suite
  above is Foundry fuzz: a thousand runs per property on a seed that changes each time, good for
  discovery and useless for reproduction. This one is the repository's usual instrument -- a fixed
  seed consumed in order, 10k steps by default and 100k under `SIM_LONG=1` -- over eight positions
  and a growing history of the split. It reaches the state fuzzing cannot: a position opened at one
  epoch, settled several changes later, replaced, and settled again, for as long as the run lasts.
  Its dominance assertion caught a real modelling error while it was being written -- subtracting a
  position's *stale* claims from totals restated at every change removes too little, and the totals
  stop covering the positions within a few dozen steps. That is rule 10's reason, made executable.

  **`test/unit/HarvestShare.t.sol` holds what the arithmetic cannot state on its own**: that a
  change moves nothing between minter and foundation, that the sweep stays idempotent across one,
  that settling late lands where settling at every step does, that catching up costs the same
  however many changes were missed, and that redemption works from every state a change can leave
  behind -- paused, the ceiling at zero, and several epochs behind at once.

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

  Pausing, curve swaps (which are also how the ceiling moves, and two in five of which put it
  below the live supply), changes of the harvest share and rejected operations are all part of the
  operation mix. That makes "redemption is never gated" a property held across the whole run rather
  than one assertion, against both switches: a 10k-operation run redeems ~975 times while paused and
  ~390 times with the ceiling below the live supply. It also checks **which** error each guard
  raises from whatever state the run has reached — `_opMint` draws its amount without reference to
  the ceiling and lets the shadow decide whether the mint should be refused, which is a stronger
  statement than a `supply <= cap` assertion and, unlike one, survives burn-only mode.

  The harvest share is retuned throughout, to zero and one as well as between them, and the shadow
  tracks both halves of every claim in plain checked arithmetic rather than through `EpochMath` --
  same formulas, same flooring, different code, so a rounding regression shows up as a
  disagreement. That is all it is, though: the shadow restates the production algorithm, so its
  per-step equality cannot catch a *wrong* formula, only a changed one. The epoch arithmetic is
  held to an independent standard in `EpochMath.t.sol` and `EpochSim.t.sol`, not here; what this
  simulation adds on top of them is the two inequalities -- every position can be paid, and the
  obligation stays within its stated ceiling of the balance -- which are model-independent. Positions are deliberately left unsettled in the shadow exactly as the vault leaves
  them, so the per-step comparison is a check on the lazy settlement itself; a run redeems hundreds
  of positions that have sat through one or more changes.

  Two assertions there are weaker than they look and are that way on purpose. Positions no longer
  sum exactly to the totals -- the totals are restated rounded up where a position is rounded down,
  so they sit a few wei above, and the gap is bounded rather than zero. And solvency is asserted as
  "every position can be paid" rather than "the balance covers `owed`", because `owed` is
  deliberately a ceiling and may exceed the balance by a wei without anyone being short.

  Curve swaps go in both directions and alternate between the two shapes: every odd swap installs a
  random, monotone step table (coarse — 500 iAI per bucket; a full table of 38 buckets reaches
  19,000 iAI, past any ceiling a linear swap can set, and a narrowing swap draws fewer buckets so
  the top lands under the supply) and every even one a linear curve, whose anchor is its ceiling.
  The shadow does not read the ceiling back: it is `buckets * width` or the anchor by construction,
  and both are asserted against the deployed curve. The shadow tracks the kind in force
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
- **`vm.warp(block.timestamp + x)` cannot be repeated inside one function.** Under `via_ir` the
  compiler reads `TIMESTAMP` once per function and reuses the value across the cheatcode calls in
  between, so the second and later warps target the *same moment as the first* and the clock
  silently stops advancing -- no revert, no warning, just a test that no longer exercises the
  elapsed time it claims to. Three tests in this suite were doing exactly that and were found only
  when a fourth one's assertion happened to depend on it. Use `_warp(by)` from `test/Base.t.sol`,
  which reads the timestamp back through `vm.getBlockTimestamp()` and so cannot be folded away.
  Check with:

  ```bash
  grep -rn "vm\.warp(block\.timestamp" test && echo "use _warp() instead"
  ```
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
`Target`; for the exponential curve, `Base`, `Exponent`, `Target`, `BucketWidth`, `Budget` and the
587-entry `Prices` array. This is the one nested object in an otherwise flat file, and it earns the
exception: those keys are meaningless to any other curve, and each kind has its own block rather
than piling more top-level keys into a shared namespace. There is no `Cap` key anywhere: the vault
has no ceiling of its own, and the curve's is a function of its block. `HarvestShare` stays at the
top level because it governs how the collateral's yield is divided, which has nothing to do with
what any curve charges to issue.

`HarvestShare` records only the value in force, not the history. The vault keeps its own epochs, so
a position settled under an older split is restated on chain rather than reconstructed from a file;
`checkDeployment` holds the record against the chain, and `./run.sh setHarvestShare` moves both and
then reads the chain back.

**`Prices` is derived, never edited.** `./run.sh genCurve` runs `script/curve/gen_exponential_table.py`,
which derives the table from `Base`, `Exponent`, `Target`, `BucketWidth` and `Budget` alone --
60-digit `decimal`, each price rounded up to the wei, each bucket priced at its upper bound, and as
many buckets as it takes for the whole table's cost (the exact sum of price times width, one ceiling
over it, exactly as `cost(0, top)` computes it) to reach `Budget` -- and writes the block. **The
table's length is the supply ceiling, and `Budget` is what fixes it.** `Budget` goes no further than
the record: the constructor takes the width, the prices, `Base`, `Exponent` and `Target`, and the
contract is configured by the table it is given. Do not add a `budget` argument to it -- nothing on
chain would read it, and the record already says what the table was sized to. `./run.sh check` and
`./run.sh deployCurve` run the same script in `--check` mode first, so a table that disagrees with
the parameters beside it -- in any entry, or in its length -- cannot be deployed or pass a check;
`checkDeployment` then compares the deployed curve under the kind key against the record's table
entry by entry.

**That second comparison is only fatal while the exponential curve is in force.** `genCurve`
deliberately leaves the record ahead of the chain until `deployCurve` catches it up, so a record
that runs ahead is the documented procedure, not a fault. When some other curve is pricing,
`checkDeployment` warns and passes -- the only thing out of step is a dormant contract. When the
exponential curve *is* pricing, the record no longer describes the table every mint is charged
against and the check fails, as do a missing parameter block and a missing address. `setCurve`
refuses either way: it is about to make that curve price things. Every integer in the block is WAD-scaled and stored as a decimal string like the
rest of the file — `Exponent` is `4711000000000000000` for 4.711, `Budget` is 2,000,000,000 0G in
wei. The unit tests cannot read the record, so `--solidity` also emits
`test/unit/curves/ExponentialTable.sol` as a mirror of **`iai-example.json`** -- the shipped
parameters, which is what the unit tests pin -- and `test/script/Deploy.t.sol` asserts the two
agree. Regenerate the mirror only when the *example's* parameters change. A network record's
parameters (`iai-16661.json`, `iai-16602.json`) may move without touching any test: their tables
are guarded by `run.sh check`, not by `forge test`, exactly as their addresses are. The golden vectors in
`test/unit/curves/ExponentialMintCurve.t.sol` were computed with `mpmath`, independently of the
generator, and may not be edited to follow it.

**The exponential curve's domain is its table, and its top is the supply ceiling.**
`maxSafeSupply()` is `bucketCount * bucketWidth` (14,675 iAI for the shipped parameters: 587
buckets, the smallest number whose total reaches two billion 0G), and the vault issues nothing past
it. Raising the ceiling is therefore always `genCurve --budget ...` → `deployCurve` → `setCurve`, in
that order, and the ceiling moves at the last step; a shorter table is put in force the same way and
brings the ceiling down with it, into burn-only mode if its top is below the live supply. Both paths
are exercised in `test/script/Deploy.t.sol`. `run.sh setCurve ExponentialMintCurve` pre-flights the
kind key against the record's table before broadcasting, so a `genCurve` without `deployCurve` is
caught before a governance transaction is spent. The test fixture stays on the linear curve: its
closed form keeps the fuzz and split tests fast, and its anchor gives the fixture a ceiling of 9,270
iAI that tests can mint up to. Exponential coverage lives in its own suite, in `CurveSwap.t.sol`, in
`Deploy.t.sol` and in the simulation's alternating swaps.

`AnchorCap` is the supply a linear curve's slope was derived against, burned into the curve at
construction, and it is that curve's ceiling. It once shared a record key with the vault's cap, so
deploying a curve after any cap change silently derived a *different* curve from the same published
`R0` and `Target` — double the anchor and the slope came out 271850478687441015 instead of
2021598247004348741, with every number involved still looking plausible. The vault's cap is gone;
the lesson stays: **a curve is built from its own block and nothing else.**

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
events and, on any move outside the expected daily band, `pause()` **and** revoke
`PAUSE_EXEMPT_MINTER_ROLE` if anyone holds it (R10) — the second is part of the response, not a
follow-up to it. `pause()` stops minting but not redemption, so the window between alert and human
response is the exposure. Note the cap is not a
bound on this: it is adjustable upward, so "mint to the cap" is not a fixed quantity of damage.

**R2 — a mint and an immediate full burn costs at most 1 wei, and at a harvest share of zero
costs nothing at all** (the share-denominated half comes back exactly as deposited). Round-trips are effectively free, so a large
mint can be front-run for position. Accepted; slippage protection is the only defence, and the
contracts are upgradeable if a holding period ever becomes necessary.

**R3 — if the a0G oracle stops updating for 21 days, `mint`, `burn`, `harvest`, `setHarvestShare`,
`initialize` and every quote revert.** Settling a position across past changes of the harvest share
does *not* need the oracle — `EpochMath.sync` uses only rates already recorded — so a stall adds no
new way for redemption to fail, but it does mean a deployment cannot be made and the share cannot
be retuned while the feed is down. An external dependency. Note that setting the upstream `maxAge` to zero freezes the system
permanently rather than temporarily.

**R4 — `totalLocked0G` can exceed what the curve accounts for, and has no computable upper
bound.** A redeemer releases 0G at their own average rate while the freed supply is resold at the
marginal rate, so churn ratchets the total upward. The old figure of "roughly 213.9M 0G" was
derived from a fixed `(r0, cap, target)` and is no longer a bound of any kind: the curve can be
replaced with a longer or dearer one without limit, and the table's two-billion-0G budget is a
sizing choice, not a bound on custody. **Never write `require(totalLocked0G <= target)`**,
and do not reintroduce a numeric ceiling in its place.

**R5 — a falling exchange rate leaves late redeemers short.** The harvest sweep goes quiet and
redemption becomes first come, first served. Accepted on the premise that a0G does not depreciate;
`test_RateFall_SweepGoesQuietButLateRedeemersAreLeftShort` pins the actual behaviour so it is a known
quantity rather than a surprise.

The exposure now scales with `harvestShare`: only the 0G-denominated half of a claim grows in a0G
terms as the rate falls, and the share-denominated half tracks the asset down of its own accord. A
position opened at `er_m` is short by `harvestShare * (er_m / er - 1)` of its backing, so at a 50%
share a 10% fall leaves a 5.6% shortfall where it used to leave 11.1%, and a halving leaves 50%
rather than 100%.

**Redemption is still not gated when this happens, and must not become so.** Closing the exit
during a shortfall does not share the loss out, it strands everyone; and the only way to share it —
a pro-rata haircut — requires the payout to read the vault's balance, which is exactly what rule 9
forbids and what makes repeated harvesting safe. What to close is the entrance: `pause()`, and
revoke `PAUSE_EXEMPT_MINTER_ROLE` with it, so nobody opens a new position against a vault that is
already short. Note too that `setHarvestShare` refuses a fallen rate, so the split cannot be
retuned until the collateral recovers — a governance action only, never a user's. Swapping in a narrower curve to wind the system down makes this worse rather
than better — the sweep is gated by `pause`, not by the ceiling, so it keeps running. Use `pause()`,
and revoke `PAUSE_EXEMPT_MINTER_ROLE` with it if anyone holds it (R10).

**R6 — governance can reprice all future issuance, and lower the curve at existing holders' profit.**
`setCurve` takes any contract satisfying `IMintCurve`. Lowering the curve lets an existing holder
burn and re-mint at a profit: they release 0G at their own average and buy the same supply back
cheaper. Measured — dropping `r0` from 4,330 to 2,000 lets a 100-iAI holder extract 238,439 0G.
Solvency is unaffected (the vault only ever pays out what a position holds), but the same supply
then sits on less collateral and the foundation's future harvest shrinks. Accepted deliberately:
no on-chain restriction on the direction of a swap, and no record of the price difference.
`test_Swap_DownwardsIsArbitrageableByExistingHolders` pins it.

**R7 — the supply ceiling moves with the curve, without limit.** The ceiling is the curve's
`maxSafeSupply()`, and `setCurve` accepts any curve, so governance can raise it as far as a table
can be made long (the vault clamps at 2^127) or drop it to zero in one swap. The shipped table's
top is the supply two billion 0G buys, which nobody can reach; but that is a property of one
deployed table, not of the system, and a swap removes the ceiling every other figure here was
quoted against, R1 and R4 included.

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
curve's top and force burn-only from the token side, and leaves supply the vault has no position behind —
which is the premise `_settle`'s arithmetic rests on.

The mitigation got cheap in the same change, though, and should be taken: **`IAI` now has no
admin-settable state at all**, so `DEFAULT_ADMIN_ROLE` on the token does nothing except grant
`MINTER_BURNER_ROLE`. Renouncing it, or moving it behind a timelock, costs nothing operationally.
That was not true before.

**R10 — a pause-exempt minter narrows what `pause()` guarantees.** `PAUSE_EXEMPT_MINTER_ROLE` is
held by nobody at deployment, so by default `pause()` means exactly what it always did. Once
granted, `pause()` closes issuance to the public and to nothing else, and every risk whose stated
mitigation is `pause()` — R1 above, and R5's wind-down — is weakened by precisely that much. Note
what the role does *not* do: it removes a mitigation, it does not add a capability. An exempt mint
runs the same code as any other, so the damage bound is the one an unpaused vault already has, which
R1 already says the cap does not fix.

Accepted deliberately, with the power kept as narrow as the code can make it — same curve, same
ceiling check, same slippage bound, same recipient, `mint` only — and with two operational
consequences. First, a grant is for one operation and should be revoked when that operation is
done; a holder left in place is a standing hole in the pause switch, which is why nothing records
the holder on disk and why `./run.sh grantPausedMinter` reads the chain back. Second, there is no
single switch that closes issuance to everyone: the total stop is `pause()` plus revoking this role,
two transactions. (A curve whose top is zero would do it in one, but needs a contract deployed for
the purpose; it is a fallback, not the procedure.)

## Conventions

- Comments explain *why*, and inline the substance rather than pointing at a document the reader may
  not have. No `see plan §2.A`.
- NatSpec: document every `@param`. The external ABI is documented on the **interfaces**;
  implementations use `@inheritdoc` plus any implementation-specific `@dev`.
- Solidity NatSpec allows only `@custom:*` tags on struct fields — use plain `///` for those.
- Commits and PR bodies carry no AI or tooling attribution, and no personal information.

**R11 — governance can redirect every future wei of collateral yield.** `setHarvestShare` accepts
anything from zero to one, so admin can take the whole appreciation or none of it, repeatedly and
without notice. What it cannot do is reach backwards: the change restates every position by value
at the current rate, so yield already earned keeps the split it was earned under and the obligation
comes out unchanged to within the rounding. `test_Change_MovesNothingBetweenMinterAndFoundation`
pins that, and the simulation re-checks it at every change from whatever state the run has reached.

The power is therefore prospective and total rather than retroactive and partial, which is the
right shape but is still an upgrade-grade lever — it is why the admin key belongs with beacon
ownership. Accepted deliberately, with no timelock and no bound on the direction or size of a
change, in exchange for being able to retune the product's economics without an upgrade.

**A change is value-neutral at the instant it is made, and it is not forward-neutral. Do not
write that there is "no advantage in choosing when".** Within an epoch a minter captures
`1 - share` of the appreciation of the a0G they originally deposited. A change re-bases that onto
the position's *current* value, which is smaller — the foundation has already taken its part — and
at the same time turns the foundation's accrued part from a non-compounding 0G amount into shares
that compound for it. So re-issuing the **same** share still moves future yield toward the
foundation. Measured on the fixture, 100 iAI held for two years leaves the minter 509,574 0G with
no change at all, 507,407 with one same-share change, and 505,396 with twenty-four.

This is the compounding asymmetry a per-block accrual would have had, and avoiding it is why that
design was rejected — restating at a change does not remove it. What it does is take it out of the
hands of anyone who can call a permissionless function and put it in the hands of the one role that
can call this one. It is bounded by how often governance acts, always runs in the foundation's
favour, and is unreachable by a user. Removing it would mean keeping each position's original
deposit basis as a third field and letting the 0G half go negative, which the two-bucket
representation cannot express; that trade was not taken.

**R12 — a change of the harvest share anchors on the live rate, permanently.**
`setHarvestShare` reads the oracle, restates every position at that reading, and stores it in the
epoch it opens, where it stays a divisor for every later settlement of a position that predates it.

It is tempting to reason that a restatement which preserves value cannot transfer anything. That
reasoning is wrong, and it is the trap this entry exists to close: the restatement preserves value
*at the rate it uses*, and at any other rate it is a transfer of
`(R - r) * [share * claimA0G - (1 - share) * claim0G / R]`, where `R` is what was read and `r` the
truth.

**Be careful with the scaling, which is not what it first looks like.** Writing `R = r(1 + e)`, that
expression is about `e * share * (1 - share) * (the appreciation the position has accrued since it
was last restated)` — not `e` times the whole claim. A position restated a moment ago has accrued
nothing, and the transfer collapses to second order in `e`. Measured on the fixture (100 iAI, a 50%
share, one year after the mint, surplus already swept, so the balance is exactly what is owed):

| reading | shortfall against the balance |
| --- | --- |
| 2.00x | 15.1% |
| 1.05x | 0.22% |
| 1.01x | 0.03% |

At twice the true rate the vault owes one holder 430,302 a0G against a balance of 373,798: **15%
short with no rate fall having occurred**, the sweep silent, late redeemers stranded as in R5.
(Before a sweep the balance is 399,877 and the same glitch leaves it 7.6% short — quote which.)

Nor can it be undone: a rate below the previous epoch's is refused, so the corrective call is
blocked until the true rate climbs past the bad reading. The only exit is an upgrade.

Accepted, on the same premise the rest of the system rests on: the a0G oracle is assumed sound. R1
already concedes that its write key can drain the vault outright without going near this path, so
hardening one governance call against that key while the direct route stays open buys nothing.
**That, and only that, is the reason there is no rate band here.** It is not that a band would be
impractical: the scaling above says a deviation check at a couple of per cent would be both
tolerable in ordinary operation and enough to keep the damage under a tenth of a per cent, so the
mitigation is available and cheap if the premise underneath R1 ever changes. What a band must not
be derived from is the oracle itself — an operator reading the same feed a block earlier gets a
window centred on the manipulated value, which is no window at all.

What *is* enforced is the direction. A reading below the previous epoch's is refused outright, so a
depressed reading can never be anchored; only an inflated one can, and that is the case the
operational rule covers.

**Operational requirement: do not move the harvest share while the oracle is behaving unusually.**
It is the same rule R1 already imposes, with a worse failure mode attached — R1's damage leaves the
accounting intact, this writes a permanent divisor into it.
