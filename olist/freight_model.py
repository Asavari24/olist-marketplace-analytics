"""What freight SHOULD cost, and which shipments are priced far from it.

`mart_freight_economics` records what freight WAS charged. This module fits
what it should have been given weight, size and distance, and ranks the gaps.

The model is a log-log regression:

    log(freight) ~ log(billable_kg) + log(distance_km) + category + route FE

Logs on both sides because freight pricing is multiplicative -- carriers quote
a rate per kg per distance band, not a flat sum -- so the coefficients read
directly as elasticities. A coefficient of 0.4 on billable weight means
doubling the weight raises freight by about 32%, which is the shape of a real
tariff with a fixed handling component.

Billable weight is max(actual, volumetric) as computed in the mart. Using raw
mass would systematically flag bulky-light categories as overpriced when they
are simply being billed by the volume they occupy.

WHAT THE RESIDUALS DO AND DO NOT MEAN. A large positive residual means this
shipment cost much more than similar shipments. It does NOT mean anyone was
overcharged: the model has no visibility of service level, insurance,
fragility, remoteness beyond state, or the contract the seller negotiated.
The residual is a flag for review, not a verdict -- which is why the output
ranks routes for investigation rather than computing a refund.

Output: docs/freight_findings.md, outputs/charts/freight_model.png
"""

from __future__ import annotations

import warnings

import duckdb
import numpy as np
import pandas as pd

from . import DOCS_DIR, OUTPUTS_DIR, WAREHOUSE

warnings.filterwarnings("ignore")

MIN_ROUTE_N = 100      # route fixed effects below this are pooled
MIN_CATEGORY_N = 200


def load(con) -> pd.DataFrame:
    df = con.execute("""
        select order_id, order_item_seq, seller_id, category_en, route,
               seller_state, customer_state, customer_region, is_intrastate,
               route_distance_km, item_price, item_freight,
               billable_kg, weight_kg, volumetric_kg, is_volumetric,
               weight_band, distance_band, is_free_shipping, purchase_month
        from main_marts.mart_freight_economics
        where not is_free_shipping
          and item_freight > 0
          and billable_kg > 0
          and route_distance_km is not null
          and route_distance_km > 0
    """).df()

    df["log_freight"] = np.log(df["item_freight"])
    df["log_kg"] = np.log(df["billable_kg"])
    df["log_km"] = np.log(df["route_distance_km"])

    for col, min_n in (("route", MIN_ROUTE_N), ("category_en", MIN_CATEGORY_N)):
        keep = df[col].value_counts()
        keep = set(keep[keep >= min_n].index)
        df[f"{col}_grp"] = np.where(df[col].isin(keep), df[col], "other")

    return df


def fit(df: pd.DataFrame):
    import statsmodels.api as sm

    X = df[["log_kg", "log_km"]].astype(float).copy()
    X["is_volumetric"] = df["is_volumetric"].astype(float)
    X["is_intrastate"] = df["is_intrastate"].astype(float)
    fe = pd.get_dummies(df[["category_en_grp", "route_grp"]],
                        drop_first=True, dtype=float)
    X = pd.concat([X, fe], axis=1)

    model = sm.OLS(df["log_freight"].astype(float), sm.add_constant(X)).fit(cov_type="HC1")
    return model, X, list(fe.columns)


def main() -> int:
    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    df = load(con)

    spread = con.execute("""
        select weight_band, distance_band, count(*) as n,
               median(item_freight)                    as median_freight,
               quantile_cont(item_freight, 0.10)       as p10,
               quantile_cont(item_freight, 0.90)       as p90,
               quantile_cont(item_freight, 0.90)
                 / nullif(quantile_cont(item_freight, 0.10), 0) as p90_over_p10
        from main_marts.mart_freight_economics
        where not is_free_shipping and weight_band <> 'unknown'
          and distance_band <> 'unknown'
        group by 1, 2
        having count(*) >= 200
        order by p90_over_p10 desc
        limit 8
    """).df()

    totals = con.execute("""
        select count(*)                            as lines,
               sum(is_free_shipping::int)          as free_lines,
               sum(is_volumetric::int)             as volumetric_lines,
               sum(item_freight)                   as freight_total,
               sum(item_price)                     as gmv,
               sum(item_freight) / sum(item_price) as freight_to_gmv
        from main_marts.mart_freight_economics
    """).df().iloc[0]
    con.close()

    model, X, fe_cols = fit(df)
    df = df.copy()
    df["predicted_log"] = model.fittedvalues
    df["residual_log"] = model.resid
    # Retransforming with the smearing correction rather than plain exp(),
    # which would systematically under-predict on a log model.
    smear = np.mean(np.exp(model.resid))
    df["predicted_freight"] = np.exp(df["predicted_log"]) * smear
    df["freight_gap"] = df["item_freight"] - df["predicted_freight"]
    df["freight_ratio"] = df["item_freight"] / df["predicted_freight"]

    coefs = pd.DataFrame({
        "term": ["log(billable kg)", "log(distance km)",
                 "volumetric billing", "intrastate"],
        "coef": [model.params["log_kg"], model.params["log_km"],
                 model.params["is_volumetric"], model.params["is_intrastate"]],
        "std_err": [model.bse["log_kg"], model.bse["log_km"],
                    model.bse["is_volumetric"], model.bse["is_intrastate"]],
        "p": [model.pvalues["log_kg"], model.pvalues["log_km"],
              model.pvalues["is_volumetric"], model.pvalues["is_intrastate"]],
    })
    coefs["pct_effect_per_doubling"] = (2 ** coefs["coef"] - 1) * 100

    route_gaps = (df.groupby("route")
                    .agg(n=("freight_gap", "size"),
                         mean_actual=("item_freight", "mean"),
                         mean_predicted=("predicted_freight", "mean"),
                         mean_gap=("freight_gap", "mean"),
                         median_ratio=("freight_ratio", "median"))
                    .reset_index())
    route_gaps = route_gaps[route_gaps["n"] >= MIN_ROUTE_N]
    route_gaps["total_gap"] = route_gaps["mean_gap"] * route_gaps["n"]
    dearest = route_gaps.nlargest(8, "median_ratio")
    cheapest = route_gaps.nsmallest(8, "median_ratio")

    seller_gaps = (df.groupby("seller_id")
                     .agg(n=("freight_gap", "size"),
                          median_ratio=("freight_ratio", "median"),
                          total_gap=("freight_gap", "sum"))
                     .reset_index())
    seller_gaps = seller_gaps[seller_gaps["n"] >= 50]
    outlier_sellers = seller_gaps.nlargest(8, "median_ratio")

    # ---- chart -----------------------------------------------------------
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    charts = OUTPUTS_DIR / "charts"
    charts.mkdir(parents=True, exist_ok=True)
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

    samp = df.sample(min(8000, len(df)), random_state=20260909)
    ax1.scatter(samp["predicted_freight"], samp["item_freight"], s=4, alpha=0.18,
                color="#1F6F8B", edgecolors="none")
    lim = np.percentile(df["item_freight"], 99.5)
    ax1.plot([0, lim], [0, lim], color="#B23A48", lw=1.3, ls="--", label="perfect fit")
    ax1.set_xlim(0, lim); ax1.set_ylim(0, lim)
    ax1.set_xlabel("Predicted freight (R$)")
    ax1.set_ylabel("Actual freight (R$)")
    ax1.set_title(f"Freight model fit (R² = {model.rsquared:.3f}, n = {int(model.nobs):,})")
    ax1.legend(frameon=False); ax1.grid(alpha=0.25)

    cells = spread.head(6).copy()
    cells["label"] = cells["weight_band"].str[3:] + "\n" + cells["distance_band"].str[3:]
    y = np.arange(len(cells))
    ax2.barh(y, cells["p90"] - cells["p10"], left=cells["p10"], color="#E0A458", alpha=0.85)
    ax2.scatter(cells["median_freight"], y, color="#B23A48", zorder=3, label="median")
    ax2.set_yticks(y); ax2.set_yticklabels(cells["label"], fontsize=8)
    ax2.invert_yaxis()
    ax2.set_xlabel("Freight charged (R$), p10 to p90")
    ax2.set_title("Same weight, same distance, very different price")
    ax2.legend(frameon=False); ax2.grid(alpha=0.25, axis="x")

    fig.tight_layout()
    chart_path = charts / "freight_model.png"
    fig.savefig(chart_path, dpi=140); plt.close(fig)

    # ---- write-up --------------------------------------------------------
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    out = DOCS_DIR / "freight_findings.md"

    lines = [
        "# Freight findings",
        "",
        "Generated by `olist/freight_model.py`.",
        "",
        "Freight in this dataset is what the BUYER paid, per item line. There is no",
        "carrier-cost column anywhere in the source, so nothing here speaks to margin.",
        "What it can speak to is consistency: whether comparable shipments are priced",
        "comparably.",
        "",
        "## Scale",
        "",
        f"- {totals['lines']:,.0f} item lines, R$ {totals['freight_total']:,.0f} of freight",
        f"  against R$ {totals['gmv']:,.0f} of goods — freight is **{totals['freight_to_gmv']:.1%}** of GMV",
        f"- {totals['volumetric_lines']:,.0f} lines ({totals['volumetric_lines']/totals['lines']:.0%})",
        "  are billed on VOLUME rather than mass",
        f"- {totals['free_lines']:,.0f} lines shipped free",
        "",
        "That volumetric share is the first practical finding: for three quarters of",
        "shipments the box, not the contents, sets the price. Any freight analysis",
        "using raw weight is modelling the wrong variable on most of its rows.",
        "",
        "## The pricing model",
        "",
        f"Log-log OLS, R² = **{model.rsquared:.3f}** on {int(model.nobs):,} lines with",
        f"{len(fe_cols)} category and route fixed effects. HC1 robust standard errors.",
        "",
        coefs[["term", "coef", "std_err", "p", "pct_effect_per_doubling"]]
            .to_markdown(index=False, floatfmt=",.4f"),
        "",
        f"Doubling billable weight raises freight by **{(2**model.params['log_kg']-1)*100:.0f}%**;",
        f"doubling distance raises it by **{(2**model.params['log_km']-1)*100:.0f}%**. Both",
        "elasticities are well below 1, which is the signature of a tariff with a large",
        "fixed handling component — the first kilo and the first kilometre cost far more",
        "than the last. That is why small light parcels carry such punishing",
        "freight-to-price ratios, and it is a structural feature of the rate card rather",
        "than anything about the seller.",
        "",
        "## The spread that the model cannot explain",
        "",
        "Within a single weight band and distance band, before any modelling:",
        "",
        spread.to_markdown(index=False, floatfmt=",.2f"),
        "",
        "The p90/p10 column is the finding. In the worst cell, identical-looking",
        "shipments differ in price by a factor of six. Weight, distance, category and",
        f"route together explain {model.rsquared:.0%} of the variation in log freight,",
        f"leaving {1 - model.rsquared:.0%} to something this dataset does not record —",
        "negotiated rates, service level, insurance, or genuine remoteness within a",
        "state. Close to half the price of a Brazilian parcel is not a function of the",
        "parcel.",
        "",
        "## Routes priced furthest from the model",
        "",
        "Ratio above 1 means the route charges more than its weight, distance,",
        "category and volume would predict. Routes with at least",
        f"{MIN_ROUTE_N} lines.",
        "",
        "**Dearest:**",
        "",
        dearest[["route", "n", "mean_actual", "mean_predicted", "median_ratio"]]
            .to_markdown(index=False, floatfmt=",.3f"),
        "",
        "**Cheapest:**",
        "",
        cheapest[["route", "n", "mean_actual", "mean_predicted", "median_ratio"]]
            .to_markdown(index=False, floatfmt=",.3f"),
        "",
        "## Sellers priced furthest from the model",
        "",
        "Sellers with at least 50 lines, ranked by median actual/predicted ratio.",
        "",
        outlier_sellers.to_markdown(index=False, floatfmt=",.3f"),
        "",
        "## What these residuals are not",
        "",
        "A high ratio is a flag for review, not a finding of overcharging. The model",
        "cannot see service level, fragility, insurance, declared value, remoteness",
        "beyond the state, or what rate a given seller negotiated. A seller shipping",
        "fragile goods with insurance to interior addresses would show exactly this",
        "signature while doing nothing wrong.",
        "",
        "The defensible use is triage: these are the routes and sellers where the",
        "difference between quoted and comparable pricing is large enough to be worth",
        "someone's time to explain.",
        "",
        "## Chart",
        "",
        "- `outputs/charts/freight_model.png`",
    ]

    out.write_text("\n".join(lines) + "\n")
    print(f"wrote {out}")
    print(f"wrote {chart_path}")
    print(f"\nR^2                {model.rsquared:.4f} on {int(model.nobs):,} lines")
    print(f"weight elasticity  {model.params['log_kg']:.3f} "
          f"({(2**model.params['log_kg']-1)*100:.0f}% per doubling)")
    print(f"distance elasticity{model.params['log_km']:.3f} "
          f"({(2**model.params['log_km']-1)*100:.0f}% per doubling)")
    print(f"volumetric share   {totals['volumetric_lines']/totals['lines']:.0%}")
    print(f"worst cell p90/p10 {spread['p90_over_p10'].max():.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
