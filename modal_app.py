"""Deploy the Olist dbt + DuckDB warehouse on Modal.

A nightly rebuild of the whole warehouse on a Modal Volume, plus read-only
HTTP endpoints serving two marts.

SETUP (once, from the repo root):

    pip install modal
    modal setup                                   # interactive browser auth
    modal volume create olist-warehouse
    modal volume put olist-warehouse ./data/raw /raw

The last step matters and is easy to skip: the nine source CSVs (126MB) are
gitignored, so a fresh clone has no data. `python -m olist.download` fetches
them locally first, then the `volume put` above copies them to /data/raw
where the container's dbt sources expect them.

TEST:    modal run modal_app.py::refresh
DEPLOY:  modal deploy modal_app.py

WHY THE REFRESH IS THREE PHASES AND NOT ONE `dbt build`

The forecast marts read tables that olist/forecast.py writes: a rolling-origin
backtest is a loop over model refits, which SQL cannot express. So the Python
step sits INSIDE the dbt DAG, and the order is not optional:

    dbt build --exclude tag:forecast     everything up to mart_weekly_demand
    python -m olist.forecast             reads it, writes forecast.* tables
    dbt build --select tag:forecast      accuracy and variance marts

A plain `dbt build` on a fresh Volume fails at the forecast marts with
"table forecast.forecast_backtest does not exist". That is the correct
failure, and reproduce.sh runs the identical three phases locally.
"""

import modal

app = modal.App("olist-marts")

# Everything the warehouse and the forecast step need. statsmodels and scipy
# are here for olist/forecast.py (damped Holt) and the analysis modules;
# without them phase 2 of the refresh dies halfway through.
image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "dbt-core>=1.9,<1.11",
        "dbt-duckdb>=1.9,<1.11",
        "duckdb>=1.0",
        "pandas>=2.2",
        "numpy>=1.26,<2.3",
        "scipy>=1.11",
        "statsmodels>=0.14",
        "fastapi[standard]",
    )
    .env({
        # dbt_project/profiles.yml reads OLIST_DUCKDB; models/staging/_sources.yml
        # reads OLIST_RAW. Both fall back to local paths when unset, so the
        # same repo builds locally and here with no branching.
        "OLIST_DUCKDB": "/data/olist.duckdb",
        "OLIST_RAW": "/data/raw",
    })
    .add_local_dir(
        ".",
        remote_path="/root/project",
        # Without this the upload includes a ~1GB venv, 126MB of CSVs that
        # belong on the Volume rather than in the image, and a warehouse file
        # the container is about to rebuild anyway.
        ignore=[
            ".venv/**", ".git/**", "data/**", "warehouse/**",
            "outputs/**", "**/__pycache__/**", "**/.pytest_cache/**",
            "dbt_project/target/**", "dbt_project/logs/**", "logs/**",
        ],
    )
)

vol = modal.Volume.from_name("olist-warehouse", create_if_missing=True)

PROJECT = "/root/project"
DBT_DIR = f"{PROJECT}/dbt_project"
# The dbt project lives in a subdirectory, and profiles.yml sits beside it
# rather than in ~/.dbt, so both flags are required on every invocation.
FLAGS = ["--project-dir", DBT_DIR, "--profiles-dir", DBT_DIR]
DBT = ["dbt", "--no-use-colors"]


def _run(cmd: list[str], cwd: str = PROJECT) -> None:
    """Run a step, failing the whole function if it fails.

    check=True is the point: a dbt build that fails three models out of
    twenty-eight still exits non-zero, and without this the schedule would
    report a green run over a half-built warehouse.
    """
    import subprocess
    print(f"\n$ {' '.join(cmd)}", flush=True)
    subprocess.run(cmd, check=True, cwd=cwd)


@app.function(
    image=image,
    volumes={"/data": vol},
    schedule=modal.Cron("0 6 * * *"),   # daily, 06:00 UTC
    timeout=3600,                        # the 52-origin backtest needs minutes
    memory=4096,
)
def refresh():
    """Rebuild and test the entire warehouse. Fails loudly or not at all."""
    import os
    import time

    started = time.time()

    # Preflight. Without the CSVs every staging view fails with a DuckDB IO
    # error several layers deep; this turns that into one legible sentence.
    if not os.path.isdir("/data/raw") or not os.listdir("/data/raw"):
        raise RuntimeError(
            "/data/raw is empty on the Volume. Run, from the repo root:\n"
            "  python -m olist.download\n"
            "  modal volume put olist-warehouse ./data/raw /raw"
        )
    csvs = [f for f in os.listdir("/data/raw") if f.endswith(".csv")]
    print(f"found {len(csvs)} source CSVs on the Volume")
    if len(csvs) != 9:
        raise RuntimeError(f"expected 9 Olist CSVs in /data/raw, found {len(csvs)}: {sorted(csvs)}")

    # Phase 1 -- everything that does not depend on the Python forecast.
    _run(DBT + ["build", "--exclude", "tag:forecast"] + FLAGS)

    # Phase 2 -- fit models and backtest; writes forecast.* into the same file.
    _run(["python", "-m", "olist.forecast"])

    # Phase 3 -- the marts that score those forecasts.
    _run(DBT + ["build", "--select", "tag:forecast"] + FLAGS)

    vol.commit()   # persist the rebuilt DuckDB file

    elapsed = time.time() - started
    print(f"\nwarehouse rebuilt and tested in {elapsed/60:.1f} min")
    return {"status": "ok", "minutes": round(elapsed / 60, 2), "source_csvs": len(csvs)}


def _query(sql: str, params: list) -> list[dict]:
    """Run a read-only query and return JSON-safe records.

    The sanitising below is not defensive padding, it is load-bearing.
    Starlette serialises responses with `json.dumps(..., allow_nan=False)`,
    and several mart columns are legitimately NaN -- `mean_review_score`
    where a slice has no reviews, `mean_lateness_days_when_late` where
    nothing in the slice was late. Returning those raw makes FastAPI raise
    "Out of range float values are not JSON compliant" and the endpoint
    answers 500 on exactly the slices that are most interesting.

    NaN becomes null, which is what "no late orders here" actually means.
    Dates are emitted as plain ISO dates rather than midnight timestamps.
    """
    import duckdb
    import pandas as pd

    vol.reload()   # pick up whatever the last scheduled refresh wrote
    con = duckdb.connect("/data/olist.duckdb", read_only=True)
    try:
        df = con.execute(sql, params).fetchdf()
    finally:
        con.close()

    for col in df.columns:
        if pd.api.types.is_datetime64_any_dtype(df[col]):
            df[col] = df[col].dt.strftime("%Y-%m-%d")

    # object dtype is required first: assigning None into a float column
    # silently turns it straight back into NaN.
    return df.astype(object).where(pd.notna(df), None).to_dict(orient="records")


@app.function(image=image, volumes={"/data": vol})
@modal.fastapi_endpoint(method="GET", docs=True)
def delivery_performance(dimension: str = "customer_region", limit: int = 20):
    """Late rate and delivery-stage times for any slice of the business.

    Marts live in the `main_marts` schema, not the default `main`, so the
    table must be qualified.
    """
    return _query(
        """
        select dimension, dimension_value, purchase_month, n_orders,
               late_rate, mean_total_days, mean_promised_days,
               share_seller_handling, share_carrier_transit,
               mean_review_score, suppress_small_n
        from main_marts.mart_delivery_performance
        where dimension = ?
        order by purchase_month desc, n_orders desc
        limit ?
        """,
        [dimension, limit],
    )


@app.function(image=image, volumes={"/data": vol})
@modal.fastapi_endpoint(method="GET", docs=True)
def coverage():
    """Every row the pipeline excludes, and why.

    Sixteen rows. Served because it is the most useful thing in the warehouse
    for anyone deciding whether to trust a number from any other endpoint.
    """
    return _query(
        "select area, metric, n_orders, note from main_marts.mart_data_coverage",
        [],
    )
