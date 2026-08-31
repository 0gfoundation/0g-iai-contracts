# iAI — Frontend Integration Guide

Everything a frontend needs to call these contracts, organised by **what the user is trying to do**
rather than by contract. You do not need to understand the protocol to use this document; every
parameter says where its value comes from and what, if anything, you must do to it first.

---

## 0. Read this first: the two things that trip people up

**① All amounts are integers with 18 decimals.** iAI, a0G and 0G all use 18. There are no
exceptions in this system and no token here uses 6 or 8. A user typing `1.5` means `1500000000000000000`.

```ts
import { parseUnits, formatUnits } from "viem";
const onChain  = parseUnits(userTyped, 18);   // "1.5"  -> 1500000000000000000n
const display  = formatUnits(onChain, 18);    // 1500000000000000000n -> "1.5"
```

Never build these by hand and never use JavaScript `number` for them — they exceed `Number.MAX_SAFE_INTEGER`.
Use `bigint` end to end.

**② Denominate the UI in 0G value, not in a0G token count.** a0G is a *yield-bearing* token: its
balance never grows, its **exchange rate** does. So a user who locks a0G and later redeems gets back
**fewer a0G tokens** than they put in, while the 0G value is exactly what they locked. A real
measurement from a test deployment:

| | |
| --- | --- |
| Locked | **4,330.885 a0G** — worth 4,331.0108 0G |
| Redeemed later | **3,922.223 a0G** — worth 4,331.0108 0G |
| Difference | 408.66 a0G, which is the yield the protocol harvested |

If the UI shows a0G counts as the headline, every user will believe they lost 9% of their money.
Show 0G value as the headline and a0G as secondary. There is a copy template in §7.

---

## 1. Addresses, ABIs and networks

### Where the addresses come from

One file per network, in this repository: **`deployments/iai-<chainId>.json`**.

| Network | chainId | RPC | Explorer | File |
| --- | --- | --- | --- | --- |
| 0G mainnet | `16661` | `https://evmrpc.0g.ai` | `https://chainscan.0g.ai` | `deployments/iai-16661.json` |
| 0G Galileo testnet | `16602` | `https://evmrpc-testnet.0g.ai` | `https://chainscan-galileo.0g.ai` | `deployments/iai-16602.json` |

Each file has three entries per contract. **Always use the bare name.**

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
| **Burn iAI** | `IAIVault.burn` | ❌ **No** | The vault holds a role that lets it burn directly. Asking for an approval here will confuse users and the transaction would work without it anyway. |
| **Stake iAI** | `CreditRegistry.stake` | ✅ **Yes** — `iAI.approve(registryAddress, amount)` | The registry is a separate contract and pulls the tokens. |
| **Unstake iAI** | `CreditRegistry.initiateUnstake` / `unstake` | ❌ **No** | The tokens are already inside the registry. |

**a0G has no `permit`.** It is an ERC-4626 vault share that does not implement EIP-2612, so there is
no gasless one-click signature path. Minting is always two transactions: `approve`, then `mint`.
Budget for that in the UI.

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

### 3.1 Show the price

```solidity
IAIVault.quoteMint(uint256 d) view returns (uint256 delta0G, uint256 a0GIn)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `d` | The amount of iAI the user wants, from your input box. | `parseUnits(input, 18)` |

| Return | Meaning | Display |
| --- | --- | --- |
| `delta0G` | The **0G value** this mint locks. This is the headline number. | `formatUnits(delta0G, 18)` + " 0G" |
| `a0GIn` | The **a0G tokens** that will actually leave the wallet. | `formatUnits(a0GIn, 18)` + " a0G" |

This is a `view` call — free, no gas, no wallet prompt. Re-run it whenever the input changes and
again right before submitting, because the price rises as other people mint.

**The reverse direction.** If your UI has a "spend all my a0G" button:

```solidity
IAIVault.quoteMintForA0G(uint256 a0GAmount) view returns (uint256 d)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `a0GAmount` | `a0G.balanceOf(userAddress)`, or a smaller amount the user typed. | Already 18-decimal wei if read from `balanceOf`; `parseUnits(input, 18)` if typed. |

It returns the `d` you then pass to `quoteMint` and `mint`. It rounds down, so the resulting mint
never costs more than `a0GAmount`.

### 3.2 Send the transaction

```solidity
IAIVault.mint(uint256 d, uint256 maxA0GIn, uint256 deadline)
```

| Parameter | Where it comes from | Conversion / handling |
| --- | --- | --- |
| `d` | The same `d` you passed to `quoteMint`. | Already wei. Pass it unchanged — do not re-derive it. |
| `maxA0GIn` | `a0GIn` from `quoteMint`, **widened by a slippage tolerance**. | `a0GIn * (10000n + toleranceBps) / 10000n`. See below. |
| `deadline` | Current time plus how long the user will wait. | **Unix seconds, not milliseconds.** `BigInt(Math.floor(Date.now()/1000) + 600)` for 10 minutes. `Date.now()` alone is 1000× too large and will never expire. |

**About `maxA0GIn`.** It is the only slippage bound, and it protects against everything at once: the
price rising because someone minted first, and the a0G exchange rate moving between your quote and
the transaction landing. Suggested default **0.5% (`50` bps)**; let the user change it. Too tight and
the transaction reverts on a busy block; too loose and a user can overpay. It caps what leaves the
wallet, so it is safe to reason about directly: *"you will spend at most X a0G."*

```ts
const TOLERANCE_BPS = 50n;                                   // 0.5%
const [delta0G, a0GIn] = await vault.read.quoteMint([d]);
const maxA0GIn = (a0GIn * (10_000n + TOLERANCE_BPS)) / 10_000n;
const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);

await vault.write.mint([d, maxA0GIn, deadline]);
```

### 3.3 Confirm

On success the transaction emits `Minted` (§8). The user's `iAI.balanceOf` increases by exactly `d` —
minting gives the precise amount asked for; it is the *cost* that varies, never the output.

---

## 4. Showing a position

```solidity
IAIVault.positionOf(address account)
  view returns (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `account` | The connected wallet address. | none |

| Return | Meaning | Display |
| --- | --- | --- |
| `locked0G` | 0G value this user has locked. **The headline.** | `formatUnits(locked0G, 18)` + " 0G" |
| `iaiOutstanding` | iAI they minted and have not yet redeemed. This is the maximum they can burn. | `formatUnits(..., 18)` + " iAI" |
| `avgRate` | Their average price, in 0G per iAI. Zero when the position is empty. | `formatUnits(avgRate, 18)` + " 0G/iAI" |

**`iaiOutstanding` is not the same as `iAI.balanceOf(user)`.** iAI is freely transferable, so a user
can hold tokens they did not mint (they cannot burn those) or have sent away tokens they did mint
(the position stays, but they need the tokens back to redeem). Show both, and see §9.

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

### 5.1 Show what they get back

```solidity
IAIVault.quoteBurn(address minter, uint256 b) view returns (uint256 unlocked0G, uint256 a0GOut)
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `minter` | The connected wallet address. | none |
| `b` | How much iAI to burn. Cap the input at `min(iaiOutstanding, iAI.balanceOf(user))`. | `parseUnits(input, 18)` |

| Return | Meaning |
| --- | --- |
| `unlocked0G` | The 0G value released. **This equals what they locked for that slice** — headline it. |
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

### 5.3 What to tell the user

Always show both units on the confirmation screen, with 0G first. See §7 for wording.

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

**Two behaviours the UI must communicate, or users will be angry:**

1. **Earning stops immediately**, the moment this is called — not when the cooldown ends.
2. **Calling it a second time restarts the clock for the entire pending amount.** If a user has
   100 iAI cooling down with 2 hours left and initiates another 10, all 110 wait the full cooldown
   again. Warn before the second call, and show the new end time.

### 6.3 Wait, then claim

```solidity
CreditRegistry.unstake()          // no parameters
```

Takes **no arguments** and withdraws everything whose cooldown has elapsed. Disable the button until
then; calling early reverts with `CooldownNotOver` (§10).

### 6.4 Reading staking state

```solidity
CreditRegistry.stakedOf(address account) view returns (uint256)
CreditRegistry.stakedInfoOf(address account)
  view returns (uint256 amountStaked, uint256 coolDownAmount, uint256 coolDownEnd)
CreditRegistry.cooldownDuration() view returns (uint256)
```

| Field | Meaning | Display |
| --- | --- | --- |
| `amountStaked` | Currently earning. Same value as `stakedOf`. | 18 decimals |
| `coolDownAmount` | Withdrawing; **not** earning. | 18 decimals |
| `coolDownEnd` | Unix timestamp in **seconds** when `unstake()` becomes available. `0` if nothing is cooling down. | `new Date(Number(coolDownEnd) * 1000)` — multiply by 1000 for JavaScript |
| `cooldownDuration` | The delay, in **seconds**. Typically `86400` (1 day). | `Number(x) / 86400` for days |

```ts
const canUnstake =
  coolDownAmount > 0n && BigInt(Math.floor(Date.now() / 1000)) >= coolDownEnd;
```

---

## 7. Copy that must appear in the UI

This is a product requirement, not a style suggestion. Because a0G appreciates, the a0G number always
goes down and users read that as a loss.

**On the redemption preview:**

> You will receive **3,922.223 a0G**
> ≈ **4,331.01 0G** — exactly the 0G value you locked. Your principal is intact.
> a0G has appreciated since you deposited, so the same value is now fewer tokens.

**On the mint preview:**

> You will lock **4,331.01 0G** of value
> costing **4,330.885 a0G** at today's rate
> You will receive **1.0 iAI**

**On the staking screen:** state that unstaking takes `cooldownDuration` and that earning stops the
moment withdrawal is initiated.

**Anywhere a user might expect yield:** locked collateral earns the user nothing. The yield goes to
the protocol. Say so once, plainly, before they deposit.

---

## 8. Events

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
rescue (§9) rather than a normal redemption — label it differently.

---

## 9. Burning requires the caller to be the original minter

`burn` needs **both** conditions:

1. `msg.sender` must be the address that minted (has `iaiOutstanding > 0`), **and**
2. that address must currently hold the iAI tokens being burned.

iAI is freely transferable, so these can come apart:

| Situation | What the user sees | What the UI should do |
| --- | --- | --- |
| Bought iAI on a market | `balanceOf > 0`, `iaiOutstanding == 0` | The tokens are usable for staking. There is nothing to redeem — say so instead of showing a disabled Burn button with no explanation. |
| Minted, then sent tokens away | `iaiOutstanding > 0`, `balanceOf < iaiOutstanding` | Show "you need N more iAI in this wallet to redeem the rest". Getting the tokens back restores the ability. |
| Minted and still holding | both non-zero | Normal. Cap the burn input at `min(iaiOutstanding, balanceOf)`. |

If a user sends minted iAI to an address they do not control, the collateral is stuck. There is an
administrative recovery path (`burnFor`) that always returns the collateral to the original minter,
never to whoever calls it. It is a support process, not a UI feature — do not surface a button;
route the user to support.

---

## 10. Error reference

Decode the first 4 bytes of the revert data. `viem`'s `decodeErrorResult` with the contract ABI does
this for you.

### Errors a normal user can hit

| Selector | Error | What happened | What to do |
| --- | --- | --- | --- |
| `0xce8c6762` | `ExcessiveInput(required, maxAccepted)` | The mint would cost more a0G than `maxA0GIn` allowed — someone minted first, or the rate moved. | Re-quote and retry. Offer to raise the slippage tolerance. `required` tells you the real price. |
| `0xaa2fd925` | `Expired(deadline, nowTs)` | The transaction sat past its deadline. | Retry with a fresh `deadline`. If it happens often, the deadline is too short or the gas price too low. |
| `0x509309dc` | `BurnExceedsPosition(requested, outstanding)` | Tried to burn more than this address minted. | Cap the input at `iaiOutstanding`. Usually means the user holds bought tokens (§9). |
| `0xe450d38c` | `ERC20InsufficientBalance` | Not enough iAI in the wallet to burn or stake. | Cap the input at `balanceOf`. |
| `0xfb8f41b2` | `ERC20InsufficientAllowance` | Missing or too-small approval. | Run the approval flow (§2). Remember: burn and unstake need none. |
| `0xfa07c026` | `CooldownNotOver(availableAt, nowTs)` | `unstake()` called before the cooldown elapsed. | Disable the button until `coolDownEnd`. `availableAt` is the timestamp in seconds. |
| `0x2aab8ce8` | `NothingInCooldown()` | `unstake()` with nothing pending. | The user must call `initiateUnstake` first. |
| `0x45be0a26` | `InsufficientStake(requested, staked)` | Withdrawing more than is staked. | Cap the input at `stakedOf`. |
| `0x1f2a2005` | `ZeroAmount()` | An amount of zero. | Validate before sending. |
| `0xf480e285` | `CapExceeded(supplyAfter, cap)` | The mint would exceed the total supply limit. | Show remaining headroom: `cap() - totalSupply()`. |

### Errors that mean the system is closed, not the user

| Selector | Error | What happened | What to do |
| --- | --- | --- | --- |
| `0xd93c0665` | `EnforcedPause()` | Minting (or staking) is paused. **The system launches paused**, so expect this before go-live. | Show "minting is not open yet" — this is not a user error. Note that **burning is never paused**; redemption always works. |
| — | `"Oracle: stale value"` (a plain string, not a custom error) | The upstream a0G price feed has not been updated recently enough. Mint, burn and quotes all revert. | This is an **external dependency**, not our contracts. Say "the a0G price feed is unavailable, please try again later" and alert your ops channel. Distinguish it from our own failures. |
| `0xe2517d3f` | `AccessControlUnauthorizedAccount(account, role)` | An admin-only function was called from a normal wallet. | Should never reach a user. It means the frontend is calling something it should not. |

---

## 11. Testnet (Galileo, chainId 16602)

The testnet uses a **mock a0G** with an open faucet — anyone can mint themselves collateral:

```solidity
MockA0G.mint(address to, uint256 amount)    // no permissions, any caller
```

| Parameter | Where it comes from | Conversion |
| --- | --- | --- |
| `to` | Any address, usually the connected wallet. | none |
| `amount` | However much you want. | `parseUnits("1000000", 18)` |

The mock address is `MockA0G` in `deployments/iai-16602.json` — the same value as `A0G` there.

Its exchange rate **rises automatically and much faster than production** (about 10% per day rather
than 15% per year), so the "you get fewer a0G back" effect is visible within a testing session
instead of taking months. That is deliberate: the effect is the thing most likely to be mis-designed,
so it is made obvious on testnet.

A file of pre-funded test accounts (address + private key, already holding gas and mock a0G) can be
requested from the contracts team. It is not in this repository.

---

## 12. Quick reference

```solidity
// ---- read (free, no wallet prompt) ----
IAIVault.quoteMint(uint256 d)                    -> (uint256 delta0G, uint256 a0GIn)
IAIVault.quoteMintForA0G(uint256 a0GAmount)      -> (uint256 d)
IAIVault.quoteBurn(address minter, uint256 b)    -> (uint256 unlocked0G, uint256 a0GOut)
IAIVault.positionOf(address account)             -> (uint256 locked0G, uint256 iaiOutstanding, uint256 avgRate)
IAIVault.exchangeRate()                          -> uint256          // 0G per a0G, 1e18-scaled
IAIVault.cap()                                   -> uint256
IAI.balanceOf(address) / totalSupply()           -> uint256
CreditRegistry.stakedOf(address)                 -> uint256
CreditRegistry.stakedInfoOf(address)             -> (uint256 amountStaked, uint256 coolDownAmount, uint256 coolDownEnd)
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
