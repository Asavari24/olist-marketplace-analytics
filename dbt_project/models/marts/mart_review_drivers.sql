-- What moves the review score. A long table: one row per
-- (driver, bucket), each carrying the score distribution within that bucket.
--
-- The design point is that all candidate drivers are measured the SAME way on
-- the SAME population, so their effect sizes are directly comparable. The
-- usual version of this analysis reports a correlation for lateness and a
-- bar chart for category and leaves the reader to guess which matters more.
--
-- Effect size here is the spread in mean score across a driver's buckets,
-- computed in mart_review_driver_ranking. The regression that controls for
-- all of them jointly lives in olist/review_drivers.py -- SQL can rank
-- marginal effects but cannot separate correlated ones, and lateness,
-- distance and freight are heavily correlated in this data.
--
-- NON-RESPONSE. 99.2% of in-window orders were reviewed, which is unusually
-- high and means selection bias is small -- but it is not zero, and it is not
-- random: unreviewed orders skew undelivered. Rows here are restricted to
-- reviewed orders and mart_data_coverage reports who is missing.

with base as (
    select *
    from {{ ref('mart_order_fact') }}
    where was_reviewed
),

{% set drivers = [
    ('lateness_band',      'lateness_band'),
    ('delivery_days_band', "case when not has_delivery_outcome then 'no outcome'
                                 when total_delivery_days <  5 then '01 under 5d'
                                 when total_delivery_days < 10 then '02 5-10d'
                                 when total_delivery_days < 20 then '03 10-20d'
                                 when total_delivery_days < 40 then '04 20-40d'
                                 else                               '05 40d+' end"),
    ('seller_sla',         "case when seller_missed_dispatch_sla then 'missed dispatch SLA'
                                 when seller_missed_dispatch_sla is null then 'unknown'
                                 else 'met dispatch SLA' end"),
    ('gmv_band',           'gmv_band'),
    ('distance_band',      'distance_band'),
    ('freight_ratio_band', "case when freight_to_price_ratio is null then 'unknown'
                                 when freight_to_price_ratio < 0.10 then '01 under 10%'
                                 when freight_to_price_ratio < 0.25 then '02 10-25%'
                                 when freight_to_price_ratio < 0.50 then '03 25-50%'
                                 when freight_to_price_ratio < 1.00 then '04 50-100%'
                                 else                                    '05 over 100%' end"),
    ('order_status',       'order_status'),
    ('multi_seller',       "case when is_multi_seller then 'multi-seller' else 'single seller' end"),
    ('installments',       "case when max_installments is null then 'unknown'
                                 when max_installments <= 1 then '01 single payment'
                                 when max_installments <= 3 then '02 2-3x'
                                 when max_installments <= 6 then '03 4-6x'
                                 else                             '04 7x+' end"),
    ('payment_type',       "coalesce(primary_payment_type, 'unknown')"),
    ('customer_region',    'customer_region'),
    ('primary_category',   "coalesce(primary_category, 'no items')")
] %}

stacked as (
    {% for driver_name, driver_expr in drivers %}
    select
        '{{ driver_name }}'                     as driver,
        cast({{ driver_expr }} as varchar)      as bucket,
        review_score,
        is_detractor,
        is_promoter,
        has_comment_text
    from base
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select
    driver,
    bucket,
    count(*)                                                as n_reviews,
    count(*)::double / sum(count(*)) over (partition by driver)
                                                            as share_of_reviews,

    avg(review_score)                                       as mean_score,
    median(review_score)                                    as median_score,
    stddev_samp(review_score)                               as stddev_score,

    avg(is_detractor::int)                                  as detractor_rate,
    avg(is_promoter::int)                                   as promoter_rate,
    -- NPS-style net, on the 1-5 survey: promoters (5) minus detractors (1-2).
    avg(is_promoter::int) - avg(is_detractor::int)          as net_promoter_gap,

    -- Leaving a written comment is itself a signal of strong feeling, and it
    -- is far more common on bad orders than good ones.
    avg(has_comment_text::int)                              as comment_rate,

    -- Lift against the overall mean for this driver, so buckets are readable
    -- without holding the base rate in your head.
    avg(review_score)
        - (sum(sum(review_score)) over (partition by driver)
           / sum(count(*)) over (partition by driver))      as score_vs_driver_mean,

    count(*) < 30                                           as suppress_small_n,
    cast('{{ var("analysis_start") }}' as date)             as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)             as analysis_end

from stacked
group by driver, bucket
