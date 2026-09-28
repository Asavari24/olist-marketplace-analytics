"""Tests for the forecasting models, metrics and marts.

The model functions are tested on hand-constructed series whose correct
forecast is arithmetic, not judgement. The marts are tested for the failure
modes that would make a backtest look better than it is.
"""

from __future__ import annotations

import duckdb
import numpy as np
import pytest

from olist import WAREHOUSE
from olist.forecast import (
    HORIZON,
    MODELS,
    f_drift,
    f_mean4,
    f_mean8,
    f_naive,
    mase_scale,
    rolling_origin_backtest,
)
import pandas as pd


# --------------------------------------------------------------------------
# Model functions
# --------------------------------------------------------------------------

def test_naive_repeats_the_last_value():
    y = np.array([5.0, 9.0, 2.0, 7.0])
    assert np.allclose(f_naive(y, 3), [7.0, 7.0, 7.0])


def test_mean4_uses_exactly_the_last_four():
    y = np.array([100.0, 0.0, 0.0, 2.0, 4.0, 6.0, 8.0])
    assert np.allclose(f_mean4(y, 2), [5.0, 5.0])  # mean(2,4,6,8)


def test_mean8_uses_exactly_the_last_eight():
    y = np.concatenate([np.full(5, 99.0), np.arange(1.0, 9.0)])
    assert np.allclose(f_mean8(y, 1), [np.arange(1.0, 9.0).mean()])


def test_drift_extrapolates_a_perfect_line_exactly():
    """On a series rising by 10 a week, drift must predict the continuation."""
    y = np.arange(0.0, 100.0, 10.0)      # 0,10,...,90
    assert np.allclose(f_drift(y, 3), [100.0, 110.0, 120.0])


def test_drift_on_a_flat_series_is_naive():
    y = np.full(10, 42.0)
    assert np.allclose(f_drift(y, 4), np.full(4, 42.0))


def test_every_model_returns_the_requested_horizon():
    y = np.abs(np.random.default_rng(3).normal(50, 10, 60))
    for name, fn in MODELS.items():
        out = np.asarray(fn(y, HORIZON), dtype=float)
        assert out.shape == (HORIZON,), name
        assert np.all(np.isfinite(out)), name


def test_models_handle_a_series_containing_zeros():
    """Intermittent demand is the normal case in thin segments."""
    y = np.array([0.0, 3.0, 0.0, 0.0, 5.0, 1.0, 0.0, 2.0] * 5)
    for name, fn in MODELS.items():
        out = np.asarray(fn(y, HORIZON), dtype=float)
        assert np.all(np.isfinite(out)), name


# --------------------------------------------------------------------------
# MASE scale
# --------------------------------------------------------------------------

def test_mase_scale_is_mean_absolute_first_difference():
    y = np.array([1.0, 3.0, 2.0, 6.0])       # diffs 2, 1, 4 -> mean 7/3
    assert mase_scale(y) == pytest.approx(7 / 3)


def test_mase_scale_is_nan_on_a_constant_series():
    """A flat series gives a zero denominator; NaN is correct, 0 would make
    every scaled error infinite and silently poison the mart."""
    assert np.isnan(mase_scale(np.full(10, 5.0)))


def test_mase_scale_needs_two_points():
    assert np.isnan(mase_scale(np.array([1.0])))


# --------------------------------------------------------------------------
# Backtest mechanics
# --------------------------------------------------------------------------

def _series(n=60, start="2017-01-02"):
    return pd.DataFrame({
        "week_start": pd.date_range(start, periods=n, freq="7D").date,
        "value": np.linspace(100, 200, n),
        "is_black_friday_window": False,
    })


def test_backtest_never_targets_a_week_at_or_before_its_origin():
    bt = rolling_origin_backtest(_series(), "orders")
    assert len(bt) > 0
    assert (pd.to_datetime(bt["target_week"]) > pd.to_datetime(bt["origin_week"])).all()


def test_backtest_horizon_matches_the_week_gap():
    bt = rolling_origin_backtest(_series(), "orders")
    gap = (pd.to_datetime(bt["target_week"]) - pd.to_datetime(bt["origin_week"])).dt.days // 7
    assert (gap == bt["horizon"]).all()


def test_backtest_horizon_never_exceeds_the_declared_maximum():
    bt = rolling_origin_backtest(_series(), "orders")
    assert bt["horizon"].max() <= HORIZON
    assert bt["horizon"].min() >= 1


def test_backtest_returns_empty_when_history_is_too_short():
    assert rolling_origin_backtest(_series(n=12), "orders").empty


def test_backtest_forecasts_are_never_negative():
    """A damped trend through a collapsing series predicts below zero unless
    clipped, and a negative forecast inverts the sign of every variance."""
    df = _series(n=60)
    df["value"] = np.linspace(500, 1, 60)
    bt = rolling_origin_backtest(df, "orders")
    assert (bt["forecast"] >= 0).all()


def test_drift_recovers_a_linear_series_in_the_backtest():
    """End-to-end sanity: on a noiseless straight line, drift should be
    near-exact. If it is not, the origin indexing is off by one."""
    bt = rolling_origin_backtest(_series(), "orders")
    d = bt[bt["model"] == "drift"]
    assert (d["forecast"] - d["actual"]).abs().max() < 1e-6


# --------------------------------------------------------------------------
# Marts
# --------------------------------------------------------------------------

@pytest.fixture(scope="module")
def con():
    if not WAREHOUSE.exists():
        pytest.skip("warehouse not built; run reproduce.sh first")
    c = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        c.execute("select 1 from main_marts.mart_forecast_accuracy limit 1")
    except Exception:
        pytest.skip("forecast marts not built; run olist.forecast then dbt run")
    yield c
    c.close()


def test_weekly_demand_is_fully_zero_filled(con):
    bad = con.execute("""
        with w as (select count(distinct week_start) n from main_marts.mart_weekly_demand)
        select count(*) from (
            select grain, segment from main_marts.mart_weekly_demand
            group by grain, segment
            having count(*) <> (select n from w))
    """).fetchone()[0]
    assert bad == 0


def test_weekly_demand_excludes_the_truncated_final_week(con):
    """The raw window ends Friday 2018-08-31, so the week of 08-27 is five
    days long. It must not appear."""
    last = con.execute(
        "select max(week_start) from main_marts.mart_weekly_demand").fetchone()[0]
    assert str(last) == "2018-08-20"


def test_naive_relative_mae_is_exactly_one(con):
    """rel_mae_vs_naive is defined against the naive model, so naive's own
    value must be 1.0 by construction. Anything else means the join that
    attaches the baseline is misaligned."""
    worst = con.execute("""
        select max(abs(rel_mae_vs_naive - 1.0))
        from main_marts.mart_forecast_accuracy where model = 'naive'
    """).fetchone()[0]
    assert worst == pytest.approx(0.0, abs=1e-12)


def test_mape_coverage_is_a_proportion(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_forecast_accuracy
        where mape_coverage < 0 or mape_coverage > 1
    """).fetchone()[0]
    assert bad == 0


def test_mape_is_null_exactly_when_coverage_is_zero(con):
    bad = con.execute("""
        select count(*) from main_marts.mart_forecast_accuracy
        where (mape_coverage = 0) <> (mape is null)
    """).fetchone()[0]
    assert bad == 0


def test_every_segment_has_exactly_one_champion_per_horizon(con):
    bad = con.execute("""
        select count(*) from (
            select grain, segment, measure, horizon
            from main_marts.mart_forecast_accuracy
            where model_rank = 1
            group by 1,2,3,4 having count(*) <> 1)
    """).fetchone()[0]
    assert bad == 0


def test_variance_mart_uses_only_champion_models(con):
    bad = con.execute("""
        select count(*)
        from main_marts.mart_forecast_variance v
        left join main_marts.mart_forecast_accuracy a
               on v.grain = a.grain and v.segment = a.segment
              and v.measure = a.measure and v.horizon = a.horizon
              and v.champion_model = a.model and a.model_rank = 1
        where a.model is null
    """).fetchone()[0]
    assert bad == 0


def test_variance_equals_forecast_minus_actual(con):
    worst = con.execute("""
        select max(abs(variance_abs - (forecast - actual)))
        from main_marts.mart_forecast_variance
    """).fetchone()[0]
    assert worst == pytest.approx(0.0, abs=1e-9)


def test_investigation_worklist_is_a_small_share(con):
    """The point of triage is a worklist, not a wall. If this ever exceeds a
    tenth of rows the thresholds have stopped discriminating."""
    share = con.execute("""
        select avg(needs_investigation::int) from main_marts.mart_forecast_variance
    """).fetchone()[0]
    assert 0 < share < 0.10


def test_black_friday_is_excluded_from_the_worklist(con):
    """It is a known unlearnable event, not a forecast defect to investigate."""
    bad = con.execute("""
        select count(*) from main_marts.mart_forecast_variance
        where needs_investigation and is_black_friday
    """).fetchone()[0]
    assert bad == 0


def test_black_friday_error_is_actually_scored(con):
    """The backtest must reach November 2017. With too few origins these
    columns come back all-NULL and the hardest week goes unevaluated."""
    n = con.execute("""
        select count(*) from main_marts.mart_forecast_accuracy
        where mape_black_friday_only is not null
    """).fetchone()[0]
    assert n > 0
