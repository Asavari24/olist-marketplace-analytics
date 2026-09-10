"""Delivery findings: stage attribution, the promise padding, and charts.

The dbt marts compute the numbers. This module does the two things they
cannot: attach uncertainty to them, and render them.

Bootstrap confidence intervals are used rather than normal-theory ones
because the quantities of interest -- a late rate of 6.8%, a mean lateness
conditional on being late -- are either bounded proportions or means of a
hard right-skewed distribution, and neither is well served by +/- 1.96 SE.

Output: docs/delivery_findings.md, outputs/charts/*.png
"""

from __future__ import annotations

import duckdb
import numpy as np
import pandas as pd

from . import DOCS_DIR, OUTPUTS_DIR, WAREHOUSE

RNG_SEED = 20260909
N_BOOT = 2000


def bootstrap_ci(values: np.ndarray, stat=np.mean, n_boot: int = N_BOOT,
                 alpha: float = 0.05, seed: int = RNG_SEED) -> tuple[float, float, float]:
    """Percentile bootstrap CI. Returns (point, low, high)."""
    rng = np.random.default_rng(seed)
    values = np.asarray(values, dtype=float)
    values = values[~np.isnan(values)]
    if len(values) == 0:
        return (np.nan, np.nan, np.nan)
    idx = rng.integers(0, len(values), size=(n_boot, len(values)))
    draws = stat(values[idx], axis=1)
    return (float(stat(values)),
            float(np.percentile(draws, 100 * alpha / 2)),
            float(np.percentile(draws, 100 * (1 - alpha / 2))))


def load(con) -> pd.DataFrame:
    return con.execute("""
        select purchase_month, customer_region, customer_state, distance_band,
               is_late::int as is_late, lateness_days, total_delivery_days,
               promised_days, promise_slack_days, promise_utilisation,
               payment_approval_days, seller_handling_days, carrier_transit_days,
               review_score, is_detractor::int as is_detractor, was_reviewed,
               route_distance_km, gmv, freight_total
        from main_marts.mart_order_fact
        where has_delivery_outcome
    """).df()


def make_charts(df: pd.DataFrame, attribution: pd.DataFrame) -> list[str]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    charts_dir = OUTPUTS_DIR / "charts"
    charts_dir.mkdir(parents=True, exist_ok=True)
    written = []

    # --- 1. Promise vs actual, by month -------------------------------------
    monthly = df.groupby("purchase_month").agg(
        actual=("total_delivery_days", "mean"),
        promised=("promised_days", "mean"),
        late_rate=("is_late", "mean"),
        n=("is_late", "size"),
    ).reset_index()

    fig, ax1 = plt.subplots(figsize=(11, 5))
    ax1.plot(monthly["purchase_month"], monthly["promised"], marker="o",
             label="Promised (estimate shown at checkout)", color="#B23A48")
    ax1.plot(monthly["purchase_month"], monthly["actual"], marker="o",
             label="Actual delivery time", color="#1F6F8B")
    ax1.fill_between(monthly["purchase_month"], monthly["actual"], monthly["promised"],
                     alpha=0.15, color="#B23A48", label="Padding")
    ax1.set_ylabel("Days from purchase")
    ax1.set_xlabel("Purchase month")
    ax1.set_title("Olist promises roughly twice the delivery time it needs")
    ax1.legend(loc="upper right", frameon=False)
    ax1.grid(alpha=0.25)
    fig.autofmt_xdate()
    fig.tight_layout()
    p = charts_dir / "promise_vs_actual.png"
    fig.savefig(p, dpi=140); plt.close(fig); written.append(str(p))

    # --- 2. Stage attribution: time vs risk ---------------------------------
    fig, ax = plt.subplots(figsize=(9, 5))
    x = np.arange(len(attribution))
    w = 0.38
    ax.bar(x - w/2, attribution["share_of_mean_days"], w,
           label="Share of average delivery time", color="#1F6F8B")
    ax.bar(x + w/2, attribution["variance_contribution"], w,
           label="Share of variance (unpredictability)", color="#E0A458")
    ax.set_xticks(x)
    ax.set_xticklabels([s.replace("_", "\n") for s in attribution["stage"]])
    ax.set_ylabel("Share")
    ax.set_title("Carrier transit dominates both duration and risk")
    ax.legend(frameon=False)
    ax.grid(alpha=0.25, axis="y")
    fig.tight_layout()
    p = charts_dir / "stage_attribution.png"
    fig.savefig(p, dpi=140); plt.close(fig); written.append(str(p))

    # --- 3. Review score against lateness -----------------------------------
    band = df[df["was_reviewed"]].copy()
    band["bucket"] = pd.cut(
        band["lateness_days"],
        bins=[-np.inf, -10, -5, 0, 3, 7, 21, np.inf],
        labels=["10d+ early", "5-10d early", "0-5d early",
                "0-3d late", "3-7d late", "7-21d late", "21d+ late"],
    )
    g = band.groupby("bucket", observed=True).agg(
        mean_score=("review_score", "mean"),
        detractor=("is_detractor", "mean"),
        n=("review_score", "size"),
    ).reset_index()

    fig, ax1 = plt.subplots(figsize=(10, 5))
    ax1.bar(g["bucket"].astype(str), g["mean_score"], color="#1F6F8B")
    ax1.set_ylabel("Mean review score", color="#1F6F8B")
    ax1.set_ylim(1, 5)
    ax2 = ax1.twinx()
    ax2.plot(g["bucket"].astype(str), 100 * g["detractor"], marker="o", color="#B23A48")
    ax2.set_ylabel("1-2 star reviews (%)", color="#B23A48")
    ax1.set_title("Lateness collapses the review score; being early buys nothing")
    for i, n in enumerate(g["n"]):
        ax1.text(i, 1.06, f"n={n:,}", ha="center", fontsize=7, color="#444")
    fig.autofmt_xdate(rotation=25)
    fig.tight_layout()
    p = charts_dir / "review_vs_lateness.png"
    fig.savefig(p, dpi=140); plt.close(fig); written.append(str(p))

    # --- 4. Late rate by distance and region --------------------------------
    piv = (df.groupby(["customer_region", "distance_band"])["is_late"]
             .agg(["mean", "size"]).reset_index())
    piv = piv[piv["size"] >= 30]
    table = piv.pivot(index="customer_region", columns="distance_band", values="mean")

    fig, ax = plt.subplots(figsize=(10, 4.5))
    im = ax.imshow(table.values * 100, cmap="YlOrRd", aspect="auto")
    ax.set_xticks(range(len(table.columns)))
    ax.set_xticklabels(table.columns, rotation=25, ha="right")
    ax.set_yticks(range(len(table.index)))
    ax.set_yticklabels(table.index)
    for i in range(table.shape[0]):
        for j in range(table.shape[1]):
            v = table.values[i, j]
            if not np.isnan(v):
                ax.text(j, i, f"{v*100:.1f}", ha="center", va="center", fontsize=8)
    ax.set_title("Late rate (%) by region and distance, cells with n≥30")
    fig.colorbar(im, ax=ax, label="Late rate (%)")
    fig.tight_layout()
    p = charts_dir / "late_rate_heatmap.png"
    fig.savefig(p, dpi=140); plt.close(fig); written.append(str(p))

    return written


def main() -> int:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    df = load(con)
    attribution = con.execute(
        "select * from main_marts.mart_delivery_stage_attribution"
    ).df()
    coverage = con.execute("select * from main_marts.mart_data_coverage").df()
    con.close()

    late_pt, late_lo, late_hi = bootstrap_ci(df["is_late"].values)
    late_only = df.loc[df["is_late"] == 1, "lateness_days"].values
    mag_pt, mag_lo, mag_hi = bootstrap_ci(late_only)
    slack_pt, slack_lo, slack_hi = bootstrap_ci(df["promise_slack_days"].values)

    scored = df[df["was_reviewed"]]
    on_time_score = scored.loc[scored["is_late"] == 0, "review_score"].mean()
    late_score = scored.loc[scored["is_late"] == 1, "review_score"].mean()

    charts = make_charts(df, attribution)

    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    out = DOCS_DIR / "delivery_findings.md"

    att = attribution[["stage", "mean_days", "share_of_mean_days",
                       "variance_contribution", "excess_days_when_late"]].copy()
    att.columns = ["Stage", "Mean days", "Share of time", "Share of variance",
                   "Excess days when late"]

    lines = [
        "# Delivery findings",
        "",
        "Generated by `olist/delivery_analysis.py`. Confidence intervals are",
        f"percentile bootstrap, {N_BOOT:,} resamples, seed {RNG_SEED}.",
        f"Population: {len(df):,} delivered in-window orders.",
        "",
        "## 1. The promise is padded by about a factor of two",
        "",
        f"- Mean actual delivery: **{df['total_delivery_days'].mean():.2f} days**",
        f"- Mean promised: **{df['promised_days'].mean():.2f} days**",
        f"- Mean slack: **{slack_pt:.2f} days** (95% CI {slack_lo:.2f} to {slack_hi:.2f})",
        f"- Orders use only **{df['promise_utilisation'].mean():.1%}** of their promised window on average",
        "",
        "This is the single largest structural fact in the delivery data, and it cuts",
        "both ways. The 93.2% on-time rate is mostly bought with padding rather than",
        "speed -- so it is not evidence of a fast network. But the padding is also a",
        "conversion cost: a checkout quoting 25 days when the parcel reliably arrives",
        "in 12 is losing orders it would have kept.",
        "",
        "## 2. Late rate",
        "",
        f"- Late rate: **{late_pt:.2%}** (95% CI {late_lo:.2%} to {late_hi:.2%})",
        f"- When an order is late it is late by **{mag_pt:.1f} days** on average "
        f"(95% CI {mag_lo:.1f} to {mag_hi:.1f})",
        "",
        "The magnitude is the part that matters. A 6.8% failure rate sounds survivable;",
        "a failure that averages nine days past a promise already padded by twelve does",
        "not. Lateness here is not a near-miss distribution.",
        "",
        "## 3. Where the time goes, and where the risk goes",
        "",
        att.to_markdown(index=False, floatfmt=",.4f"),
        "",
        "Share of variance is `cov(stage, total) / var(total)`, which sums to exactly 1",
        "because the stages sum to the total -- enforced by",
        "`tests/assert_variance_contributions_sum_to_one.sql`.",
        "",
        "The two shares tell different stories and the gap between them is the finding.",
        "Seller handling is a fifth of the average delivery but only an eighth of the",
        "variance: it is slow and steady. Carrier transit is three quarters of the time",
        "and six sevenths of the variance -- it is both the biggest cost and essentially",
        "all of the unpredictability. Squeezing seller handling shortens deliveries;",
        "only the carrier leg moves the late rate.",
        "",
        "## 4. Lateness is what moves the review score",
        "",
        f"- On-time orders average **{on_time_score:.2f}** stars",
        f"- Late orders average **{late_score:.2f}** stars",
        f"- A drop of **{on_time_score - late_score:.2f}** stars",
        "",
        "The relationship is strongly asymmetric, which the chart makes obvious:",
        "arriving early buys almost nothing, arriving late costs a great deal. See",
        "`docs/review_drivers.md` for the joint model that holds price, distance,",
        "freight and category constant and finds the same thing.",
        "",
        "## 5. Charts",
        "",
    ] + [f"- `{c.split('olist_analytics/')[-1]}`" for c in charts] + [
        "",
        "## 6. Coverage and exclusions",
        "",
        coverage[["area", "metric", "n_orders"]].to_markdown(index=False),
        "",
        "Full notes on each exclusion are in `main_marts.mart_data_coverage`.",
    ]

    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out}")
    for c in charts:
        print(f"wrote {c}")

    print(f"\nlate rate      {late_pt:.2%}  [{late_lo:.2%}, {late_hi:.2%}]")
    print(f"mean slack     {slack_pt:.2f}d  [{slack_lo:.2f}, {slack_hi:.2f}]")
    print(f"score gap      {on_time_score - late_score:.2f} stars")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
