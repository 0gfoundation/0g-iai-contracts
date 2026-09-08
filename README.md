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
| `src/curves/LinearMintCurve.sol` | The curve in force. Every parameter `immutable`, zero storage — a curve is a value, and replacing one means deploying another and repointing the vault. |
| `src/curves/LinearCurveMath.sol` | The linear curve's closed form. A library: no storage, no state. |
| `src/mocks/` | Stand-in a0G and its oracle, for networks without the real thing. In `src/` rather than `test/` because they are deployed and verified on testnets. |

### The curve

The marginal price rises linearly with supply:

```
rate(s)   = R0 + slope·s              0G per iAI
locked(s) = R0·s + (slope/2)·s²       0G locked at supply s
cost(s→s+d) = locked(s+d) − locked(s) what a mint charges
```

`slope` is **derived** in the curve's constructor from `R0`, `anchorCap` and `target` — never
supplied — so the three published numbers are the only thing anyone has to agree on. With the
shipped parameters:

| | |
| --- | --- |
| `R0` (price at zero supply) | 4,330 0G / iAI |
| `anchorCap` (the supply `slope` is pinned against) | 9,270 iAI |
| `Target` (0G the curve accounts for at `anchorCap`) | 127,000,000 0G |
| derived `slope` | 2,021,598,247,004,348,741 |
| implied price at `anchorCap` | 23,070.2157 0G / iAI |

`cost()` is the only pricing primitive. `lockedAt()` floors and exists for charts and reconciliation
only; it sits a hair under `target` at the anchor, so never assert equality between the two.

**The curve and the supply cap are separate, and both move.** The vault's cap is its own number and
is adjustable in either direction; `anchorCap` is provenance on the curve, recording how `slope` was
derived, and enforces nothing. Governance can also replace the whole curve. Neither reaches anything
already minted — see below — but it does mean no figure on this page is a permanent bound. Read them
from the chain rather than hard-coding them.

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
- **`totalLocked0G` can exceed the curve's `target`, with no computable ceiling.** A redeemer
  releases 0G at their average rate while the freed supply is resold at the marginal rate, so churn
  ratchets the total upward. There is no numeric bound to quote: the cap can be raised and the curve
  replaced with a dearer one. Never write `require(totalLocked0G <= target)`.

## Layout

```
src/            contracts
script/deploy/  the chain work, as abstract contracts: IAIDeployer (system wiring and mock
                collateral), AccountFunder, UpgradeChecker — plus the thin *.s.sol shells
                that read parameters and write results back
script/         Upgrade.s.sol, Handover.s.sol — beacon upgrades and the governance handover
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
forge test                      # 181 tests, a few seconds
SIM_LONG=1 forge test --match-test test_Sim_Long   # 100k-operation simulation
```

The unit fixture builds the system by calling the deployment script's own `IAIDeployer`, so every
test run is also a rehearsal of the real deployment, including its post-deploy sanity checks. A
fixture that re-implemented the wiring would let the two drift, and the suite could stay green
against a topology the script no longer produces.

## Deploy

```bash
cp .env.example .env                  # PRIVATE_KEY, TEST_MNEMONIC
cp config.example.sh config.sh        # CHAIN_ID and RPC; gitignored
$EDITOR deployments/iai-<chainid>.json   # start from iai-example.json

./run.sh              # mock collateral (off mainnet), then the system
./run.sh accounts     # testnet: derive and fund the account set
./run.sh status       # read it back
./run.sh unpause      # open issuance
./verify.sh           # publish sources to the 0G explorer
```

`config.sh` carries the gas flags every 0G transaction needs — `--slow --with-gas-price 3gwei
--priority-gas-price 3gwei`, since 0G's EIP-1559 wants both pinned and `--slow` stops a nonce gap
from stranding the rest of a deployment.

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
