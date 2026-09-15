"""Tests for the Kaplan-Meier implementation and the new marts.

The KM estimator is hand-rolled in olist/seller_survival.py, so it is tested
against worked examples whose answers are known independently of the code.
"""

from __future__ import annotations

import duckdb
import numpy as np
import pytest

from olist import WAREHOUSE
from olist.seller_survival import (
    kaplan_meier,
    logrank_test,
    median_survival,
    survival_at,
)


# --------------------------------------------------------------------------
# Kaplan-Meier against hand-computable cases
# --------------------------------------------------------------------------

def test_km_with_no_censoring_is_the_empirical_survival_function():
    """With every exit observed, KM must reduce to 1 - ECDF."""
    d = np.array([1, 2, 2, 3, 4])
    e = np.ones(5, dtype=int)
    km = kaplan_meier(d, e)
    assert survival_at(km, 1) == pytest.approx(4 / 5)
    assert survival_at(km, 2) == pytest.approx(2 / 5)
    assert survival_at(km, 3) == pytest.approx(1 / 5)
    assert survival_at(km, 4) == pytest.approx(0.0)


def test_km_worked_example_with_censoring():
    """Classic textbook case, computed by hand.

    Durations 1, 2+, 3, 4+, 5 (+ = censored).
      t=1: at risk 5, 1 exit  -> S = 1 - 1/5           = 0.8
      t=2: censored, no drop  -> S = 0.8
      t=3: at risk 3, 1 exit  -> S = 0.8 * (1 - 1/3)   = 0.5333...
      t=4: censored, no drop  -> S = 0.5333...
      t=5: at risk 1, 1 exit  -> S = 0.5333 * (1 - 1/1) = 0
    """
    d = np.array([1, 2, 3, 4, 5])
    e = np.array([1, 0, 1, 0, 1])
    km = kaplan_meier(d, e)
    assert survival_at(km, 1) == pytest.approx(0.8)
    assert survival_at(km, 2) == pytest.approx(0.8)
    assert survival_at(km, 3) == pytest.approx(0.8 * 2 / 3)
    assert survival_at(km, 4) == pytest.approx(0.8 * 2 / 3)
    assert survival_at(km, 5) == pytest.approx(0.0)


def test_censored_subject_raises_survival_versus_treating_it_as_an_exit():
    """The entire point of censoring: a censored observation must not be
    counted as an exit. If it were, survival would be lower."""
    d = np.array([1, 2, 3, 4])
    correct = kaplan_meier(d, np.array([1, 0, 0, 1]))
    if_treated_as_exits = kaplan_meier(d, np.array([1, 1, 1, 1]))
    assert survival_at(correct, 3) > survival_at(if_treated_as_exits, 3)


def test_km_all_censored_never_drops():
    km = kaplan_meier(np.array([1, 2, 3]), np.array([0, 0, 0]))
    assert survival_at(km, 3) == pytest.approx(1.0)


def test_km_survival_is_monotonically_non_increasing():
    rng = np.random.default_rng(7)
    d = rng.integers(1, 20, 500)
    e = rng.integers(0, 2, 500)
    km = kaplan_meier(d, e)
    assert np.all(np.diff(km["survival"].values) <= 1e-12)


def test_km_confidence_bounds_stay_inside_unit_interval():
    rng = np.random.default_rng(11)
    d = rng.integers(1, 15, 400)
    e = rng.integers(0, 2, 400)
    km = kaplan_meier(d, e)
    assert km["ci_low"].min() >= 0.0
    assert km["ci_high"].max() <= 1.0
    assert np.all(km["ci_low"] <= km["survival"] + 1e-12)
    assert np.all(km["survival"] <= km["ci_high"] + 1e-12)


def test_km_handles_empty_input():
    km = kaplan_meier(np.array([]), np.array([]))
    assert len(km) == 0


def test_median_survival_is_nan_when_curve_never_reaches_half():
    km = kaplan_meier(np.array([1, 2, 3]), np.array([0, 0, 0]))
    assert np.isnan(median_survival(km))


def test_logrank_finds_no_difference_between_identical_groups():
    d = np.array([1, 2, 3, 4, 5, 6])
    e = np.array([1, 1, 1, 1, 1, 1])
    chi2, p = logrank_test(d, e, d, e)
    assert chi2 == pytest.approx(0.0, abs=1e-9)
    assert p > 0.99


def test_logrank_detects_a_clear_separation():
    early = np.array([1, 1, 2, 2, 2, 3])
    late = np.array([10, 11, 12, 12, 13, 14])
    ones = np.ones(6, dtype=int)
    chi2, p = logrank_test(early, ones, late, ones)
    assert chi2 > 8
    assert p < 0.01


# --------------------------------------------------------------------------
# The new marts
# --------------------------------------------------------------------------

@pytest.fixture(scope="module")
def con():
    if not WAREHOUSE.exists():
        pytest.skip("warehouse not built; run reproduce.sh first")
    c = duckdb.connect(str(WAREHOUSE), read_only=True)
    yield c
    c.close()


def test_seller_cohorts_covers_every_selling_seller_once(con):
    n, distinct, from_perf = con.execute("""
        select (select count(*) from main_marts.mart_seller_cohorts),
               (select count(distinct seller_id) from main_marts.mart_seller_cohorts),
               (select count(*) from main_marts.mart_seller_performance)
    """).fetchone()
    assert n == distinct == from_perf


def test_lifespan_never_exceeds_the_observable_window(con):
    """A seller cannot have traded for longer than the window allowed. If this
    fails, the cohort arithmetic is wrong and every survival curve with it."""
    bad = con.execute("""
        select count(*) from main_marts.mart_seller_cohorts
        where lifespan_months > observable_months
    """).fetchone()[0]
    assert bad == 0


def test_lifespan_is_at_least_one_month(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_seller_cohorts where lifespan_months < 1
    """).fetchone()[0]
    assert bad == 0


def test_churn_event_is_the_complement_of_censoring(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_seller_cohorts
        where churn_event <> (case when is_censored then 0 else 1 end)
    """).fetchone()[0]
    assert bad == 0


def test_censored_sellers_are_the_ones_still_trading_at_the_edge(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_seller_cohorts
        where is_censored <> (months_silent_at_window_end <= 1)
    """).fetchone()[0]
    assert bad == 0


def test_activity_density_is_a_proportion(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_seller_cohorts
        where activity_density <= 0 or activity_density > 1
    """).fetchone()[0]
    assert bad == 0


def test_freight_billable_weight_is_the_larger_of_mass_and_volume(con):
    """The volumetric convention. If this inverts, bulky-light categories get
    flagged as overpriced when they are simply billed by volume."""
    bad = con.execute("""
        select count(*) from main_marts.mart_freight_economics
        where billable_kg + 1e-9 < greatest(coalesce(weight_kg, 0),
                                            coalesce(volumetric_kg, 0))
    """).fetchone()[0]
    assert bad == 0


def test_freight_economics_preserves_item_line_grain(con):
    n, from_items = con.execute("""
        select (select count(*) from main_marts.mart_freight_economics),
               (select count(*) from main_intermediate.int_order_items_enriched i
                join main_marts.mart_order_fact o on i.order_id = o.order_id)
    """).fetchone()
    assert n == from_items


def test_freight_total_reconciles_to_item_lines(con):
    a, b = con.execute("""
        select (select sum(item_freight) from main_marts.mart_freight_economics),
               (select sum(i.item_freight)
                from main_intermediate.int_order_items_enriched i
                join main_marts.mart_order_fact o on i.order_id = o.order_id)
    """).fetchone()
    assert a == pytest.approx(b, rel=1e-9)


def test_free_shipping_lines_are_flagged_not_dropped(con):
    free, flagged = con.execute("""
        select sum((item_freight = 0)::int), sum(is_free_shipping::int)
        from main_marts.mart_freight_economics
    """).fetchone()
    assert free == flagged
    assert free > 0
