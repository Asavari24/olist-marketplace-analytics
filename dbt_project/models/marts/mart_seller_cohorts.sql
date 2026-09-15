-- One row per seller: acquisition cohort, observed lifespan, and whether the
-- exit was actually observed or the window simply ended.
--
-- This is the input to the Kaplan-Meier curves in olist/seller_survival.py,
-- and the censoring column is the entire reason it is a separate model rather
-- than a couple of extra columns on mart_seller_performance.
--
-- WHY CENSORING IS THE WHOLE PROBLEM.
--
-- The obvious way to measure seller lifespan is last_sale minus first_sale.
-- On a 20-month window that is wrong in a specific, directional way: a seller
-- acquired in July 2018 can show a lifespan of at most two months no matter
-- how good they are, because there is no more window left. Averaging observed
-- lifespans therefore reports that recent cohorts are worse than old ones
-- when the only thing that differs is how long anyone was watching.
--
-- The fix is to treat sellers still trading at the edge of the window as
-- right-censored: we know they lasted AT LEAST this long, not that they
-- stopped. Kaplan-Meier consumes exactly that distinction. Every survival
-- number in this project rests on the `is_censored` column below.
--
-- Note this is an OBSERVED-ACTIVITY definition of churn, not a contractual
-- one. The dataset has no seller-account table, so a seller who stopped
-- selling and a seller who deregistered are indistinguishable here.

with seller_months as (
    select
        i.seller_id,
        o.purchase_month,
        count(distinct i.order_id)                      as orders,
        sum(i.item_price)                               as gmv
    from {{ ref('int_order_items_enriched') }} i
    join {{ ref('mart_order_fact') }} o on i.order_id = o.order_id
    group by i.seller_id, o.purchase_month
),

bounds as (
    select
        cast(date_trunc('month', cast('{{ var("analysis_end") }}' as date)) as date)
            as last_window_month
),

per_seller as (
    select
        sm.seller_id,
        min(sm.purchase_month)                          as cohort_month,
        max(sm.purchase_month)                          as last_active_month,
        count(distinct sm.purchase_month)               as active_months,
        sum(sm.orders)                                  as orders,
        sum(sm.gmv)                                     as gmv,

        -- Months from first sale to last sale, inclusive of both endpoints,
        -- so a seller who traded in exactly one month has a lifespan of 1
        -- rather than 0. A zero would be indistinguishable from a seller who
        -- never traded at all, and would collapse the first survival step.
        date_diff('month', min(sm.purchase_month), max(sm.purchase_month)) + 1
                                                        as lifespan_months,

        -- How much window was left after this seller joined. The maximum
        -- lifespan they could possibly have shown.
        date_diff('month', min(sm.purchase_month), b.last_window_month) + 1
                                                        as observable_months,

        -- Gap between last sale and the window closing.
        date_diff('month', max(sm.purchase_month), b.last_window_month)
                                                        as months_silent_at_window_end
    from seller_months sm
    cross join bounds b
    group by sm.seller_id, b.last_window_month
)

select
    p.seller_id,
    s.seller_state,
    s.seller_region,

    p.cohort_month,
    p.last_active_month,
    p.active_months,
    p.lifespan_months,
    p.observable_months,
    p.months_silent_at_window_end,

    p.orders,
    p.gmv,
    p.gmv / nullif(p.active_months, 0)                  as gmv_per_active_month,

    -- Intermittency. A seller active in 3 of 12 months between first and last
    -- sale is a different animal from one active in 12 of 12, and pooling
    -- them makes the survival curve describe neither.
    p.active_months::double / nullif(p.lifespan_months, 0)
                                                        as activity_density,

    -- ---- the survival inputs ------------------------------------------
    -- Still trading when the window closed: we know they lasted at least
    -- this long and nothing more.
    p.months_silent_at_window_end <= {{ var('seller_censor_months') }}
                                                        as is_censored,
    -- The Kaplan-Meier event indicator: 1 = observed exit, 0 = censored.
    case when p.months_silent_at_window_end <= {{ var('seller_censor_months') }}
         then 0 else 1 end                              as churn_event,

    ntile(4) over (order by p.gmv desc, p.seller_id)    as gmv_quartile,
    p.gmv >= 10000                                      as is_major_seller,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from per_seller p
left join {{ ref('stg_sellers') }} s on p.seller_id = s.seller_id
