-- Delivery performance as a long, sliceable table: one row per
-- (grain, dimension value, month), so a single table answers "late rate by
-- state", "by region", "by distance band" and "by route" without four
-- near-identical marts.
--
-- Every row carries n, so a 40% late rate on five orders in Roraima is
-- visibly not the same claim as 6% on forty thousand in Sao Paulo. The
-- suppression flag marks rows too thin to quote.
--
-- The stage means on each row are the point of the table: they say WHERE the
-- time went for that slice, not merely how much of it there was.

{% set dimensions = [
    ('customer_state',   'customer_state'),
    ('customer_region',  'customer_region'),
    ('distance_band',    'distance_band'),
    ('gmv_band',         'gmv_band'),
    ('primary_category', 'primary_category'),
    ('payment_type',     'primary_payment_type'),
    ('route',            "customer_region || ' <- ' || coalesce(primary_seller_state, 'unknown')")
] %}

with delivered as (
    select * from {{ ref('mart_order_fact') }}
    where has_delivery_outcome
),

unpivoted as (
    {% for dim_name, dim_expr in dimensions %}
    select
        '{{ dim_name }}'                as dimension,
        cast({{ dim_expr }} as varchar) as dimension_value,
        purchase_month,
        *
    from delivered
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select
    dimension,
    dimension_value,
    purchase_month,

    count(*)                                                as n_orders,

    -- ---- the outcome -----------------------------------------------------
    avg(is_late::int)                                       as late_rate,
    avg(case when lateness_days > 7 then 1 else 0 end)      as severely_late_rate,
    -- Mean lateness over LATE orders only. Averaging signed lateness over all
    -- orders returns a large negative number (the padding) and reads as if
    -- delivery were early rather than as a failure magnitude.
    avg(case when is_late then lateness_days end)           as mean_lateness_days_when_late,
    max(lateness_days)                                      as worst_lateness_days,

    -- ---- where the time went --------------------------------------------
    avg(total_delivery_days)                                as mean_total_days,
    median(total_delivery_days)                             as median_total_days,
    avg(payment_approval_days)                              as mean_payment_approval_days,
    avg(seller_handling_days)                               as mean_seller_handling_days,
    avg(carrier_transit_days)                               as mean_carrier_transit_days,

    -- Stage shares. These sum to 1 by construction because the stages sum to
    -- the total; that identity is what makes the comparison across slices
    -- legitimate.
    sum(payment_approval_days) / nullif(sum(total_delivery_days), 0)
                                                            as share_payment_approval,
    sum(seller_handling_days)  / nullif(sum(total_delivery_days), 0)
                                                            as share_seller_handling,
    sum(carrier_transit_days)  / nullif(sum(total_delivery_days), 0)
                                                            as share_carrier_transit,

    -- ---- the promise -----------------------------------------------------
    avg(promised_days)                                      as mean_promised_days,
    avg(promise_slack_days)                                 as mean_slack_days,
    avg(promise_utilisation)                                as mean_promise_utilisation,

    -- ---- attributable seller failure -------------------------------------
    avg(seller_missed_dispatch_sla::int)                    as seller_sla_miss_rate,

    -- ---- satisfaction ----------------------------------------------------
    avg(review_score)                                       as mean_review_score,
    avg(is_detractor::int)                                  as detractor_rate,

    -- ---- distance --------------------------------------------------------
    avg(route_distance_km)                                  as mean_route_distance_km,

    -- ---- reliability -----------------------------------------------------
    count(*) < 30                                           as suppress_small_n,
    avg(stage_order_clamped::int)                           as clamped_share,
    cast('{{ var("analysis_start") }}' as date)             as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)             as analysis_end

from unpivoted
group by dimension, dimension_value, purchase_month
