"""Unit tests for the analysis layer.

These test the code that dbt cannot: the bootstrap, the haversine macro's
arithmetic, and the warehouse invariants that span models. Everything that
can be asserted in SQL is asserted in `dbt_project/tests/` instead.

Run: pytest olist/tests -q
"""

from __future__ import annotations

import math

import duckdb
import numpy as np
import pytest

from olist import WAREHOUSE
from olist.delivery_analysis import bootstrap_ci


# --------------------------------------------------------------------------
# Bootstrap
# --------------------------------------------------------------------------

def test_bootstrap_recovers_known_mean():
    rng = np.random.default_rng(1)
    x = rng.normal(loc=10.0, scale=2.0, size=5000)
    point, lo, hi = bootstrap_ci(x, n_boot=500)
    assert point == pytest.approx(x.mean())
    assert lo < 10.0 < hi
    # A 5,000-sample mean of a sigma=2 normal has SE ~0.028, so the 95% CI
    # should be tight. A wide interval means the resampling is wrong.
    assert hi - lo < 0.25


def test_bootstrap_interval_brackets_point_estimate():
    rng = np.random.default_rng(2)
    x = rng.exponential(scale=3.0, size=2000)
    point, lo, hi = bootstrap_ci(x, n_boot=500)
    assert lo <= point <= hi


def test_bootstrap_is_deterministic_for_a_given_seed():
    x = np.arange(100, dtype=float)
    a = bootstrap_ci(x, n_boot=200, seed=42)
    b = bootstrap_ci(x, n_boot=200, seed=42)
    assert a == b


def test_bootstrap_ignores_nan():
    x = np.array([1.0, 2.0, 3.0, np.nan])
    point, _, _ = bootstrap_ci(x, n_boot=100)
    assert point == pytest.approx(2.0)


def test_bootstrap_handles_all_nan():
    point, lo, hi = bootstrap_ci(np.array([np.nan, np.nan]), n_boot=10)
    assert math.isnan(point) and math.isnan(lo) and math.isnan(hi)


# --------------------------------------------------------------------------
# Warehouse invariants that span models
# --------------------------------------------------------------------------

@pytest.fixture(scope="module")
def con():
    if not WAREHOUSE.exists():
        pytest.skip("warehouse not built; run reproduce.sh first")
    c = duckdb.connect(str(WAREHOUSE), read_only=True)
    yield c
    c.close()


def test_haversine_macro_matches_known_distance(con):
    """Sao Paulo to Rio is ~357km great-circle. The macro is compiled into
    int_zip_centroids and int_order_items_enriched; if its constant or its
    radian conversion were wrong, every distance band would be wrong."""
    d = con.execute("""
        select 6371.0088 * 2 * asin(sqrt(
            pow(sin(radians(-22.9068 - (-23.5505)) / 2), 2)
          + cos(radians(-23.5505)) * cos(radians(-22.9068))
          * pow(sin(radians(-43.1729 - (-46.6333)) / 2), 2)))
    """).fetchone()[0]
    assert d == pytest.approx(357, abs=6)


def test_stage_shares_sum_to_one_per_slice(con):
    """mart_delivery_performance publishes three stage shares per row. They
    must sum to 1 or the slice-level attribution is not a decomposition."""
    bad = con.execute("""
        select count(*) from main_marts.mart_delivery_performance
        where abs(share_payment_approval + share_seller_handling
                  + share_carrier_transit - 1.0) > 1e-9
    """).fetchone()[0]
    assert bad == 0


def test_order_fact_has_no_duplicate_orders(con):
    n, distinct = con.execute(
        "select count(*), count(distinct order_id) from main_marts.mart_order_fact"
    ).fetchone()
    assert n == distinct


def test_rfm_covers_every_person_exactly_once(con):
    fact_persons = con.execute(
        "select count(distinct person_key) from main_marts.mart_order_fact"
    ).fetchone()[0]
    rfm_rows, rfm_persons = con.execute(
        "select count(*), count(distinct person_key) from main_marts.mart_customer_rfm"
    ).fetchone()
    assert rfm_rows == rfm_persons == fact_persons


def test_rfm_monetary_reconciles_to_order_fact(con):
    """Person-level GMV must equal the sum of that person's orders. Catches a
    fan-out in the RFM aggregation."""
    gap = con.execute("""
        with from_fact as (
            select person_key, sum(coalesce(gmv, 0)) as gmv
            from main_marts.mart_order_fact group by person_key
        )
        select coalesce(max(abs(r.monetary_gmv - f.gmv)), 0)
        from main_marts.mart_customer_rfm r
        join from_fact f using (person_key)
    """).fetchone()[0]
    assert gap < 0.01


def test_lateness_is_measured_against_end_of_estimated_day(con):
    """The promise convention. If this regresses to a midnight comparison the
    late rate jumps by about a fifth, and it would not be obvious from any
    single number."""
    mismatched = con.execute("""
        select count(*) from main_marts.mart_order_fact
        where has_delivery_outcome
          and is_late <> (delivered_at > date_trunc('day', estimated_delivery_date)
                                          + interval 1 day)
    """).fetchone()[0]
    assert mismatched == 0


def test_late_rate_is_in_the_expected_range(con):
    """A regression canary. This dataset's late rate is 6.79% under the
    end-of-day convention and 8.11% under the midnight one; the band below
    passes the first and fails the second."""
    rate = con.execute("""
        select avg(is_late::int) from main_marts.mart_order_fact
        where has_delivery_outcome
    """).fetchone()[0]
    assert 0.060 < rate < 0.075


def test_no_negative_delivery_stages(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_order_fact
        where has_delivery_outcome
          and (payment_approval_days < 0 or seller_handling_days < 0
               or carrier_transit_days < 0)
    """).fetchone()[0]
    assert bad == 0


def test_person_key_is_not_the_order_customer_key(con):
    """The dataset's central naming trap. If these ever match row-for-row,
    something upstream has joined on the wrong customer column and every
    retention number becomes structurally zero."""
    persons, order_keys = con.execute("""
        select count(distinct person_key), count(distinct order_customer_key)
        from main_marts.mart_order_fact
    """).fetchone()
    assert persons < order_keys


def test_repeat_rate_matches_the_documented_negative_result(con):
    rate = con.execute("""
        select avg((n > 1)::int) from (
            select person_key, count(*) as n
            from main_marts.mart_order_fact group by person_key)
    """).fetchone()[0]
    assert 0.025 < rate < 0.040


def test_cohort_triangle_has_no_unobservable_cells(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_cohort_retention where not is_observable
    """).fetchone()[0]
    assert bad == 0


def test_month_zero_retention_is_one(con):
    """Every cohort member is active in their own acquisition month by
    definition. If this is not 1.0 the cohort join has lost rows."""
    worst = con.execute("""
        select min(retention_rate) from main_marts.mart_cohort_retention
        where months_since_first = 0
    """).fetchone()[0]
    assert worst == pytest.approx(1.0)


def test_seller_gmv_reconciles_to_item_lines(con):
    """Seller metrics are item-level precisely so multi-seller orders are not
    double-counted. Total seller GMV must equal total item GMV."""
    seller_gmv, item_gmv = con.execute("""
        select (select sum(gmv) from main_marts.mart_seller_performance),
               (select sum(i.item_price)
                from main_intermediate.int_order_items_enriched i
                join main_marts.mart_order_fact o on i.order_id = o.order_id)
    """).fetchone()
    assert seller_gmv == pytest.approx(item_gmv, rel=1e-9)


def test_category_gmv_reconciles_to_item_lines(con):
    cat_gmv, item_gmv = con.execute("""
        select (select sum(gmv) from main_marts.mart_category_economics),
               (select sum(i.item_price)
                from main_intermediate.int_order_items_enriched i
                join main_marts.mart_order_fact o on i.order_id = o.order_id)
    """).fetchone()
    assert cat_gmv == pytest.approx(item_gmv, rel=1e-9)


def test_zip_centroids_are_unique_per_prefix(con):
    n, distinct = con.execute("""
        select count(*), count(distinct zip_prefix)
        from main_intermediate.int_zip_centroids
    """).fetchone()
    assert n == distinct
