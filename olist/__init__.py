"""Analysis layer for the Olist Brazilian e-commerce warehouse.

The warehouse itself is dbt + DuckDB; this package holds the work SQL is the
wrong tool for -- joint regression, bootstrap intervals, chart rendering --
plus the reproducible fetch of the source CSVs.

PATHS ARE ENVIRONMENT-DRIVEN, AND THEY HAVE TO BE.

Every path below defaults to its location in a local checkout and can be
overridden by an environment variable. That is not generality for its own
sake -- it is the fix for a real failure. dbt reads the warehouse location
from OLIST_DUCKDB (see dbt_project/profiles.yml) and the CSV location from
OLIST_RAW (see models/staging/_sources.yml). When this package computed its
own paths instead, the Modal container built the warehouse correctly onto its
Volume at /data/olist.duckdb and then olist.forecast went looking for
/root/project/warehouse/olist.duckdb and died. Two places defined the same
path and only one of them was configured.

So dbt and Python now read the SAME variables. Anything that adds a new path
should add it here, with a default and a variable, rather than deriving one
from PROJECT_ROOT at the call site.
"""

import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _path(env_var: str, default: Path) -> Path:
    """Resolve a path from the environment, falling back to the local layout."""
    value = os.environ.get(env_var)
    return Path(value).expanduser() if value else default


# Read by dbt too -- models/staging/_sources.yml uses OLIST_RAW and
# profiles.yml uses OLIST_DUCKDB. Keep them in step.
RAW_DIR = _path("OLIST_RAW", PROJECT_ROOT / "data" / "raw")
WAREHOUSE = _path("OLIST_DUCKDB", PROJECT_ROOT / "warehouse" / "olist.duckdb")

# Written to, so in a container these must point somewhere writable. The
# source tree is mounted from the local machine and is not the right place
# for generated output; modal_app.py sends both to the Volume.
DOCS_DIR = _path("OLIST_DOCS", PROJECT_ROOT / "docs")
OUTPUTS_DIR = _path("OLIST_OUTPUTS", PROJECT_ROOT / "outputs")

__all__ = ["PROJECT_ROOT", "RAW_DIR", "WAREHOUSE", "DOCS_DIR", "OUTPUTS_DIR"]
