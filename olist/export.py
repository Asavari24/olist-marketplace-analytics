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

# Summary marts: small enough to commit, so a reviewer can read every result
# without building the warehouse.
TABLES = [
    "mart_delivery_performance",
    "mart_delivery_stage_attribution",
    "mart_review_drivers",
    "mart_review_driver_ranking",
    "mart_seller_performance",
    "mart_category_economics",
    "mart_cohort_retention",
    "mart_seller_cohorts",
    "mart_data_coverage",
]

# Row-level extracts, big enough that they are gitignored and regenerated
# rather than committed. Listed separately so the manifest records which
# tables a given checkout will and will not have on disk.
LARGE_TABLES = [
    "mart_order_fact",
    "mart_customer_rfm",
    "mart_freight_economics",
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

    for table, committed in [(t, True) for t in TABLES] + \
                            [(t, False) for t in LARGE_TABLES]:
        path = dest / f"{table}.csv"
        con.execute(
            f"copy (select * from main_marts.{table}) to '{path}' (header, delimiter ',')"
        )
        n = con.execute(f"select count(*) from main_marts.{table}").fetchone()[0]
        size_mb = path.stat().st_size / 1e6
        manifest["tables"][table] = {
            "rows": n,
            "file": path.name,
            "size_mb": round(size_mb, 2),
            # False = gitignored, so a fresh checkout will not have this file
            # until export runs. Recorded here so the absence is explicable.
            "committed_to_git": committed,
        }
        flag = "" if committed else "   (gitignored, regenerated)"
        print(f"  {table:36s} {n:>9,} rows  {size_mb:>7.1f}MB -> {path.name}{flag}")

    con.close()

    manifest_path = dest / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"\nwrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
