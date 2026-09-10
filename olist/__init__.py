"""Analysis layer for the Olist Brazilian e-commerce warehouse.

The warehouse itself is dbt + DuckDB; this package holds the work SQL is the
wrong tool for -- joint regression, bootstrap intervals, chart rendering --
plus the reproducible fetch of the source CSVs.
"""

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"
WAREHOUSE = PROJECT_ROOT / "warehouse" / "olist.duckdb"
DOCS_DIR = PROJECT_ROOT / "docs"
OUTPUTS_DIR = PROJECT_ROOT / "outputs"

__all__ = ["PROJECT_ROOT", "RAW_DIR", "WAREHOUSE", "DOCS_DIR", "OUTPUTS_DIR"]
