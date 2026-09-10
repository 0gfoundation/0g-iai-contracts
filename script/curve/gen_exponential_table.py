#!/usr/bin/env python3
"""Generate, check and export the ExponentialMintCurve price table.

The curve the vault charges is a step function: supply is cut into buckets of `BucketWidth`
iAI, and every bucket is priced flat at the value the smooth formula takes at the bucket's
**upper** bound:

    price_i = ceil_to_wei( Base * exp( Exponent * ( ((i + 1) * BucketWidth) / Target )^3 ) )

for i in 0 .. N-1, with N = ceil(Target / BucketWidth), so the table's top (N * BucketWidth)
reaches the target and overshoots it by less than one bucket. Pricing at the upper bound means
the table never sits below the formula anywhere in a bucket, and rounding each price up to the
wei keeps that true after quantisation. Both roundings favour the vault.

The curve's parameters and the vault's are two separate sets. Nothing here reads the vault's
`Cap`: the cap is a policy number that governance moves, the table is the curve. The vault alone
checks, at `setCurve` and `setCap`, that the cap fits under the curve's `maxSafeSupply()`, which
for this curve is the table's top -- so raising the target past the cap's reach is
`genCurve --target ...`, `deployCurve`, `setCurve`, and only then `setCap`.

Encodings, all 18-decimal fixed point ("WAD"): `Base` is wei-0G per iAI, `Exponent` is the
dimensionless coefficient scaled by 1e18, `Target` and `BucketWidth` are wei-iAI. The cubic
power is part of the formula, not a parameter. Prices are wei-0G per iAI, stored as decimal
strings like every other integer in the record.

The contract holds only the table. Nothing on chain evaluates `exp`, so this script is the
single definition of how the table is derived. It is deliberately dependency-free (standard
library `decimal` at 60 significant digits) so anyone can rerun it and compare:

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json
        writes CurveParams.ExponentialMintCurve into the record (parameters from the flags,
        or from the block already in the record when no flag is given)

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json --check
        regenerates from the parameters in the record and fails if the stored Prices differ

    python3 script/curve/gen_exponential_table.py deployments/iai-<chainId>.json \
        --solidity test/unit/curves/ExponentialTable.sol
        also emits the table as a Solidity library, for tests that may not read files
"""

import argparse
import json
import sys
from decimal import ROUND_CEILING, Decimal, getcontext

WAD = 10**18
BLOCK = "ExponentialMintCurve"

# The proposal's constants: 3,237.4 0G at zero supply, e^3.419 = 30.5x at the target of
# 9,270 iAI, 25 iAI per bucket.
DEFAULTS = {"base": "3237.4", "exponent": "3.419", "target": "9270", "width": "25"}


def price_table(base_wei: int, exponent_wad: int, target_wei: int, width_wei: int) -> list[int]:
    """The whole derivation. Everything else in this file is plumbing."""
    getcontext().prec = 60
    base = Decimal(base_wei)
    k = Decimal(exponent_wad) / WAD
    target = Decimal(target_wei)
    count = -(-target_wei // width_wei)  # ceil(target / width)
    prices = []
    for i in range(count):
        upper = Decimal((i + 1) * width_wei)
        price = base * (k * (upper / target) ** 3).exp()
        prices.append(int(price.to_integral_value(rounding=ROUND_CEILING)))
    return prices


def to_wad(text: str) -> int:
    """'3237.4' -> 3237400000000000000000, exactly."""
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
    """Flags win; otherwise the block already in the record; otherwise the proposal's defaults."""
    block = record.get("CurveParams", {}).get(BLOCK, {})
    keys = {"base": "Base", "exponent": "Exponent", "target": "Target", "width": "BucketWidth"}
    out = {}
    for flag, key in keys.items():
        given = getattr(args, flag)
        if given is not None:
            out[key] = to_wad(given)
        elif key in block:
            out[key] = int(block[key])
        else:
            out[key] = to_wad(DEFAULTS[flag])
    return out


def solidity_library(prices: list[int], params: dict) -> str:
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
 *      python3 script/curve/gen_exponential_table.py deployments/iai-example.json \\
 *          --solidity test/unit/curves/ExponentialTable.sol
 *
 *      Unit tests may not read files, so the table the deployment record carries is mirrored
 *      here; `test/script/Deploy.t.sol` asserts the two are identical, which is what keeps
 *      this copy honest. Each price is 16 bytes, big-endian, in bucket order.
 */
library ExponentialTable {{
    uint256 internal constant BUCKET_WIDTH = {params['BucketWidth']};
    uint256 internal constant BASE = {params['Base']};
    uint256 internal constant EXPONENT = {params['Exponent']};
    uint256 internal constant TARGET = {params['Target']};
    uint256 internal constant COUNT = {len(prices)};

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
    ap.add_argument("--base", help="0G per iAI at zero supply, e.g. 3237.4")
    ap.add_argument("--exponent", help="exponent coefficient, e.g. 3.419")
    ap.add_argument("--target", help="supply the exponent is normalised against, in iAI, e.g. 9270")
    ap.add_argument("--width", help="bucket width in iAI, e.g. 25")
    ap.add_argument("--check", action="store_true", help="verify the stored table instead of writing it")
    ap.add_argument("--solidity", metavar="PATH", help="also write the table as a Solidity library")
    args = ap.parse_args()

    record = load(args.record)
    params = parameters(record, args)
    for key, value in params.items():
        if value <= 0:
            sys.exit(f"{key} must be positive")

    prices = price_table(params["Base"], params["Exponent"], params["Target"], params["BucketWidth"])
    top = len(prices) * params["BucketWidth"]

    if args.check:
        block = record.get("CurveParams", {}).get(BLOCK)
        if block is None:
            print(f"{args.record}: no {BLOCK} block, nothing to check")
            return
        stored = [int(p) for p in block.get("Prices", [])]
        if stored != prices:
            first = next((i for i, (a, b) in enumerate(zip(stored, prices)) if a != b), min(len(stored), len(prices)))
            sys.exit(
                f"{args.record}: stored Prices do not match the parameters beside them "
                f"(first difference at bucket {first}; stored {len(stored)} entries, derived {len(prices)}). "
                f"Run without --check to regenerate."
            )
        print(f"{args.record}: {len(prices)} prices match their parameters (top {top})")
    else:
        record.setdefault("CurveParams", {})[BLOCK] = {
            "Base": str(params["Base"]),
            "BucketWidth": str(params["BucketWidth"]),
            "Exponent": str(params["Exponent"]),
            "Prices": [str(p) for p in prices],
            "Target": str(params["Target"]),
        }
        save(args.record, record)
        print(
            f"{args.record}: wrote {len(prices)} prices, width {params['BucketWidth']}, top {top}, "
            f"first {prices[0]}, last {prices[-1]}"
        )

    if args.solidity:
        with open(args.solidity, "w") as f:
            f.write(solidity_library(prices, params))
        print(f"{args.solidity}: written")


if __name__ == "__main__":
    main()
