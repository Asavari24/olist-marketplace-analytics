"""Seller survival: how long sellers keep trading, handling censoring properly.

53% of sellers in this window were still trading when it closed. Any lifespan
statistic that ignores that is measuring the window, not the sellers -- and it
does so in a direction that flatters old cohorts and punishes new ones.

Kaplan-Meier is implemented here rather than pulled from `lifelines` for two
reasons: it is twenty lines, and having it local means it can be unit-tested
against a worked example with a known answer (see olist/tests/test_survival.py),
which a black-box import cannot be.

The estimator:

    S(t) = product over event times t_i <= t of (1 - d_i / n_i)

where d_i is exits observed at t_i and n_i is the number still at risk just
before t_i. Censored sellers stay in n_i up to their censoring time and then
leave without ever contributing a d_i -- that is the whole mechanism, and it
is why a censored seller correctly counts as evidence of survival rather than
as evidence of exit.

Greenwood's formula gives the variance; confidence bounds are computed on the
log-log scale so they cannot escape [0, 1], which the naive normal interval
does at the tails where survival is near 1.

Output: docs/seller_survival.md, outputs/charts/seller_survival.png
"""

from __future__ import annotations

import duckdb
import numpy as np
import pandas as pd

from . import DOCS_DIR, OUTPUTS_DIR, WAREHOUSE


def kaplan_meier(durations: np.ndarray, events: np.ndarray) -> pd.DataFrame:
    """Kaplan-Meier survival curve with Greenwood log-log confidence bounds.

    durations: observed time to exit or censoring (>= 1)
    events:    1 = exit observed, 0 = right-censored
    """
    durations = np.asarray(durations, dtype=float)
    events = np.asarray(events, dtype=int)
    if len(durations) == 0:
        return pd.DataFrame(columns=["t", "n_at_risk", "n_events", "survival",
                                     "ci_low", "ci_high"])

    times = np.unique(durations)
    n = len(durations)

    rows, survival, cum_var = [], 1.0, 0.0
    for t in times:
        at_risk = int((durations >= t).sum())
        exits = int(((durations == t) & (events == 1)).sum())
        censored = int(((durations == t) & (events == 0)).sum())

        if at_risk > 0 and exits > 0:
            survival *= 1.0 - exits / at_risk
            # Greenwood: accumulate d / (n * (n - d)).
            if at_risk > exits:
                cum_var += exits / (at_risk * (at_risk - exits))
            else:
                cum_var = np.nan

        # Log-log transform keeps the interval inside [0, 1].
        if 0.0 < survival < 1.0 and np.isfinite(cum_var) and cum_var > 0:
            se_loglog = np.sqrt(cum_var) / abs(np.log(survival))
            z = 1.959963985
            lo = survival ** np.exp(z * se_loglog)
            hi = survival ** np.exp(-z * se_loglog)
        else:
            lo = hi = survival

        rows.append({
            "t": float(t),
            "n_at_risk": at_risk,
            "n_events": exits,
            "n_censored": censored,
            "survival": survival,
            "ci_low": lo,
            "ci_high": hi,
        })

    out = pd.DataFrame(rows)
    out.attrs["n"] = n
    out.attrs["n_events"] = int(events.sum())
    return out


def median_survival(curve: pd.DataFrame) -> float:
    """First time at which survival drops to 0.5 or below; NaN if it never does."""
    below = curve[curve["survival"] <= 0.5]
    return float(below["t"].iloc[0]) if len(below) else float("nan")


def survival_at(curve: pd.DataFrame, t: float) -> float:
    prior = curve[curve["t"] <= t]
    return float(prior["survival"].iloc[-1]) if len(prior) else 1.0


def logrank_test(d1, e1, d2, e2) -> tuple[float, float]:
    """Two-sample log-rank test. Returns (chi-square statistic, p-value).

    Tests whether two survival curves differ, correctly accounting for
    censoring -- which a t-test on observed lifespans does not.
    """
    from scipy import stats

    d1, e1 = np.asarray(d1, float), np.asarray(e1, int)
    d2, e2 = np.asarray(d2, float), np.asarray(e2, int)
    times = np.unique(np.concatenate([d1[e1 == 1], d2[e2 == 1]]))

    o_minus_e, var = 0.0, 0.0
    for t in times:
        n1, n2 = (d1 >= t).sum(), (d2 >= t).sum()
        n = n1 + n2
        if n < 2:
            continue
        ob1 = ((d1 == t) & (e1 == 1)).sum()
        ob = ob1 + ((d2 == t) & (e2 == 1)).sum()
        if ob == 0:
            continue
        exp1 = ob * n1 / n
        o_minus_e += ob1 - exp1
        var += (ob * (n1 / n) * (n2 / n) * (n - ob)) / (n - 1)

    if var <= 0:
        return (0.0, 1.0)
    chi2 = o_minus_e ** 2 / var
    return (float(chi2), float(stats.chi2.sf(chi2, df=1)))


def _curve_table(curve: pd.DataFrame, horizons=(1, 3, 6, 12)) -> dict:
    return {f"survival_{h}m": survival_at(curve, h) for h in horizons}


def main() -> int:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    df = con.execute("""
        select seller_id, cohort_month, lifespan_months, observable_months,
               churn_event, is_censored, gmv, gmv_quartile, activity_density,
               seller_region, orders
        from main_marts.mart_seller_cohorts
    """).df()

    naive_by_age = con.execute("""
        select observable_months,
               count(*)                         as sellers,
               avg(is_censored::int)            as censored_share,
               avg(lifespan_months)             as naive_mean_lifespan
        from main_marts.mart_seller_cohorts
        group by observable_months
        order by observable_months desc
    """).df()
    con.close()

    overall = kaplan_meier(df["lifespan_months"], df["churn_event"])

    # By GMV quartile: does size predict survival?
    by_quartile = {}
    for q in sorted(df["gmv_quartile"].unique()):
        sub = df[df["gmv_quartile"] == q]
        by_quartile[int(q)] = kaplan_meier(sub["lifespan_months"], sub["churn_event"])

    top, bottom = df[df["gmv_quartile"] == 1], df[df["gmv_quartile"] == 4]
    chi2, p = logrank_test(top["lifespan_months"], top["churn_event"],
                           bottom["lifespan_months"], bottom["churn_event"])

    # The bias demonstration: naive mean lifespan against how much window the
    # cohort had. If censoring did not matter these would be flat.
    corr = naive_by_age[["observable_months", "naive_mean_lifespan"]].corr().iloc[0, 1]

    # ---- chart -----------------------------------------------------------
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    charts = OUTPUTS_DIR / "charts"
    charts.mkdir(parents=True, exist_ok=True)

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

    ax1.step(overall["t"], overall["survival"], where="post", color="#1F6F8B", lw=2)
    ax1.fill_between(overall["t"], overall["ci_low"], overall["ci_high"],
                     step="post", alpha=0.18, color="#1F6F8B")
    ax1.axhline(0.5, ls="--", color="#B23A48", lw=1)
    ax1.set_xlabel("Months since first sale")
    ax1.set_ylabel("Share of sellers still trading")
    ax1.set_ylim(0, 1)
    ax1.set_title(f"Seller survival (n={len(df):,}, {df['is_censored'].sum():,} censored)")
    ax1.grid(alpha=0.25)

    colors = ["#1F6F8B", "#3E8E7E", "#E0A458", "#B23A48"]
    for q, curve in by_quartile.items():
        ax2.step(curve["t"], curve["survival"], where="post",
                 label=f"GMV quartile {q}" + (" (largest)" if q == 1 else
                                              " (smallest)" if q == 4 else ""),
                 color=colors[q - 1], lw=1.8)
    ax2.set_xlabel("Months since first sale")
    ax2.set_ylabel("Share still trading")
    ax2.set_ylim(0, 1)
    ax2.set_title("Larger sellers survive longer")
    ax2.legend(frameon=False, fontsize=8)
    ax2.grid(alpha=0.25)

    fig.tight_layout()
    chart_path = charts / "seller_survival.png"
    fig.savefig(chart_path, dpi=140)
    plt.close(fig)

    # ---- write-up --------------------------------------------------------
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    out = DOCS_DIR / "seller_survival.md"

    q_rows = []
    for q, curve in by_quartile.items():
        sub = df[df["gmv_quartile"] == q]
        q_rows.append({
            "GMV quartile": f"Q{q}" + (" (largest)" if q == 1 else
                                       " (smallest)" if q == 4 else ""),
            "sellers": len(sub),
            "median GMV": sub["gmv"].median(),
            **{k.replace("survival_", "S("). replace("m", "m)"): v
               for k, v in _curve_table(curve).items()},
            "median survival": median_survival(curve),
        })
    q_table = pd.DataFrame(q_rows)

    med = median_survival(overall)
    med_txt = (f"**{med:.0f} months**" if np.isfinite(med)
               else "**never reached** — more than half of sellers were still "
                    "trading when the window closed")

    lines = [
        "# Seller survival",
        "",
        "Generated by `olist/seller_survival.py`. Kaplan-Meier with Greenwood",
        "log-log confidence bounds, implemented in-module and unit-tested against a",
        "worked example in `olist/tests/test_survival.py`.",
        "",
        "## Why censoring is the whole analysis",
        "",
        f"Of {len(df):,} sellers, **{df['is_censored'].sum():,} ({df['is_censored'].mean():.1%})**",
        "were still trading when the analysis window closed. Their exit was never",
        "observed — we know only that they lasted *at least* as long as we watched.",
        "",
        "The naive approach (mean of last-sale minus first-sale) produces this:",
        "",
        naive_by_age.head(10).to_markdown(index=False, floatfmt=(",.0f", ",.0f", ".3f", ".2f")),
        "",
        f"Naive mean lifespan correlates **{corr:+.3f}** with how many months of window",
        "a cohort had. That is not sellers getting worse over time — it is the ruler",
        "getting shorter. A seller acquired two months before the cut-off cannot show",
        "a lifespan above two months however good they are. Kaplan-Meier removes this",
        "by construction.",
        "",
        "## The survival curve",
        "",
        f"- Median survival: {med_txt}",
        f"- Still trading after 3 months: **{survival_at(overall, 3):.1%}**",
        f"- Still trading after 6 months: **{survival_at(overall, 6):.1%}**",
        f"- Still trading after 12 months: **{survival_at(overall, 12):.1%}**",
        "",
        "The steepest drop is the first step: single-month sellers who list, sell, and",
        "are never seen again. After that the curve flattens markedly — a seller who",
        "survives their first few months tends to keep going, which is the shape that",
        "makes early-tenure intervention worth more than late-tenure retention.",
        "",
        "## Survival by seller size",
        "",
        q_table.to_markdown(index=False, floatfmt=",.3f"),
        "",
        f"Log-rank test, largest quartile vs smallest: χ² = {chi2:,.1f}, p = {p:.3g}.",
        "",
        "The log-rank test is used rather than comparing mean lifespans because it is",
        "the comparison that accounts for censoring; a t-test on observed lifespans",
        "would be testing the window as much as the sellers.",
        "",
        "Causation runs in both directions here and the data cannot separate them: big",
        "sellers survive, and sellers who survive accumulate GMV. The quartiles are",
        "assigned on total GMV over the whole window, so this table should be read as",
        "a description of who lasts, not as evidence that growing a seller's GMV would",
        "make them last.",
        "",
        "## Caveats",
        "",
        "- Churn is defined by observed inactivity, not by deregistration. The dataset",
        "  has no seller-account table, so a seller who stopped selling and one who",
        "  left the platform are indistinguishable.",
        f"- Activity is intermittent (mean density {df['activity_density'].mean():.2f} —",
        "  sellers trade in that share of the months between their first and last sale),",
        "  so a lifespan is a span containing gaps, not continuous trading.",
        "- The window is 20 months. Nothing here speaks to survival beyond that.",
        "",
        "## Chart",
        "",
        "- `outputs/charts/seller_survival.png`",
    ]

    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out}")
    print(f"wrote {chart_path}")
    print(f"\nsellers            {len(df):,}")
    print(f"censored           {df['is_censored'].sum():,} ({df['is_censored'].mean():.1%})")
    print(f"S(3m)/S(6m)/S(12m) {survival_at(overall,3):.1%} / "
          f"{survival_at(overall,6):.1%} / {survival_at(overall,12):.1%}")
    print(f"naive bias corr    {corr:+.3f}")
    print(f"log-rank Q1 vs Q4  chi2={chi2:,.1f} p={p:.3g}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
