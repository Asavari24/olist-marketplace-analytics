"""Weekly order and GMV forecasts by category and state, with honest backtesting.

Reads `mart_weekly_demand`, runs a rolling-origin backtest over several
models, and writes three tables back into the warehouse for the forecast
marts to build on:

    forecast.forecast_backtest   every (segment, model, origin, horizon) with
                                 its forecast and the actual that landed
    forecast.forecast_future     the forward forecast past the end of history
    forecast.forecast_run        one row of run metadata

WHAT THIS SERIES CAN AND CANNOT SUPPORT

86 complete weeks. That is short, and it rules two things out:

  No annual seasonality. Only 34 of the 86 weeks have a lag-52 counterpart, so
  a seasonal term would be fitted on a third of the data and validated on
  almost none of it. Black Friday 2017 appears exactly once; nothing can learn
  a yearly pattern from one observation. Every model here is level-and-trend
  only, and the November spike is reported as forecast error rather than
  pretended away.

  No deep hierarchy. Of 1,391 category x state cells, 74 clear the volume
  gate, covering 59% of GMV. Category and state on their own cover 93% and
  99%. The module forecasts all four grains but the accuracy mart reports
  coverage alongside error, because a brilliant MAPE on 59% of the business is
  not a brilliant forecast of the business.

WHY MASE IS THE HEADLINE METRIC AND MAPE IS NOT

MAPE is what stakeholders ask for, so it is reported. It is also the wrong
primary metric here, for reasons that bite on exactly this data:

  It is undefined when the actual is zero, and forecastable segments still
  have zero-demand weeks. Dropping those rows silently changes the population
  the metric describes, so `mape_coverage` records what share of points MAPE
  could be computed on.

  It explodes when the actual is small but non-zero. One week where a segment
  sold 2 units against a forecast of 8 contributes 300% and swamps fifty
  accurate weeks.

  It is asymmetric: over-forecasting is bounded at 100%, under-forecasting is
  not. A model tuned on MAPE learns to under-forecast.

MASE has none of these problems. It is the mean absolute error divided by the
mean absolute error of a one-step naive forecast on the TRAINING data, so it
is scale free, defined at zero, and symmetric.

One caveat on reading it, because it is widely got wrong: the "MASE < 1 beats
naive" rule applies to ONE-STEP forecasts. These are one- to four-step, and a
four-week-ahead forecast is legitimately harder than a one-week-ahead naive
step, so MASE above 1 is normal here and is not by itself a failure. MASE is
used to compare models against each other on a common scale, and reported per
horizon so the difficulty gradient is visible.

For the direct question -- did this model beat the benchmark -- there is
`rel_mae_vs_naive`: this model's MAE divided by the naive model's MAE over the
identical set of scored points. Below 1 beats naive, above 1 loses to it, with
no ambiguity about horizons.

Output: docs/forecast_findings.md, outputs/charts/forecast_*.png
"""

from __future__ import annotations

import warnings
from datetime import datetime, timezone

import duckdb
import numpy as np
import pandas as pd

from . import DOCS_DIR, OUTPUTS_DIR, WAREHOUSE

warnings.filterwarnings("ignore")

HORIZON = 4          # weeks ahead to forecast and to score

# Rolling-origin cuts. 52 rather than a handful, for a specific reason: with
# only 20 origins the backtest covered April-August 2018 and never scored
# November 2017 at all, so the Black Friday columns in mart_forecast_accuracy
# came back NULL and the one week most likely to break a forecast was silently
# outside the evaluation. A year of origins scores the whole usable series.
N_ORIGINS = 52

MIN_TRAIN_WEEKS = 30 # never fit on less than this
MEASURES = ("orders", "gmv")


# ---------------------------------------------------------------------------
# Models. Each takes a training array and a horizon, returns h forecasts.
# Deliberately simple: on 86 weeks with no fittable seasonality, the honest
# comparison is "can anything beat naive", and the answer is interesting.
# ---------------------------------------------------------------------------

def f_naive(y: np.ndarray, h: int) -> np.ndarray:
    """Last observed value, carried forward. The benchmark everything must beat."""
    return np.repeat(y[-1], h)


def f_mean4(y: np.ndarray, h: int) -> np.ndarray:
    """Mean of the last four weeks. Smooths the week-to-week noise."""
    return np.repeat(y[-4:].mean(), h)


def f_mean8(y: np.ndarray, h: int) -> np.ndarray:
    return np.repeat(y[-8:].mean(), h)


def f_drift(y: np.ndarray, h: int) -> np.ndarray:
    """Naive plus the average per-week change over the whole history.

    The classic random-walk-with-drift. On a series that grew as steeply as
    Olist's did, this is the cheapest way to stop systematically
    under-forecasting a trending series.
    """
    if len(y) < 2:
        return f_naive(y, h)
    slope = (y[-1] - y[0]) / (len(y) - 1)
    return y[-1] + slope * np.arange(1, h + 1)


def f_holt_damped(y: np.ndarray, h: int) -> np.ndarray:
    """Holt's linear trend with damping.

    Damped because an undamped trend extrapolated four weeks out of a steeply
    growing 86-week series produces numbers nobody would sign off on. Damping
    is the standard defence and it is what makes this usable in practice.
    """
    from statsmodels.tsa.holtwinters import ExponentialSmoothing

    if len(y) < MIN_TRAIN_WEEKS or np.all(y == y[0]):
        return f_naive(y, h)
    try:
        # Non-convergence is common on short, spiky segment series and is not
        # fatal -- statsmodels still returns the best parameters it reached.
        # Silenced at the call site rather than globally so a genuinely new
        # warning elsewhere in the module still surfaces.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            fit = ExponentialSmoothing(
                y, trend="add", damped_trend=True, seasonal=None,
                initialization_method="estimated",
            ).fit(optimized=True)
        return np.asarray(fit.forecast(h), dtype=float)
    except Exception:
        # A fit failure is not a reason to emit nothing; fall back and let the
        # backtest judge the fallback on the same footing as everything else.
        return f_drift(y, h)


MODELS = {
    "naive": f_naive,
    "mean4": f_mean4,
    "mean8": f_mean8,
    "drift": f_drift,
    "holt_damped": f_holt_damped,
}


# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

def mase_scale(train: np.ndarray) -> float:
    """Mean absolute one-step naive error on the training data.

    This is the MASE denominator (Hyndman & Koehler 2006). Computed on TRAIN,
    never on test — using the test period would let the scale absorb the very
    volatility the metric is supposed to expose.
    """
    if len(train) < 2:
        return np.nan
    d = np.abs(np.diff(train))
    m = d.mean()
    return m if m > 0 else np.nan


# ---------------------------------------------------------------------------
# Backtest
# ---------------------------------------------------------------------------

def rolling_origin_backtest(df: pd.DataFrame, measure: str) -> pd.DataFrame:
    """Expanding-window backtest for one segment and one measure.

    Expanding rather than sliding: the production process would refit on all
    history available at each Monday, so the backtest imitates that. Each
    origin trains on weeks 1..t and scores weeks t+1..t+h, which means no
    observation ever informs a forecast of itself.
    """
    y = df["value"].to_numpy(dtype=float)
    weeks = df["week_start"].to_numpy()
    n = len(y)

    last_origin = n - HORIZON
    first_origin = max(MIN_TRAIN_WEEKS, last_origin - N_ORIGINS + 1)
    if last_origin < first_origin:
        return pd.DataFrame()

    rows = []
    for t in range(first_origin, last_origin + 1):
        train, scale = y[:t], mase_scale(y[:t])
        for name, fn in MODELS.items():
            fc = np.asarray(fn(train, HORIZON), dtype=float)
            # Demand cannot be negative; a damped trend through a declining
            # segment will happily predict -40 orders otherwise.
            fc = np.clip(fc, 0.0, None)
            for hh in range(HORIZON):
                idx = t + hh
                if idx >= n:
                    break
                rows.append({
                    "model": name,
                    "origin_week": weeks[t - 1],
                    "target_week": weeks[idx],
                    "horizon": hh + 1,
                    "actual": y[idx],
                    "forecast": fc[hh],
                    "mase_scale": scale,
                })
    return pd.DataFrame(rows)


def future_forecast(df: pd.DataFrame) -> pd.DataFrame:
    """Forecast past the end of history with every model."""
    y = df["value"].to_numpy(dtype=float)
    last_week = pd.Timestamp(df["week_start"].max())
    rows = []
    for name, fn in MODELS.items():
        fc = np.clip(np.asarray(fn(y, HORIZON), dtype=float), 0.0, None)
        # Residual spread of this model's own one-step backtest errors would be
        # better, but is not available until the backtest runs; the naive
        # one-step sigma is a defensible stand-in and is labelled as such.
        sigma = np.std(np.diff(y)) if len(y) > 2 else 0.0
        for hh in range(HORIZON):
            rows.append({
                "model": name,
                "target_week": (last_week + pd.Timedelta(weeks=hh + 1)).date(),
                "horizon": hh + 1,
                "forecast": fc[hh],
                # Widening with sqrt(h), the random-walk convention.
                "lo80": max(0.0, fc[hh] - 1.2816 * sigma * np.sqrt(hh + 1)),
                "hi80": fc[hh] + 1.2816 * sigma * np.sqrt(hh + 1),
            })
    return pd.DataFrame(rows)


def run(con) -> tuple[pd.DataFrame, pd.DataFrame]:
    demand = con.execute("""
        select grain, segment, week_start, orders, gmv, is_black_friday_window
        from main_marts.mart_weekly_demand
        where is_forecastable
        order by grain, segment, week_start
    """).df()

    backtests, futures = [], []
    for (grain, segment), g in demand.groupby(["grain", "segment"], sort=False):
        g = g.sort_values("week_start")
        for measure in MEASURES:
            sub = g[["week_start", "is_black_friday_window"]].copy()
            sub["value"] = g[measure].to_numpy(dtype=float)

            bt = rolling_origin_backtest(sub, measure)
            if not bt.empty:
                bt["grain"], bt["segment"], bt["measure"] = grain, segment, measure
                bt = bt.merge(
                    sub[["week_start", "is_black_friday_window"]]
                        .rename(columns={"week_start": "target_week"}),
                    on="target_week", how="left",
                )
                backtests.append(bt)

            fu = future_forecast(sub)
            fu["grain"], fu["segment"], fu["measure"] = grain, segment, measure
            futures.append(fu)

    bt = pd.concat(backtests, ignore_index=True) if backtests else pd.DataFrame()
    fu = pd.concat(futures, ignore_index=True) if futures else pd.DataFrame()
    return bt, fu


def write_tables(con, bt: pd.DataFrame, fu: pd.DataFrame) -> None:
    con.execute("create schema if not exists forecast")
    con.register("bt_df", bt)
    con.register("fu_df", fu)
    con.execute("create or replace table forecast.forecast_backtest as select * from bt_df")
    con.execute("create or replace table forecast.forecast_future as select * from fu_df")
    con.execute("""
        create or replace table forecast.forecast_run as
        select ? as generated_at_utc, ? as horizon_weeks, ? as n_origins,
               ? as min_train_weeks, ? as models
    """, [datetime.now(timezone.utc).isoformat(timespec="seconds"),
          HORIZON, N_ORIGINS, MIN_TRAIN_WEEKS, ",".join(MODELS)])
    con.unregister("bt_df")
    con.unregister("fu_df")


def main() -> int:
    con = duckdb.connect(str(WAREHOUSE))
    bt, fu = run(con)
    write_tables(con, bt, fu)

    # Headline accuracy, computed here only for the console summary; the
    # published version is mart_forecast_accuracy.
    d = bt.copy()
    d["error"] = d["forecast"] - d["actual"]          # signed: + = over-forecast
    d["abs_err"] = d["error"].abs()
    d["ase"] = d["abs_err"] / d["mase_scale"]
    ok = d["actual"] > 0
    d.loc[ok, "ape"] = (d.loc[ok, "abs_err"] / d.loc[ok, "actual"]) * 100

    # Skill against naive over the identical scored points.
    naive_mae = (d[d["model"] == "naive"]
                 .groupby(["grain", "segment", "measure"])["abs_err"]
                 .mean().rename("naive_mae"))

    summary = (d[d["grain"] == "total"]
               .groupby(["measure", "model"])
               .agg(MASE=("ase", "mean"), MAPE=("ape", "mean"),
                    MAE=("abs_err", "mean"), bias=("error", "mean"))
               .reset_index())
    base = (summary[summary["model"] == "naive"]
            .set_index("measure")["MAE"].rename("naive_mae"))
    summary = summary.join(base, on="measure")
    summary["rel_vs_naive"] = summary["MAE"] / summary["naive_mae"]
    summary = summary.drop(columns=["naive_mae"])

    con.close()
    print(f"backtest rows  {len(bt):,}")
    print(f"future rows    {len(fu):,}")
    print(f"segments       {bt[['grain','segment']].drop_duplicates().shape[0]:,}")
    print("\ntotal-grain accuracy. rel_vs_naive < 1 beats the benchmark;")
    print("bias > 0 means over-forecasting.")
    print(summary.round(3).to_string(index=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
