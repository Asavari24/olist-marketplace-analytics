"""Fetch the nine Olist CSVs.

The canonical home of this dataset is Kaggle (olistbr/brazilian-ecommerce),
which requires an API token. To keep `reproduce.sh` runnable without
credentials the default source is a public mirror of the same release; the
expected byte sizes below are the canonical ones, so a mirror that has been
altered fails the check rather than quietly producing different numbers.

Run directly:  python -m olist.download [--force]
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

from . import RAW_DIR

MIRROR = "https://huggingface.co/datasets/bulutttt/olist-raw-data/resolve/main"

# filename -> exact byte size in the canonical Kaggle release.
FILES: dict[str, int] = {
    "olist_customers_dataset.csv": 9_033_957,
    "olist_geolocation_dataset.csv": 61_273_883,
    "olist_order_items_dataset.csv": 15_438_671,
    "olist_order_payments_dataset.csv": 5_777_138,
    "olist_order_reviews_dataset.csv": 14_451_670,
    "olist_orders_dataset.csv": 17_654_914,
    "olist_products_dataset.csv": 2_379_446,
    "olist_sellers_dataset.csv": 174_703,
    "product_category_name_translation.csv": 2_613,
}

# Row counts after correct CSV parsing. The reviews file is the one that
# matters: it contains embedded newlines inside quoted comment text, so
# `wc -l` reports 104,719 where the true row count is 99,224. Anything that
# counts lines instead of parsing will silently disagree with the warehouse.
EXPECTED_ROWS: dict[str, int] = {
    "olist_customers_dataset.csv": 99_441,
    "olist_geolocation_dataset.csv": 1_000_163,
    "olist_order_items_dataset.csv": 112_650,
    "olist_order_payments_dataset.csv": 103_886,
    "olist_order_reviews_dataset.csv": 99_224,
    "olist_orders_dataset.csv": 99_441,
    "olist_products_dataset.csv": 32_951,
    "olist_sellers_dataset.csv": 3_095,
    "product_category_name_translation.csv": 71,
}


def download(dest: Path = RAW_DIR, force: bool = False) -> list[str]:
    """Download any missing or wrong-sized file. Returns what was fetched."""
    dest.mkdir(parents=True, exist_ok=True)
    fetched = []

    for name, expected_bytes in FILES.items():
        target = dest / name
        if target.exists() and not force:
            actual = target.stat().st_size
            if actual == expected_bytes:
                print(f"  ok       {name} ({actual:,} bytes)")
                continue
            print(f"  resize   {name}: have {actual:,}, want {expected_bytes:,}")

        url = f"{MIRROR}/{name}"
        print(f"  fetching {name} ...", end="", flush=True)
        urllib.request.urlretrieve(url, target)
        actual = target.stat().st_size
        print(f" {actual:,} bytes")

        if actual != expected_bytes:
            raise RuntimeError(
                f"{name}: downloaded {actual:,} bytes, canonical release is "
                f"{expected_bytes:,}. The mirror at {MIRROR} does not match "
                f"the Kaggle original -- refusing to build a warehouse on it."
            )
        fetched.append(name)

    return fetched


def verify_rows(dest: Path = RAW_DIR) -> dict[str, tuple[int, int]]:
    """Parse each CSV and compare its true row count to the canonical one."""
    import duckdb

    con = duckdb.connect()
    mismatches = {}
    for name, expected in EXPECTED_ROWS.items():
        path = dest / name
        actual = con.execute(
            "select count(*) from read_csv_auto(?, all_varchar=true, header=true)",
            [str(path)],
        ).fetchone()[0]
        status = "ok" if actual == expected else "MISMATCH"
        print(f"  {status:8s} {name}: {actual:,} rows (expected {expected:,})")
        if actual != expected:
            mismatches[name] = (actual, expected)
    con.close()
    return mismatches


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path, default=RAW_DIR)
    parser.add_argument("--force", action="store_true", help="re-download everything")
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args()

    print(f"Olist source CSVs -> {args.dest}")
    download(args.dest, force=args.force)

    if not args.skip_verify:
        print("\nVerifying parsed row counts against the canonical release:")
        mismatches = verify_rows(args.dest)
        if mismatches:
            print("\nRow counts do not match the canonical release:", file=sys.stderr)
            for name, (actual, expected) in mismatches.items():
                print(f"  {name}: {actual:,} != {expected:,}", file=sys.stderr)
            return 1

    print("\nAll nine files present and matching the canonical release.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
