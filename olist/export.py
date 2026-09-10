"""Cut the marts to CSV extracts for BI tools.

Deliberately thin. The warehouse is the source of truth and everything here
is a straight `select *` -- no reshaping, no renaming, no filtering beyond
the small-n suppression the marts already flag. Anything cleverer belongs in
a dbt model where it can be tested, not in an export script where it cannot.

The one thing this does add is a manifest recording row counts and the
analysis window, so an extract found on someone's laptop in six months can
still be traced back to the build that produced it.

Output: outputs/tableau/*.csv
"""

from __future__ import annotations

import json
from datetime import datetime, timezone

import duckdb

from . import OUTPUTS_DIR, WAREHOUSE

TABLES = [
    "mart_order_fact",
    "mart_delivery_performance",
    "mart_delivery_stage_attribution",
    "mart_review_drivers",
    "mart_review_driver_ranking",
    "mart_seller_performance",
    "mart_category_economics",
    "mart_customer_rfm",
    "mart_cohort_retention",
    "mart_data_coverage",
]


def main() -> int:
    dest = OUTPUTS_DIR / "tableau"
    dest.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    manifest = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "warehouse": str(WAREHOUSE),
        "tables": {},
    }

    window = con.execute(
        "select min(analysis_start), max(analysis_end) from main_marts.mart_order_fact"
    ).fetchone()
    manifest["analysis_start"] = str(window[0])
    manifest["analysis_end"] = str(window[1])

    for table in TABLES:
        path = dest / f"{table}.csv"
        con.execute(
            f"copy (select * from main_marts.{table}) to '{path}' (header, delimiter ',')"
        )
        n = con.execute(f"select count(*) from main_marts.{table}").fetchone()[0]
        manifest["tables"][table] = {"rows": n, "file": path.name}
        print(f"  {table:36s} {n:>9,} rows -> {path.name}")

    con.close()

    manifest_path = dest / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"\nwrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
