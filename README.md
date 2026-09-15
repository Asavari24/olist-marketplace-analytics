# Olist marketplace analytics

A tested dbt + DuckDB warehouse over the [Brazilian E-Commerce Public Dataset by
Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (~100k orders,
2016–2018), plus a Python analysis layer for the statistics SQL cannot do.

The emphasis is on getting the *definitions* right and proving they hold: 25 dbt
models, 118 dbt tests, 40 Python unit tests, and an explicit coverage mart that
counts every row the pipeline excludes.

```bash
./reproduce.sh          # env, data fetch, build, test, analysis, extracts
```

---

## Headline findings

**1. The delivery promise is padded by roughly a factor of two.**
Mean actual delivery is **12.5 days** against a mean promise of **24.7 days** —
orders consume only **51%** of the window they were quoted. The 93.2% on-time rate
is bought with padding, not speed. It is simultaneously a conversion cost: a
checkout quoting 25 days for a parcel that reliably arrives in 12 loses orders it
would have kept.

**2. Carrier transit is both the cost and the risk.**
Decomposing every delivery into payment approval → seller handling → carrier
transit (stages that sum *exactly* to the observed total, enforced by test):

| Stage | Share of time | Share of variance | Excess days when late |
|---|---|---|---|
| Payment approval | 3.4% | 0.7% | +0.1 |
| Seller handling | 22.2% | 13.7% | +3.0 |
| Carrier transit | **74.4%** | **85.6%** | **+19.9** |

Seller handling is slow but *steady* — and flat at ~2.8 days across every distance
band. Carrier transit is what scales with distance and what makes delivery
unpredictable. Squeezing sellers shortens deliveries; only the carrier leg moves
the late rate.

**3. Lateness is what moves the review score — nothing else comes close.**
On-time orders average **4.29 stars**, late orders **2.27**. In a joint model with
category and region fixed effects (n = 94,996, R² = 0.20), a variance partition
gives:

| Block | Incremental R² |
|---|---|
| Delivery | **16.8 – 17.1%** |
| Basket & price | 2.5 – 2.7% |
| Category | 0.4 – 0.7% |
| Geography | 0.0 – 0.2% |

Delivery explains roughly six times everything else combined. The effect is
asymmetric: arriving early buys essentially nothing, arriving late is very costly.

**4. Half of sellers are still trading when the window closes — so naive tenure is meaningless.**
Kaplan-Meier with proper right-censoring puts median seller survival at **11 months**
(62% still trading at 6 months, 46% at 12). The naive last-sale-minus-first-sale
average correlates **+0.98** with how much window a cohort had — it measures the
ruler, not the sellers. Largest vs. smallest GMV quartile separates sharply
(log-rank χ² = 953, p ≈ 10⁻²⁰⁹).

**5. Three quarters of parcels are priced by volume, not weight.**
76% of item lines bill on volumetric weight. A log-log freight model
(R² = 0.54) gives elasticities of 0.20 on weight and 0.10 on distance — the
signature of a tariff dominated by fixed handling cost, which is why small light
parcels carry punishing freight ratios. Within a single weight × distance cell,
identical-looking shipments differ in price by up to **6.1×**, and roughly half
of freight variation is explained by nothing in the dataset.

**6. There is no repeat business to segment.**
**96.9%** of customers bought exactly once; the repeat rate is **3.11%**. Three
alternative explanations are tested and ruled out — wrong customer key, window
truncation (mature cohorts: 5.03%), and a repurchase cycle longer than the window
(median observed gap: 28 days). Meanwhile supply is concentrated: the top decile of
sellers takes **67%** of GMV. A manageable seller base and a customer base that
behaves like search traffic.

---

## Layout

```
data/raw/            the nine source CSVs (gitignored; fetch with olist.download)
dbt_project/
  models/staging/    typing, renaming, and the two review deduplications
  models/intermediate/  zip centroids, delivery decomposition, the order spine
  models/marts/      12 published marts
  tests/             17 singular tests asserting the invariants
olist/               Python analysis layer
outputs/charts/      rendered figures
docs/                generated findings
```

## Marts

| Mart | Grain | What it answers |
|---|---|---|
| `mart_order_fact` | order | The analytical spine; start here |
| `mart_delivery_performance` | dimension × value × month | Late rate and stage times, any slice |
| `mart_delivery_stage_attribution` | stage | Which stage drives duration vs. risk |
| `mart_review_drivers` | driver × bucket | Score distribution per candidate driver |
| `mart_review_driver_ranking` | driver | Drivers ranked by effect size |
| `mart_seller_performance` | seller | Ops, economics, reputation, concentration |
| `mart_category_economics` | category | GMV, freight economics, fulfilment |
| `mart_customer_rfm` | person | RFM (see the caveat on F) |
| `mart_cohort_retention` | cohort × age | The retention triangle |
| `mart_seller_cohorts` | seller | Survival inputs with right-censoring flags |
| `mart_freight_economics` | item line | Freight with billable weight and its drivers |
| `mart_data_coverage` | exclusion | Every row the pipeline drops, and why |

## Decisions worth knowing about

These are the places where the obvious approach gives a wrong number. Each is
documented at length in the model that handles it.

- **`customer_id` is not a customer.** Olist issues a fresh one per order; the
  person key is `customer_unique_id`. 99,441 order keys collapse to 96,096 people.
  Using the wrong one makes the repeat rate exactly zero.
- **The promise is end-of-day.** `order_estimated_delivery_date` is a DATE, so the
  deadline is the *end* of that day. Comparing against midnight moves the late
  rate from 6.77% to 8.11% — a 20% relative overstatement.
- **The review table is unique on neither key.** 789 `review_id`s span several
  orders (a fanned-out survey — scores always agree) and 547 orders carry several
  reviews (a genuine re-survey — 202 disagree). Different causes, different fixes.
- **Delivery stages are made monotonic.** 1,369 orders record checkpoints out of
  sequence. Left alone, the negative durations cancel positive ones inside every
  average. A running maximum makes stages non-negative and exactly additive.
- **Geolocation is a point cloud, not a lookup.** 1,000,163 rows over 19,015 zip
  prefixes. Reduced by median (not mean — one bad geocode drags a mean centroid
  out of the state) after trimming points too far from their own state centroid.
- **Frequency quintiles are meaningless here.** With 96.9% of customers at one
  order, `ntile(5)` over frequency invents five segments out of tie-break order.
  F is scored on its actual distribution instead, and the degeneracy is flagged.
- **The analysis window is 2017-01-01 to 2018-08-31.** 2016 is a 329-order pilot;
  the last 20 orders are right-censored with no delivery recorded.

## Testing

```bash
cd dbt_project && DBT_PROFILES_DIR=$PWD dbt test   # 118 tests
python -m pytest olist/tests -q                    # 40 tests
```

The SQL tests assert the things that would otherwise fail silently: that the
delivery stages sum to the total, that variance contributions sum to 1, that the
spine has not fanned out, that GMV reconciles to item lines, and that the late
rate stays in the band that distinguishes the end-of-day convention from the
midnight one. The Kaplan-Meier estimator is hand-rolled and tested against
worked examples with independently known answers, including the case that
proves a censored seller raises survival rather than lowering it.

## Data

Not committed (126 MB). `python -m olist.download` fetches the nine CSVs and
verifies both byte sizes and parsed row counts against the canonical Kaggle
release, so a mirror that has drifted fails loudly rather than producing
different numbers.

Source data © Olist, released on Kaggle under CC BY-NC-SA 4.0.

## Analyses

| Doc | What it establishes |
|---|---|
| `docs/delivery_findings.md` | Stage attribution, promise padding, bootstrap CIs |
| `docs/review_drivers.md` | OLS / ordered logit / detractor logit, variance partition |
| `docs/customer_findings.md` | Repeat rate, with three alternative explanations ruled out |
| `docs/seller_survival.md` | Kaplan-Meier survival, log-rank by seller size |
| `docs/freight_findings.md` | Log-log pricing model, unexplained spread, route residuals |
| `docs/tableau_dashboard_spec.md` | Five dashboard builds, and what not to compute in Tableau |
| `docs/data_profile.md` | Source profile written before any modelling |

## Status

Warehouse, tests and all five analyses are complete and passing. The dashboard
spec is written but no workbook is built — the repo ships the extracts and the
build instructions, not a `.twbx`.
