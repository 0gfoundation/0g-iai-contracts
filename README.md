# iAI Contracts

Smart contracts for **iAI**, a compute-entitlement token on 0G. Users lock **a0G** (a yield-bearing
restaking share) as collateral, mint iAI along a rising bonding curve, and stake iAI to earn a daily
allowance of AI compute. Collateral is never sold: redeeming returns the same *0G value* that was
locked, and the yield the collateral earned in the meantime is swept to the foundation.

```
        a0G                    iAI                      compute
  ┌─────────────┐   mint   ┌──────────┐   stake   ┌────────────────┐
  │  collateral │ ───────► │   iAI    │ ────────► │ CreditRegistry │
  │  (locked)   │ ◄─────── │  token   │ ◄──────── │  (entitlement) │
  └─────────────┘   burn   └──────────┘  unstake  └────────────────┘
         │                                             │
         │ harvest (yield only)                        │ off-chain meter
         ▼                                             ▼
     foundation                                  daily allowance
```

## Contracts

| Contract | Role |
| --- | --- |
| `src/IAI.sol` | The ERC-20. Mint and burn restricted to `MINTER_BURNER_ROLE`, held only by the vault; the supply ceiling is the vault's, not the token's. Deliberately **not** `ERC20Burnable` — a holder burning their own tokens would strand the collateral behind them. |
| `src/IAIVault.sol` | Custody, positions, the supply cap, and which curve is pricing. `mint` / `burn` / `burnFor` / `harvest`. |
| `src/CreditRegistry.sol` | Staking with a cooldown. Records who has how much iAI earning; the allowance itself is metered off-chain. |
| `src/interfaces/IMintCurve.sol` | The pricing surface the vault calls. Three `view` functions, so a curve reaches the vault by `STATICCALL` and can neither write state nor reenter. |
| `src/curves/ExponentialMintCurve.sol` | The curve in force: the exponential curve as a table of 371 bucket prices, 25 iAI per bucket. The table is storage written once by the constructor and nothing can write it again — no setter, no owner, no proxy — so a curve is still a value, and replacing one means deploying another and repointing the vault. |
| `script/curve/gen_exponential_table.py` | The one definition of how that table is derived from the formula. Standard-library Python; `run.sh check` re-derives and compares. |
| `src/curves/LinearMintCurve.sol` | The original curve, still deployable. Every parameter `immutable`, zero storage. |
| `src/curves/LinearCurveMath.sol` | The linear curve's closed form. A library: no storage, no state. |
| `src/mocks/` | Stand-in a0G, its oracle, and a W0G for the a0G vault to sit over, for networks without the real things. In `src/` rather than `test/` because they are deployed and verified on testnets. `MockA0G` mirrors the real token's shape: an ERC-4626 whose share price comes from the oracle, not from what it holds. |

### The curve

The marginal price rises exponentially in the cube of the supply:

```
rate(s) = base · e^(exponent · (s / target)³)        0G per iAI
```

There is no closed form for its integral and no `exp` on chain, so the contract holds a **table**:
supply is cut into buckets of 25 iAI and each bucket is priced flat at the value the formula takes at
the bucket's **upper** bound, rounded up to the wei. A mint is charged the exact sum of bucket price
times overlap for every bucket it touches, divided by 1e18 once and rounded up — one ceiling, not one
per bucket, which is what keeps the price monotonic at the wei and makes splitting a mint never
cheaper. Pricing at the upper bound means the table never sits below the smooth curve anywhere.

The table is produced off chain by `script/curve/gen_exponential_table.py` (standard-library Python,
60 significant digits) and written into the deployment record beside the parameters it came from;
`run.sh check` re-derives it and compares entry by entry. With the shipped parameters:

| | |
| --- | --- |
| `base` (price at zero supply) | 3,237.4 0G / iAI |
| `exponent` | 3.419 |
| `target` (the supply the exponent is normalised against) | 9,270 iAI |
| `bucketWidth` | 25 iAI, 371 buckets, table top 9,275 iAI |
| price of the first bucket | 3,237.40 0G / iAI |
| price at 2,000 iAI (the first public mint after the pre-mint) | 3,354.86 0G / iAI |
| price of the last bucket | 99,415.29 0G / iAI, 30.7× the base |
| 0G locked by the first 2,000 iAI | 6,532,352 0G |
| 0G locked at the cap of 9,270 iAI | 128,170,726 0G (the smooth integral is 126.96M) |
| largest step between adjacent buckets | 2.80%, at the top; 0.13% near 2,000 |

`cost()` is the only pricing primitive. `lockedAt()` floors and exists for charts and reconciliation
only. `priceAt(i)`, `prices()`, `bucketOf(s)` and `rateAt(s)` expose the table for tooling.

**The table has a top, and the cap must stay under it.** `maxSafeSupply()` is 9,275 iAI, so
`setCap` above that is refused while this curve is in force. Raising the target means generating a
new table, deploying a new curve and repointing the vault — the cap can only follow once the new
table covers it. That ordering is deliberate: a supply the table does not price is a supply nobody
has decided a price for.

**The curve and the supply cap are separate, and both move.** The vault's cap is its own number and
is adjustable in either direction; `base`, `exponent` and `target` are provenance on the curve,
recording how the table was derived, and enforce nothing. Governance can also replace the whole
curve — the linear curve, `LinearMintCurve`, is still deployable from the same record. Neither
reaches anything already minted — see below — but it does mean no figure on this page is a permanent
bound. Read them from the chain rather than hard-coding them.

### Replacing the curve, and moving the cap

Positions record an **absolute amount of 0G**, not the curve parameters that produced it, and
redemption never consults a curve. So swapping the curve reprices nothing already minted: a holder
who minted before a swap redeems for exactly what they locked, and mints after it use the new curve.
A holder who mints on both sides gets one blended average for the whole position — the guarantee is
"nobody's existing collateral is repriced", not "every coin redeems at the price it was minted at".

Lowering the cap below the live supply is a supported state, **burn-only mode**: `mint` refuses,
and redemption, rescue, staking and the harvest sweep all carry on untouched. It needs no mode flag
— `mint`'s ceiling check is simply always true once the cap is under the supply. Note that `harvest`
is gated by `pause`, not by the cap, so `setCap(0)` is not a wind-down switch on its own; `pause()`
is.

### Rounding

Every division that can lose a wei rounds in the vault's favour: value entering rounds **up**, value
leaving rounds **down**. A consequence worth knowing before reading the tests: splitting one mint
into many smaller ones is strictly *more* expensive than doing it at once, so there is no rounding
arbitrage in either direction.

## What redemption does and does not promise

Burning returns the position's own average rate — the same **0G value** that was locked. Because a0G
appreciates, that is fewer *a0G tokens* than went in. This is the design, not a loss, and any UI must
denominate in 0G value with a0G counts secondary.

Two caveats are real and must be stated to users:

- **Staked iAI must be unstaked first.** `initiateUnstake` → wait out the cooldown → `unstake` → then
  `burn`. `burn` itself is never pausable, but reaching it can take a day.
- **`totalLocked0G` can exceed what the curve accounts for at the live supply, with no computable
  ceiling.** A redeemer releases 0G at their average rate while the freed supply is resold at the
  marginal rate, so churn ratchets the total upward. There is no numeric bound to quote: the cap can
  be raised and the curve replaced with a dearer one. Never write `require(totalLocked0G <= X)` for
  any curve-derived `X`.

## Layout

```
src/            contracts
script/deploy/  the chain work, as abstract contracts: IAIDeployer (system wiring and mock
                collateral), AccountFunder, UpgradeChecker — plus the thin *.s.sol shells
                that read parameters and write results back
script/         Upgrade.s.sol, Handover.s.sol — beacon upgrades and the governance handover
script/curve/   gen_exponential_table.py — derives the exponential curve's table from its
                parameters, writes it into the record, and re-checks it
deployments/    per-network parameters *and* the addresses a run produced
test/unit/      per-function behaviour, golden vectors, revert and permission matrices, and
                the scripts' chain work. Never touches the filesystem.
test/unit/curves/  the curves themselves, plus CurveConformance.t.sol — the abstract suite
                every curve must inherit and pass before the vault may point at it
test/sim/       seeded randomized simulation against an independent shadow model
test/script/    the file half of the scripts: parameters in, addresses out
docs/           frontend integration guide
run.sh upgrade.sh handover.sh faucet.sh verify.sh   operator wrappers
```

`deployments/iai-<chainId>.json` is both the input and the record: hand-written parameters go in, the
addresses of what was deployed come back into the same file. `iai-example.json` is the template.

## Build and test

```bash
forge build
forge test                      # 223 tests, a few seconds
SIM_LONG=1 forge test --match-test test_Sim_Long   # 100k-operation simulation
python3 script/curve/gen_exponential_table.py deployments/iai-example.json --check   # the table is its parameters'
```

The unit fixture builds the system by calling the deployment script's own `IAIDeployer`, so every
test run is also a rehearsal of the real deployment, including its post-deploy sanity checks. A
fixture that re-implemented the wiring would let the two drift, and the suite could stay green
against a topology the script no longer produces.

## Deploy

```bash
cp .env.example .env                  # PRIVATE_KEY, TEST_MNEMONIC
cp config.example.sh config.sh        # CHAIN_ID and RPC; gitignored
                                      # (needs python3 >= 3.9 for the curve table; standard library only)
$EDITOR deployments/iai-<chainid>.json   # start from iai-example.json
./run.sh genCurve     # derive the exponential curve's table from the parameters in the record
                      # (pass --base/--exponent/--target/--width to change them; the table is
                      # never edited by hand, and `check` re-derives and compares it)

./run.sh              # mock collateral (off mainnet), then the system
./run.sh accounts     # testnet: derive and fund the account set
./run.sh status       # read it back
./run.sh unpause      # open issuance
./verify.sh           # publish sources to the 0G explorer
```

`config.sh` carries the gas flags every 0G transaction needs — `--slow --with-gas-price 3gwei
--priority-gas-price 3gwei`, since 0G's EIP-1559 wants both pinned and `--slow` stops a nonce gap
from stranding the rest of a deployment.

Changing the curve on a live network is three commands, in this order: `./run.sh genCurve ...`
rewrites the table in the record, `./run.sh deployCurve ExponentialMintCurve` deploys it and records
the address under its kind, and `./run.sh setCurve ExponentialMintCurve` puts it in service. Nothing
already minted is repriced. The vault's cap has to fit under the table in force: if the new table is
taller than the old, `setCap` may follow the swap but cannot precede it; if the new table's top is
below the current cap, `setCap` to at most the new top comes first or the swap is refused.

Running `forge script` by hand works too, but set **`FOUNDRY_PROFILE=deploy`**: under the default
profile `deployments/` is read-only, so that a test which forgets to redirect a script fails with a
permission error instead of overwriting a deployment record. See `run.sh` for the exact invocations.

**The vault deploys paused.** Opening issuance is a separate, explicit transaction — that is the only
launch-timing control the system has, and it is deliberately manual. The `CreditRegistry` deploys
open; nobody can stake before iAI exists.

Deployment grants `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` and beacon ownership to the deploying account,
and grants `RESCUE_ROLE` to nobody — so `burnFor` is unreachable until governance opens it.

## Handing over governance

Fill in `Admin`, `Guardian`, `Rescuer` and `BeaconOwner` in the deployment file, then:

```bash
./handover.sh status      # who holds what right now
./handover.sh grant       # every role and beacon to its target; deployer keeps its own
./handover.sh status      # confirm — and execute something from the Safe
./handover.sh renounce    # stand the deployer down
```

Two transactions, deliberately. `grant` leaves the deployer in place, so the targets can be read
back and a Safe confirmed to actually respond before the only key that still works is given up.
`renounce` re-reads governance from the chain and refuses unless the targets already hold
everything — a mistyped address stops there, with the deployer still in control, rather than after,
with nobody in control. Beacon ownership is one-step `Ownable` with no acceptance step, so that
precondition is the only safety net it has.

Other operator entrypoints: `./run.sh pause`, `./run.sh harvest`, and
`forge script script/deploy/IAI.s.sol --sig "setFoundation(address)" <addr>`.

| Role | Intended holder | Can do |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | multisig | grant and revoke roles, `setFoundation` |
| `PAUSER_ROLE` | guardian | close and open issuance, nothing else — a lighter key, because speed matters more than ceremony |
| `RESCUE_ROLE` | multisig + timelock | `burnFor`, which can only ever return collateral to its owner |
| beacon owner | multisig + timelock | upgrade one contract; each has its own beacon |

## Upgrades

Every contract sits behind its own `UpgradeableBeacon`, so one upgrade cannot reach the others.
Correctness is established by rehearsal on a mainnet fork, not by an on-chain self-check: a guard the
contract computes about itself is only sound while it reads the right storage slots, which is exactly
what is in doubt when a layout has shifted.

```bash
export CHECK_ACCOUNTS=0xLargestHolder,0xNextOne   # optional but recommended

./upgrade.sh rehearse vault    # forks the chain, upgrades there, compares state, diffs layout
./upgrade.sh vault             # only after the rehearsal passes
```

The rehearsal forks the configured chain, snapshots the curve address and cap, every balance and the
positions named in `CHECK_ACCOUNTS`, upgrades, and reverts if anything moved. The curve address is
in there because pricing lives outside the beacon now: repointing it is the one thing an upgrade can
still do to reprice the system. `iai` and `registry`
are the other two targets.
