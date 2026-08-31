# iAI — Frontend Integration Guide

Everything a frontend needs to call these contracts, organised by **what the user is trying to do**
rather than by contract. You do not need to understand the protocol to use this document; every
parameter says where its value comes from and what, if anything, you must do to it first.

---

## 0. Read this first: two things that trip up every integration

**① All amounts are integers with 18 decimals.** iAI, a0G and 0G all use 18. There are no
exceptions in this system and no token here uses 6 or 8. A user typing `1.5` means `1500000000000000000`.

```ts
import { parseUnits, formatUnits } from "viem";
const onChain  = parseUnits(userTyped, 18);   // "1.5"  -> 1500000000000000000n
const display  = formatUnits(onChain, 18);    // 1500000000000000000n -> "1.5"
```

Never build these by hand and never use JavaScript `number` for them — they exceed `Number.MAX_SAFE_INTEGER`.
Use `bigint` end to end.

**② Redeeming returns fewer a0G tokens than were deposited — the contract is working correctly.**
a0G is yield-bearing: a holder's balance never grows, the **exchange rate** does. Positions are
recorded in **0G value**, not in a0G tokens, so redemption returns the same 0G value that was locked,
which by then is a smaller number of a0G. Measured on a test deployment:

| | a0G tokens | 0G value |
| --- | --- | --- |
| Locked | 4,330.885 | 4,331.0108 |
| Redeemed later | 3,922.223 | 4,331.0108 |
| Difference | −408.66 | 0 |

Both numbers are available from the contracts: every quote returns the 0G value *and* the a0G amount
(§3.1, §5.1), and `exchangeRate()` converts between them at any time. Which one a screen leads with is
a product decision — the point here is that the two units diverge over time and are not
interchangeable, so a value cached in one unit cannot be re-displayed in the other later.

---

## 1. Addresses, ABIs and networks

### Where the addresses come from

Every deployed address lives in this repository — **`0gfoundation/0g-iai-contracts`** (private; ask
the contracts team for access if you cannot open it) — one JSON file per network:

| Network | chainId | RPC | Explorer | Address file |
| --- | --- | --- | --- | --- |
| 0G mainnet | `16661` | `https://evmrpc.0g.ai` | `https://chainscan.0g.ai` | `deployments/iai-16661.json` |
| 0G Galileo testnet | `16602` | `https://evmrpc-testnet.0g.ai` | `https://chainscan-galileo.0g.ai` | `deployments/iai-16602.json` |

```bash
git clone git@github.com:0gfoundation/0g-iai-contracts.git
jq . 0g-iai-contracts/deployments/iai-16602.json
```

**These files exist before deployment and contain only parameters at that point.** The address keys
below are written *by the deployment itself*, so a file with no `IAIVault` key simply means that
network has not been deployed yet — it is not a mistake on your side. Ask the contracts team rather
than guessing an address. Once deployed, the file is committed, so `git pull` is how you get the
current addresses; there is no separate registry or API to call.

Each contract appears three times. **Always use the bare name.**

```jsonc
{
  "IAI":            "0x...",  // ← USE THIS   (the proxy; the permanent address)
  "IAIImpl":        "0x...",  //   ignore     (implementation, changes on every upgrade)
  "IAIBeacon":      "0x...",  //   ignore     (upgrade pointer, admin only)

  "IAIVault":       "0x...",  // ← USE THIS
  "CreditRegistry": "0x...",  // ← USE THIS
  "A0G":            "0x..."   // ← USE THIS   (the collateral token)
}
```

`IAI`, `IAIVault`, `CreditRegistry` and `A0G` **never change**, including across upgrades. You can
hardcode them per network or read the JSON at build time. `*Impl` and `*Beacon` are internal
plumbing — a frontend that references them will break at the first upgrade.

### The collateral token (a0G)

On mainnet `A0G` is an existing token that this project does not own, already live at
**`0x4B3c2f55fa67679b382c979A082Df1B32079B4cB`**:

| | |
| --- | --- |
| `name()` | `Ascend Staked 0G` |
| `symbol()` | `a0G` |
| `decimals()` | `18` |
| `approve` / `allowance` / `balanceOf` / `transfer` | all present and working — it is a normal ERC-20 |
| `permit` (EIP-2612) | **absent.** `DOMAIN_SEPARATOR()` and `nonces()` revert. |

The missing `permit` is why minting is always two transactions (§2). Treat a0G as a plain ERC-20 and
use the standard ERC-20 ABI for it.

On Galileo, `A0G` points at a mock with the same interface plus an open faucet (§10).

### Where the ABIs come from

```bash
forge build
# out/IAI.sol/IAI.json           -> .abi
# out/IAIVault.sol/IAIVault.json -> .abi
# out/CreditRegistry.sol/CreditRegistry.json -> .abi
```

Take the `.abi` field. For a0G, the standard ERC-20 ABI is enough: you only ever call
`balanceOf`, `allowance` and `approve` on it.

> **Do not use the BeaconProxy ABI.** Point the `IAIVault` ABI at the `IAIVault` address. The proxy
> forwards everything; your library does not need to know a proxy is involved.

---

## 2. The approve matrix

This is the single most common integration mistake. Two of the four actions need an approval and two
do not.

| User action | Contract & function | Approval needed first? | Details |
| --- | --- | --- | --- |
| **Mint iAI** | `IAIVault.mint` | ✅ **Yes** — `a0G.approve(vaultAddress, amount)` | The vault pulls a0G from the user. |
| **Burn iAI** | `IAIVault.burn` | ❌ **No** | The vault holds `MINTER_BURNER_ROLE` on iAI and burns directly. An allowance is neither checked nor needed. |
| **Stake iAI** | `CreditRegistry.stake` | ✅ **Yes** — `iAI.approve(registryAddress, amount)` | The registry is a separate contract and pulls the tokens. |
| **Unstake iAI** | `CreditRegistry.initiateUnstake` / `unstake` | ❌ **No** | The tokens are already inside the registry. |

**a0G has no `permit`.** It is an ERC-4626 vault share that does not implement EIP-2612, so there is
no gasless one-click signature path. Minting is always two transactions: `approve`, then `mint`.

### The standard approval check

```ts
const allowance: bigint = await a0g.read.allowance([userAddress, vaultAddress]);
if (allowance < a0GIn) {
  await a0g.write.approve([vaultAddress, a0GIn]);   // or MAX_UINT256, see below
  // wait for the receipt before sending the mint
}
```

Approving the exact amount means one approval per mint. Approving `2n**256n - 1n` means one approval
ever. Both are common; pick one and be consistent. If you approve exactly, use the **quoted** amount
widened by the same tolerance you use for `maxA0GIn` (§3.2), or the approval will be a wei short and
the mint will revert.

---

## 3. Minting iAI

### 3.1 Quote the cost

```solidity
IAIVault.quoteMint(uint256 d) view returns (uint256 delta0G, uint256 a0GIn)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `d` | The amount of iAI the user wants, from your input box. **Cap it at `cap() - totalSupply()`** — beyond the remaining headroom this reverts with `CapExceeded`, the same error `mint` gives. | `parseUnits(input, 18)` |

| Return | Meaning | Display |
| --- | --- | --- |
| `delta0G` | The **0G value** this mint locks; what redemption will later return. | `formatUnits(delta0G, 18)` + " 0G" |
| `a0GIn` | The **a0G tokens** that will actually leave the wallet. | `formatUnits(a0GIn, 18)` + " a0G" |

This is a `view` call — free, no gas, no wallet prompt. Re-run it whenever the input changes and
again right before submitting, because the price rises as other people mint.

**Quotes fail wherever the action they price would fail**, with the identical error. `quoteMint`
raises `CapExceeded` and `quoteBurn` raises `BurnExceedsPosition` exactly where `mint` and `burn`
do. That is deliberate: a quote that answered anyway would hand you a number the contract refuses a
moment later. Validate the input against `cap() - totalSupply()` and `positionOf().iaiOutstanding`
before quoting, or catch the error and treat it as "too much".

**The reverse direction.** If your UI has a "spend all my a0G" button:

```solidity
IAIVault.quoteMintForA0G(uint256 a0GAmount) view returns (uint256 d)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `a0GAmount` | `a0G.balanceOf(userAddress)`, or a smaller amount the user typed. | Already 18-decimal wei if read from `balanceOf`; `parseUnits(input, 18)` if typed. |

It returns the `d` you then pass to `mint`. It rounds down, so the resulting mint never costs more
than `a0GAmount`.

Unlike `quoteMint`, this one **does not revert** when the balance would buy more than the cap
allows — it returns the remaining headroom. It was asked what a given spend buys, and the headroom
is a true, mintable answer to that question. So a "spend everything" button never errors; it just
stops growing once the cap is in sight.

### 3.2 Send the transaction

```solidity
IAIVault.mint(uint256 d, uint256 maxA0GIn, uint256 deadline)
```

| Parameter | Where it comes from | Conversion / handling |
| --- | --- | --- |
| `d` | The same `d` you passed to `quoteMint`. | Already wei. Pass it unchanged — do not re-derive it. |
| `maxA0GIn` | `a0GIn` from `quoteMint`, **widened by a slippage tolerance**. | `a0GIn * (10000n + toleranceBps) / 10000n`. See below. |
| `deadline` | Current time plus how long the user will wait. | **Unix seconds, not milliseconds.** `BigInt(Math.floor(Date.now()/1000) + 600)` for 10 minutes. `Date.now()` alone is 1000× too large and will never expire. |

**About `maxA0GIn`.** It is the only slippage bound, and it covers both risks at once: the price
rising because someone minted first, and the a0G exchange rate moving between your quote and the
transaction landing. Pass the quoted `a0GIn` widened by a tolerance. Too tight and the transaction
reverts with `ExcessiveInput` on a busy block; too loose and the user can overpay. It is a hard cap
on what leaves the wallet, so it can be reasoned about directly: the transaction will spend at most
`maxA0GIn`, never more. `50` bps is a reasonable starting point.

```ts
const TOLERANCE_BPS = 50n;                                   // 0.5%
const [delta0G, a0GIn] = await vault.read.quoteMint([d]);
const maxA0GIn = (a0GIn * (10_000n + TOLERANCE_BPS)) / 10_000n;
const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

await vault.write.mint([d, maxA0GIn, deadline]);
```

### 3.3 Confirm

On success the transaction emits `Minted` (§7). `iAI.balanceOf` increases by exactly `d`: minting
delivers the precise amount asked for, and it is the *cost* that varies, never the output.

---

## 4. Reading a position

```solidity
IAIVault.positionOf(address account)
  view returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `account` | The connected wallet address. | none |

| Return | Meaning | Display |
| --- | --- | --- |
| `locked0G` | 0G value this user has locked. | `formatUnits(locked0G, 18)` + " 0G" |
| `iaiOutstanding` | iAI they minted and have not yet redeemed. This is the maximum they can burn. | `formatUnits(..., 18)` + " iAI" |
| `avgRate` | Their average price, in 0G per iAI. Zero when the position is empty. | `formatUnits(avgRate, 18)` + " 0G/iAI" |

**`iaiOutstanding` is not the same as `iAI.balanceOf(user)`.** iAI is freely transferable, so an
address can hold tokens it did not mint (those are not redeemable by it) or have sent away tokens it
did mint (the position remains, but the tokens must be back in the wallet to redeem). They are
independent reads; see §8.

Useful companions:

```solidity
IAIVault.exchangeRate() view returns (uint256)   // 0G per a0G, scaled by 1e18
IAI.balanceOf(address)  view returns (uint256)   // freely transferable token balance
IAI.totalSupply()       view returns (uint256)   // current supply; drives the price
IAIVault.cap()          view returns (uint256)   // hard maximum supply
```

To convert between the two units anywhere in your UI:

```ts
const valueIn0G  = (a0GAmount * exchangeRate) / 10n ** 18n;
const tokensA0G  = (valueIn0G  * 10n ** 18n) / exchangeRate;
```

---

## 5. Burning iAI (redeeming collateral)

### 5.1 Quote the payout

```solidity
IAIVault.quoteBurn(address minter, uint256 b) view returns (uint256 unlocked0G, uint256 a0GOut)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `minter` | The connected wallet address. | none |
| `b` | How much iAI to burn. **Cap the input at `min(iaiOutstanding, iAI.balanceOf(user))`** — above `iaiOutstanding` this reverts with `BurnExceedsPosition`, the same error `burn` gives, so quoting and executing fail identically. | `parseUnits(input, 18)` |

| Return | Meaning |
| --- | --- |
| `unlocked0G` | The 0G value released. Equals what was locked for that slice. |
| `a0GOut` | The a0G tokens actually sent. Lower than what they deposited, by design. |

### 5.2 Send the transaction

```solidity
IAIVault.burn(uint256 b, uint256 deadline)
```

| Parameter | Where it comes from | Conversion / handling |
| --- | --- | --- |
| `b` | The same `b` you quoted. | Already wei. |
| `deadline` | Now + wait tolerance. | Unix **seconds**. Same as mint. |

**No approval, and no slippage parameter.** Both omissions are deliberate: the vault can burn
directly, and the released amount is fixed in 0G — the a0G it converts to only ever shrinks as a0G
appreciates, so there is no adverse move for a bound to catch. `deadline` alone limits the drift.

---

## 6. Staking iAI for compute

Three steps and a waiting period. The daily allowance itself is metered off-chain; the chain only
records who has how much staked.

### 6.1 Stake

```solidity
CreditRegistry.stake(uint256 amount)
```

| Parameter | Where it comes from | Conversion / handling |
| --- | --- | --- |
| `amount` | How much iAI to stake. Cap at `iAI.balanceOf(user)`. | `parseUnits(input, 18)` |

**Requires `iAI.approve(registryAddress, amount)` first** (§2). Earning starts in the same block.

### 6.2 Start withdrawing

```solidity
CreditRegistry.initiateUnstake(uint256 amount)
```

| Parameter | Where it comes from | Conversion / handling |
| --- | --- | --- |
| `amount` | How much to withdraw. Cap at `stakedOf(user)`. | `parseUnits(input, 18)` |

**Two contract behaviours that are easy to get wrong:**

1. **Earning stops immediately**, the moment this is called — not when the cooldown ends.
   `stakedOf` drops to the new value in the same transaction.
2. **Calling it a second time restarts the clock for the entire pending amount.** If 100 iAI is
   cooling down with 2 hours left and another 10 is initiated, `coolDownEnd` is reset to
   `now + cooldownDuration` for all 110. The new value is returned by `stakedInfoOf` and emitted in
   `UnstakeInitiated`.

### 6.3 Wait, then claim

```solidity
CreditRegistry.unstake()          // no parameters
```

Takes **no arguments** and withdraws everything whose cooldown has elapsed. Called before
`coolDownEnd` it reverts with `CooldownNotOver`; called with nothing pending, `NothingInCooldown`
(§9).

### 6.4 Reading staking state

```solidity
CreditRegistry.stakedOf(address account) view returns (uint256)
CreditRegistry.stakedInfoOf(address account) view returns (StakedInfo)   // ← a struct
CreditRegistry.cooldownDuration() view returns (uint256)
```

> **`stakedInfoOf` and `positionOf` come back in different shapes.** `positionOf` declares three
> separate outputs, so a client hands you an **array** — destructure it positionally.
> `stakedInfoOf` returns a single `struct`, so a client hands you an **object** keyed by field name.
> Mixing them up is a silent `undefined`, not an error.
>
> ```ts
> const [locked0G, iaiOutstanding, avgRate] = await vault.read.positionOf([user]);   // array
> const info = await registry.read.stakedInfoOf([user]);                             // object
> info.amountStaked; info.coolDownAmount; info.coolDownEnd;
> ```

| Field | Meaning | Display |
| --- | --- | --- |
| `amountStaked` | Currently earning. Same value as `stakedOf`. | 18 decimals |
| `coolDownAmount` | Withdrawing; **not** earning. | 18 decimals |
| `coolDownEnd` | Unix timestamp in **seconds** at which `unstake()` becomes callable. `0` if nothing is cooling down. | `new Date(Number(coolDownEnd) * 1000)` — multiply by 1000 for JavaScript |
| `cooldownDuration` | The delay, in **seconds**. Typically `86400` (1 day). | `Number(x) / 86400` for days |

```ts
const canUnstake =
  coolDownAmount > 0n && BigInt(Math.floor(Date.now() / 1000)) >= coolDownEnd;
```

---

## 7. Events

Every event carries the resulting state, so you can drive optimistic updates and a transaction
history from logs alone without follow-up reads. All amounts are 18-decimal.

```solidity
// IAIVault
event Minted(address indexed minter, uint256 iaiOut, uint256 locked0G, uint256 a0GIn,
             uint256 exchangeRate, uint256 supplyAfter, uint256 totalLocked0GAfter);

event Burned(address indexed minter, address indexed caller, uint256 iaiIn, uint256 unlocked0G,
             uint256 a0GOut, uint256 exchangeRate, uint256 supplyAfter, uint256 totalLocked0GAfter);

event Harvested(address indexed to, uint256 a0GSurplus, uint256 exchangeRate, uint256 totalLocked0G);

// CreditRegistry
event Staked(address indexed user, uint256 amount, uint256 amountStakedAfter, uint256 totalStakedAfter);

event UnstakeInitiated(address indexed user, uint256 amount, uint256 amountStakedAfter,
                       uint256 coolDownAmountAfter, uint256 coolDownEnd);

event Unstaked(address indexed user, uint256 amount, uint256 totalStakedAfter);
```

Filter a user's history on the `indexed` fields: `minter` for `Minted`, `minter` **or** `caller` for
`Burned`, `user` for the registry events. On `Burned`, `caller != minter` means an administrative
rescue (§8) rather than a normal redemption — label it differently.

---

## 8. Burning requires the caller to be the original minter

`burn` needs **both** conditions:

1. `msg.sender` must be the address that minted (has `iaiOutstanding > 0`), **and**
2. that address must currently hold the iAI tokens being burned.

iAI is freely transferable, so these can come apart:

| State | Reads | What it means |
| --- | --- | --- |
| Bought iAI on a market | `balanceOf > 0`, `iaiOutstanding == 0` | The tokens can be staked but there is nothing to redeem. Any `burn` reverts with `BurnExceedsPosition`. |
| Minted, then sent tokens away | `iaiOutstanding > 0`, `balanceOf < iaiOutstanding` | Redeemable only up to `balanceOf`. Acquiring the tokens again restores the rest. |
| Minted and still holding | both non-zero | The burnable maximum is `min(iaiOutstanding, balanceOf)`. |

If minted iAI reaches an address nobody controls, the collateral is stuck. There is an administrative
recovery path (`burnFor`) that always returns the collateral to the original minter and never to
whoever calls it; it is `RESCUE_ROLE`-gated and cannot be called from a normal wallet, so it is a
support process rather than something to integrate.

---

## 9. Error reference

Decode the first 4 bytes of the revert data. `viem`'s `decodeErrorResult` with the contract ABI does
this for you.

### Errors a normal user can hit

| Selector | Error | What happened | What to do |
| --- | --- | --- | --- |
| `0xce8c6762` | `ExcessiveInput(required, maxAccepted)` | The mint would cost more a0G than `maxA0GIn` allowed — someone minted first, or the rate moved. | Re-quote and retry. Offer to raise the slippage tolerance. `required` tells you the real price. |
| `0xaa2fd925` | `Expired(deadline, nowTs)` | The transaction sat past its deadline. | Retry with a fresh `deadline`. If it happens often, the deadline is too short or the gas price too low. |
| `0x509309dc` | `BurnExceedsPosition(requested, outstanding)` | Tried to burn — or to quote a burn — of more than this address minted. | Cap the input at `iaiOutstanding`. Usually means the user holds bought tokens (§8). `quoteBurn` raises the same error, so this surfaces while typing rather than on submit. |
| `0xe450d38c` | `ERC20InsufficientBalance(sender, balance, needed)` | A token balance was too low. **Which token depends on the call**: minting raises it from **a0G**, burning and staking from **iAI**. The vault does not wrap it — the collateral token's own error comes straight through. | Cap the input at the right `balanceOf`: `a0G` for minting, `iAI` for burning and staking. `needed` tells you the shortfall either way. |
| `0xfb8f41b2` | `ERC20InsufficientAllowance(spender, allowance, needed)` | Missing or too-small approval. `spender` says which one: the **vault** means the a0G approval for minting, the **registry** means the iAI approval for staking. | Run the approval flow (§2). Burn and unstake need none, so this error from either of those is an integration bug. |
| `0xfa07c026` | `CooldownNotOver(availableAt, nowTs)` | `unstake()` called before the cooldown elapsed. | `availableAt` is `coolDownEnd`, a Unix timestamp in seconds; it is also readable up front from `stakedInfoOf`. |
| `0x2aab8ce8` | `NothingInCooldown()` | `unstake()` with nothing pending. | The user must call `initiateUnstake` first. |
| `0x45be0a26` | `InsufficientStake(requested, staked)` | Withdrawing more than is staked. | Cap the input at `stakedOf`. |
| `0x1f2a2005` | `ZeroAmount()` | An amount of zero. | Validate before sending. |
| `0xf480e285` | `CapExceeded(supplyAfter, cap)` | The mint — or the quote for it — would exceed the total supply limit. | Cap the input at `cap() - totalSupply()`. `quoteMint` raises this too, so it surfaces while typing rather than on submit. |

### Errors that mean the system is closed, not the user

| Selector | Error | What happened | What to do |
| --- | --- | --- | --- |
| `0xd93c0665` | `EnforcedPause()` | Minting (or staking) is paused. **The system launches paused**, so expect this before go-live. | Not a user error, and not retryable. Check `IAIVault.paused()` up front to distinguish "not open yet" from a failure. **Burning is never pausable** — redemption works even while paused. |
| — | `"Oracle: stale value"` (a plain string, not a custom error) | The upstream a0G price feed has not been updated recently enough. Mint, burn and every quote revert. | An **external dependency**, not these contracts, and nothing a retry fixes quickly. Worth distinguishing from our own failures when reporting or alerting. |
| `0xe2517d3f` | `AccessControlUnauthorizedAccount(account, role)` | An admin-only function was called from a normal wallet. | An integration bug: `pause`, `setFoundation`, `burnFor` and the role functions are not callable from user wallets. |

---

## 10. Testnet (Galileo, chainId 16602)

The testnet uses a **mock a0G** with an open faucet — anyone can mint themselves collateral:

```solidity
MockA0G.mint(address to, uint256 amount)    // no permissions, any caller
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `to` | Any address, usually the connected wallet. | none |
| `amount` | However much you want. | `parseUnits("1000000", 18)` |

The mock address is `MockA0G` in `deployments/iai-16602.json` — the same value as `A0G` there.

Its exchange rate **rises automatically and much faster than production** — about 10% per day rather
than 15% per year — so the divergence between a0G tokens and 0G value shows up within a testing
session instead of taking months. Deliberate: it makes the behaviour in §0 ② observable while
integrating.

A file of pre-funded test accounts (address + private key, already holding gas and mock a0G) can be
requested from the contracts team. It is not in this repository.

---

## 11. Quick reference

```solidity
// ---- read (free, no wallet prompt) ----
IAIVault.quoteMint(uint256 d)                    -> (uint256 delta0G, uint256 a0GIn)   // reverts past the cap
IAIVault.quoteMintForA0G(uint256 a0GAmount)      -> (uint256 d)                        // clamps at the cap
IAIVault.quoteBurn(address minter, uint256 b)    -> (uint256 unlocked0G, uint256 a0GOut) // reverts past the position
IAIVault.positionOf(address account)             -> (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)  // ARRAY
IAIVault.exchangeRate()                          -> uint256          // 0G per a0G, 1e18-scaled
IAIVault.cap()                                   -> uint256
IAI.balanceOf(address) / totalSupply()           -> uint256
CreditRegistry.stakedOf(address)                 -> uint256
CreditRegistry.stakedInfoOf(address)             -> StakedInfo       // OBJECT: .amountStaked .coolDownAmount .coolDownEnd
CreditRegistry.cooldownDuration()                -> uint256          // seconds

// ---- write ----
a0G.approve(vaultAddress, a0GIn)                 // before mint only
IAIVault.mint(uint256 d, uint256 maxA0GIn, uint256 deadline)
IAIVault.burn(uint256 b, uint256 deadline)       // no approval, no slippage arg

IAI.approve(registryAddress, amount)             // before stake only
CreditRegistry.stake(uint256 amount)
CreditRegistry.initiateUnstake(uint256 amount)
CreditRegistry.unstake()                         // no arguments
```

Units, in one line: **every amount is an 18-decimal `bigint`; every timestamp is Unix seconds.**

Quotes, in one line: **they fail exactly where the action fails**, with the same error — except
`quoteMintForA0G`, which clamps because it was asked about a spend rather than an amount.
