#!/usr/bin/env bash
# End-to-end reproduction. Assumes python 3.11+ on PATH and network access
# for the first run (to fetch the source CSVs).
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD

# DuckDB bakes the source path into every staging view, so it must be
# absolute -- otherwise the warehouse only works when queried from
# dbt_project/. See models/staging/_sources.yml.
export OLIST_RAW="$ROOT/data/raw"

echo "==> 1/8 Python environment"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt tabulate

echo "==> 2/8 Source data (126MB, skipped if already present and correct size)"
.venv/bin/python -m olist.download

echo "==> 3/8 Profile the source before modelling"
.venv/bin/python -m olist.profile_source

echo "==> 4/8 Build the warehouse (everything except the forecast marts)"
mkdir -p warehouse
( cd dbt_project && export DBT_PROFILES_DIR=$PWD \
  && "$ROOT/.venv/bin/dbt" run --exclude tag:forecast )

# The forecasting step sits INSIDE the dbt DAG, not after it: a rolling-origin
# backtest is a loop over model refits, which SQL cannot express, but every
# metric computed from its output is ordinary arithmetic and belongs in a
# tested dbt model. Hence three phases rather than two.
echo "==> 5/8 Fit models and backtest (writes forecast.* tables)"
.venv/bin/python -m olist.forecast

echo "==> 6/8 Build the forecast marts on top of those tables"
( cd dbt_project && export DBT_PROFILES_DIR=$PWD \
  && "$ROOT/.venv/bin/dbt" run --select tag:forecast )

echo "==> 7/8 Test the warehouse"
( cd dbt_project && export DBT_PROFILES_DIR=$PWD \
  && "$ROOT/.venv/bin/dbt" test )

echo "==> 8/8 Analysis layer and extracts"
.venv/bin/python -m pytest olist/tests -q
.venv/bin/python -m olist.delivery_analysis
.venv/bin/python -m olist.review_drivers
.venv/bin/python -m olist.customer_analysis
.venv/bin/python -m olist.seller_survival
.venv/bin/python -m olist.freight_model
.venv/bin/python -m olist.forecast_report
.venv/bin/python -m olist.export

echo
echo "Done."
echo "  Warehouse   warehouse/olist.duckdb"
echo "  Findings    docs/delivery_findings.md, docs/review_drivers.md,"
echo "              docs/customer_findings.md, docs/seller_survival.md,"
echo "              docs/freight_findings.md, docs/forecast_findings.md,"
echo "              docs/data_profile.md"
echo "  Dashboards  docs/tableau_dashboard_spec.md"
echo "  Charts      outputs/charts/"
echo "  Extracts    outputs/tableau/"
