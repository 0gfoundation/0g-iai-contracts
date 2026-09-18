# Accepted risks

Decisions, not oversights. They are recorded here so nobody has to rediscover them, and so a future
change that quietly "fixes" one gets discussed rather than merged. `CLAUDE.md` carries the index;
this file carries the reasoning, and an entry is not settled until it is written down here.

**Numbering is append-only.** An entry keeps its number for good: these are cited from outside the
repository -- security reviews quote them, and our replies quote them back -- so nothing is
renumbered and no number is reused. An entry that stops being true stays where it is, marked
withdrawn, with a line saying what replaced it. Amend an entry in place when the system moves under
it; that is what R2, R3, R4, R5 and R7 have already had.

**R1 — the a0G oracle's write key can drain the vault.** Upstream `setValue` has no bounds, no
monotonicity requirement, no rate limit and no timelock. Set the rate absurdly high, mint to the
ceiling for dust, restore it, redeem: the collateral is gone. iAI does not defend against this, because the
root cause is the combination of yield-bearing collateral and recording curve value rather than
deposited tokens — both deliberate. **Operational requirement:** monitor the oracle's `ValueSet`
events and, on any move outside the expected daily band, `pause()` **and** revoke
`PAUSE_EXEMPT_MINTER_ROLE` if anyone holds it (R10) — the second is part of the response, not a
follow-up to it. `pause()` stops minting but not redemption, so the window between alert and human
response is the exposure. Note the ceiling is not a bound on this: it is the curve's, and a swap
raises it, so "mint to the ceiling" is not a fixed quantity of damage.

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
`test_Change_ReissuingTheSameShareRatchetsTowardTheFoundation` pins the direction and the size, so
it is a known quantity rather than something to be discovered.

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
