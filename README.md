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
| `src/IAI.sol` | The ERC-20. Hard supply cap; mint and burn restricted to `MINTER_BURNER_ROLE`, held only by the vault. Deliberately **not** `ERC20Burnable` — a holder burning their own tokens would strand the collateral behind them. |
| `src/IAIVault.sol` | Custody, positions, pricing. `mint` / `burn` / `burnFor` / `harvest`. |
| `src/CreditRegistry.sol` | Staking with a cooldown. Records who has how much iAI earning; the allowance itself is metered off-chain. |
| `src/libraries/MintCurve.sol` | Stateless curve maths. No storage, no state. |
| `src/mocks/` | Stand-in a0G and its oracle, for networks without the real thing. In `src/` rather than `test/` because they are deployed and verified on testnets. |

### The curve

The marginal price rises linearly with supply:

```
rate(s)   = R0 + slope·s              0G per iAI
locked(s) = R0·s + (slope/2)·s²       0G locked at supply s
cost(s→s+d) = locked(s+d) − locked(s) what a mint charges
```

`slope` is **derived** at initialization from `R0`, `cap` and `target` — never supplied — so the
three published numbers are the only thing anyone has to agree on. With the shipped parameters:

| | |
| --- | --- |
| `R0` (price at zero supply) | 4,330 0G / iAI |
| `Cap` (max supply) | 9,270 iAI |
| `Target` (0G locked at full supply) | 127,000,000 0G |
| derived `slope` | 2,021,598,247,004,348,741 |
| implied price at cap | 23,070.2157 0G / iAI |

`cost()` is the only pricing primitive. `lockedAt()` floors and exists for views and reconciliation
only; it sits a hair under `target` at the cap, so never assert equality between the two.

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
- **`totalLocked0G` can exceed `target`.** A redeemer releases 0G at their average rate while the
  freed supply is resold at the marginal rate, so churn ratchets the total upward — up to about
  213.9M 0G. Never write `require(totalLocked0G <= target)`.

## Layout

```
src/            contracts
script/deploy/  the chain work, as abstract contracts: IAIDeployer (system wiring and mock
                collateral), AccountFunder, UpgradeChecker — plus the thin *.s.sol shells
                that read parameters and write results back
script/         Upgrade.s.sol — beacon upgrades and the fork rehearsal
deployments/    per-network parameters *and* the addresses a run produced
test/unit/      per-function behaviour, golden vectors, revert and permission matrices, and
                the scripts' chain work. Never touches the filesystem.
test/sim/       seeded randomized simulation against an independent shadow model
test/script/    the file half of the scripts: parameters in, addresses out
docs/           frontend integration guide
run.sh upgrade.sh faucet.sh verify.sh   operator wrappers
```

`deployments/iai-<chainId>.json` is both the input and the record: hand-written parameters go in, the
addresses of what was deployed come back into the same file. `iai-example.json` is the template.

## Build and test

```bash
forge build
forge test                      # 82 tests, a few seconds
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
from stranding the rest of a deployment. Running `forge script` by hand works too; see `run.sh` for
the exact invocations.

**The vault deploys paused.** Opening issuance is a separate, explicit transaction — that is the only
launch-timing control the system has, and it is deliberately manual. The `CreditRegistry` deploys
open; nobody can stake before iAI exists.

Deployment grants `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE` and beacon ownership to the deploying account.
**Hand them to the multisig before launch.**

Other operator entrypoints: `./run.sh pause`, `./run.sh harvest`, and
`forge script script/deploy/IAI.s.sol --sig "setFoundation(address)" <addr>`.

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

The rehearsal forks the configured chain, snapshots every curve constant, every balance and the
positions named in `CHECK_ACCOUNTS`, upgrades, and reverts if anything moved. `iai` and `registry`
are the other two targets.
