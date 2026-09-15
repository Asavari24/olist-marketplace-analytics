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

echo "==> 1/7 Python environment"
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt tabulate

echo "==> 2/7 Source data (126MB, skipped if already present and correct size)"
.venv/bin/python -m olist.download

echo "==> 3/7 Profile the source before modelling"
.venv/bin/python -m olist.profile_source

echo "==> 4/7 Build the warehouse"
mkdir -p warehouse
( cd dbt_project && export DBT_PROFILES_DIR=$PWD \
  && "$ROOT/.venv/bin/dbt" run )

echo "==> 5/7 Test the warehouse"
( cd dbt_project && export DBT_PROFILES_DIR=$PWD \
  && "$ROOT/.venv/bin/dbt" test )

echo "==> 6/7 Analysis layer"
.venv/bin/python -m pytest olist/tests -q
.venv/bin/python -m olist.delivery_analysis
.venv/bin/python -m olist.review_drivers
.venv/bin/python -m olist.customer_analysis
.venv/bin/python -m olist.seller_survival
.venv/bin/python -m olist.freight_model

echo "==> 7/7 BI extracts"
.venv/bin/python -m olist.export

echo
echo "Done."
echo "  Warehouse   warehouse/olist.duckdb"
echo "  Findings    docs/delivery_findings.md, docs/review_drivers.md,"
echo "              docs/customer_findings.md, docs/seller_survival.md,"
echo "              docs/freight_findings.md, docs/data_profile.md"
echo "  Dashboards  docs/tableau_dashboard_spec.md"
echo "  Charts      outputs/charts/"
echo "  Extracts    outputs/tableau/"
