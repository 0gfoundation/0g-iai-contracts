#!/usr/bin/env python3
"""Generate, check and export the ExponentialMintCurve price table.

The curve the vault charges is a step function: supply is cut into buckets of `BucketWidth`
iAI, and every bucket is priced flat at the value the smooth formula takes at the bucket's
**upper** bound:

    price_i = ceil_to_wei( Base * exp( Exponent * ((i + 1) * BucketWidth) / Target ) )

for i in 0 .. N-1. Pricing at the upper bound means the table never sits below the formula
anywhere in a bucket, and rounding each price up to the wei keeps that true after quantisation.
Both roundings favour the vault.

The table's length is where the supply ceiling comes from. The vault has no cap of its own: it
refuses any mint past the curve's `maxSafeSupply()`, and for this curve that is the table's top,
`N * BucketWidth`. N is derived from `Budget`, the total 0G the curve is allowed to absorb: it is
the smallest N for which the whole table -- the exact sum of `price_i * BucketWidth` over every
bucket, divided by 1e18 once and rounded up, exactly as the contract's `cost(0, top)` computes
it -- reaches `Budget`. So the top is the supply `Budget` 0G buys, rounded up to a whole bucket,
and a budget that could never be spent (twice 0G's total supply, in the shipped parameters) makes
the ceiling a real number that is never reached in practice.

`Budget` is a parameter of the *table*, not of the contract. The constructor takes the width,
the prices, `Base`, `Exponent` and `Target` and nothing else; it records the last three for
provenance and enforces only what the vault relies on (a positive, monotone table inside its
hard bound). The budget lives here and in the deployment record, where `--check` re-derives the
table -- length included -- from the five recorded parameters. Raising the ceiling is therefore
`genCurve --budget ...`, `deployCurve`, `setCurve`; there is no cap to move afterwards.

Encodings, all 18-decimal fixed point ("WAD"): `Base` is wei-0G per iAI, `Exponent` is the
dimensionless coefficient scaled by 1e18, `Target` (the supply the exponent is normalised
against) and `BucketWidth` are wei-iAI, `Budget` is wei-0G. Prices are wei-0G per iAI, stored
as decimal strings like every other integer in the record.

The contract holds only the table. Nothing on chain evaluates `exp`, so this script is the
single definition of how the table is derived. It is deliberately dependency-free (standard
library `decimal` at 60 significant digits) so anyone can rerun it and compare:

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json
        writes CurveParams.ExponentialMintCurve into the record (parameters from the flags,
        or from the block already in the record when no flag is given)

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json --check
        regenerates from the parameters in the record and fails if the stored Prices differ

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json \\
        --solidity test/unit/curves/ExponentialTable.sol
        also emits the table as a Solidity library, for tests that may not read files
"""

import argparse
import json
import sys
from decimal import ROUND_CEILING, Decimal, getcontext

WAD = 10**18
BLOCK = "ExponentialMintCurve"
# Everything the table is derived from. The first four are also the constructor's arguments;
# `Budget` fixes the table's length and goes no further than the record.
KEYS = {"base": "Base", "exponent": "Exponent", "target": "Target", "width": "BucketWidth", "budget": "Budget"}

# Every Decimal operation in this file, flag parsing included, runs at 60 significant digits.
getcontext().prec = 60

# The shipped constants: 586 0G at zero supply, e^4.711 = 111x at the normalising supply of
# 9,270 iAI, 25 iAI per bucket, and a table long enough to absorb 2,000,000,000 0G -- twice the
# total supply of 0G, so the ceiling exists without ever being reachable.
DEFAULTS = {"base": "586", "exponent": "4.711", "target": "9270", "width": "25", "budget": "2000000000"}


def price_table(base_wei: int, exponent_wad: int, target_wei: int, width_wei: int, budget_wei: int) -> list[int]:
    """The whole derivation. Everything else in this file is plumbing.

    Buckets are appended until the table's total -- computed the way the contract computes
    `cost(0, top)`: the exact sum of `price * width`, divided by WAD once, rounded up -- reaches
    the budget. The loop always terminates because every price is at least one wei."""
    base = Decimal(base_wei)
    k = Decimal(exponent_wad) / WAD
    target = Decimal(target_wei)
    prices = []
    exact_sum = 0  # sum of price_i * width_i, in wei-0G times WAD; exact integer arithmetic
    while -(-exact_sum // WAD) < budget_wei:  # ceil(exact_sum / WAD) < budget
        upper = Decimal((len(prices) + 1) * width_wei)
        price = int((base * (k * upper / target).exp()).to_integral_value(rounding=ROUND_CEILING))
        prices.append(price)
        exact_sum += price * width_wei
    return prices


def table_total(prices: list[int], width_wei: int) -> int:
    """`cost(0, top)` as the contract computes it: one ceiling over the exact sum."""
    exact_sum = sum(p * width_wei for p in prices)
    return -(-exact_sum // WAD)


def to_wad(text: str) -> int:
    """'586.5' -> 586500000000000000000, exactly."""
    value = Decimal(text) * WAD
    if value != value.to_integral_value():
        sys.exit(f"{text} has more than 18 decimals")
    return int(value)


def load(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def save(path: str, record: dict) -> None:
    # Forge rewrites the record with sorted keys and two-space indentation; match it so a
    # later `run.sh` pass does not reformat what this script wrote.
    with open(path, "w") as f:
        json.dump(record, f, indent=2, sort_keys=True)
        f.write("\n")


def parameters(record: dict, args: argparse.Namespace) -> dict:
    """Flags win; otherwise the block already in the record; otherwise the shipped defaults."""
    block = record.get("CurveParams", {}).get(BLOCK, {})
    out = {}
    for flag, key in KEYS.items():
        given = getattr(args, flag)
        if given is not None:
            out[key] = to_wad(given)
        elif key in block:
            out[key] = int(block[key])
        else:
            out[key] = to_wad(DEFAULTS[flag])
    return out


def recorded_parameters(record: dict, path: str) -> dict:
    """For --check: every parameter must come from the block itself. A default or a flag standing
    in for a missing key would let the check agree with something the record does not say."""
    block = record.get("CurveParams", {}).get(BLOCK, {})
    missing = [key for key in KEYS.values() if key not in block]
    if missing:
        sys.exit(f"{path}: {BLOCK} block lacks {', '.join(missing)}; run without --check to regenerate it")
    return {key: int(block[key]) for key in KEYS.values()}


def solidity_library(prices: list[int], params: dict, record_path: str) -> str:
    packed = b"".join(p.to_bytes(16, "big") for p in prices)
    chunks = [packed[i : i + 64].hex() for i in range(0, len(packed), 64)]
    body = "\n".join(f'        hex"{c}"' for c in chunks)
    return f"""// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title ExponentialTable
 * @notice The production ExponentialMintCurve table, as compile-time data.
 *
 * @dev GENERATED -- do not edit. Regenerate with
 *
 *      python3 script/curve/gen_exponential_table.py {record_path} \\
 *          --solidity test/unit/curves/ExponentialTable.sol
 *
 *      Unit tests may not read files, so the table the deployment record carries is mirrored
 *      here; `test/script/Deploy.t.sol` asserts the two are identical, which is what keeps
 *      this copy honest. Each price is 16 bytes, big-endian, in bucket order. `BUDGET` is the
 *      0G the table was sized to absorb; it is not a constructor argument.
 */
library ExponentialTable {{
    uint256 internal constant BUCKET_WIDTH = {params['BucketWidth']};
    uint256 internal constant BASE = {params['Base']};
    uint256 internal constant EXPONENT = {params['Exponent']};
    uint256 internal constant TARGET = {params['Target']};
    uint256 internal constant BUDGET = {params['Budget']};

    bytes internal constant PACKED =
{body};

    function prices() internal pure returns (uint128[] memory p) {{
        bytes memory packed = PACKED;
        p = new uint128[](packed.length / 16);
        for (uint256 i = 0; i < p.length; i++) {{
            uint256 word;
            // solhint-disable-next-line no-inline-assembly
            assembly {{
                word := mload(add(add(packed, 32), mul(i, 16)))
            }}
            p[i] = uint128(word >> 128);
        }}
    }}
}}
"""


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("record", help="deployments/iai-<chainId>.json")
    ap.add_argument("--base", help="0G per iAI at zero supply, e.g. 586")
    ap.add_argument("--exponent", help="exponent coefficient, e.g. 4.711")
    ap.add_argument("--target", help="supply the exponent is normalised against, in iAI, e.g. 9270")
    ap.add_argument("--width", help="bucket width in iAI, e.g. 25")
    ap.add_argument("--budget", help="0G the table must absorb before it ends, e.g. 2000000000")
    ap.add_argument("--check", action="store_true", help="verify the stored table instead of writing it")
    ap.add_argument(
        "--require",
        action="store_true",
        help="with --check: the record must carry the block (the kind is about to be deployed)",
    )
    ap.add_argument("--solidity", metavar="PATH", help="also write the table as a Solidity library")
    args = ap.parse_args()

    record = load(args.record)
    kind_is_exponential = record.get("MintCurveKind") == BLOCK

    if args.check:
        if any(getattr(args, flag) is not None for flag in KEYS):
            sys.exit("--check verifies the record against itself; parameter flags are not accepted with it")
        if BLOCK not in record.get("CurveParams", {}):
            if args.require or kind_is_exponential:
                sys.exit(f"{args.record}: no {BLOCK} block -- run genCurve first")
            print(f"{args.record}: no {BLOCK} block, nothing to check")
            if args.solidity:
                sys.exit(f"cannot write {args.solidity}: the record carries no table to export")
            return
        params = recorded_parameters(record, args.record)
    else:
        params = parameters(record, args)
    for key, value in params.items():
        if value <= 0:
            sys.exit(f"{key} must be positive")

    prices = price_table(
        params["Base"], params["Exponent"], params["Target"], params["BucketWidth"], params["Budget"]
    )
    top = len(prices) * params["BucketWidth"]
    total = table_total(prices, params["BucketWidth"])
    if params["Target"] > top:
        # The constructor rejects this (`TargetBeyondTable`): a table that ends below the
        # supply its own exponent is normalised against cannot be the one derived for it.
        sys.exit(f"{args.record}: the budget ends the table at {top} wei-iAI, below Target {params['Target']}")

    if args.check:
        stored = [int(p) for p in record["CurveParams"][BLOCK].get("Prices", [])]
        if stored != prices:
            first = next((i for i, (a, b) in enumerate(zip(stored, prices)) if a != b), min(len(stored), len(prices)))
            sys.exit(
                f"{args.record}: stored Prices do not match the parameters beside them "
                f"(first difference at bucket {first}; stored {len(stored)} entries, derived {len(prices)}). "
                f"Run without --check to regenerate."
            )
        print(f"{args.record}: {len(prices)} prices match their parameters (top {top}, total {total} wei-0G)")
    else:
        record.setdefault("CurveParams", {})[BLOCK] = {
            "Base": str(params["Base"]),
            "BucketWidth": str(params["BucketWidth"]),
            "Budget": str(params["Budget"]),
            "Exponent": str(params["Exponent"]),
            "Prices": [str(p) for p in prices],
            "Target": str(params["Target"]),
        }
        save(args.record, record)
        print(
            f"{args.record}: wrote {len(prices)} prices, width {params['BucketWidth']}, top {top}, "
            f"total {total} wei-0G for a budget of {params['Budget']}, first {prices[0]}, last {prices[-1]}"
        )

    if args.solidity:
        with open(args.solidity, "w") as f:
            f.write(solidity_library(prices, params, args.record))
        print(f"{args.solidity}: written")


if __name__ == "__main__":
    main()
