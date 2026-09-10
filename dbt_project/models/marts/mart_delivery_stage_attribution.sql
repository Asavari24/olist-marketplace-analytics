-- Which stage actually drives late delivery? One row per stage.
--
-- Three different questions get three different columns, because they have
-- three different answers and conflating them is how "the carrier is the
-- problem" becomes received wisdom without evidence:
--
--   share_of_mean_days     How much of a typical delivery is this stage?
--                          Answered by the mean. Biggest stage wins by
--                          construction -- says nothing about failure.
--
--   variance_contribution  How much of the VARIATION between orders does
--                          this stage explain? cov(stage, total)/var(total).
--                          Because total is exactly the sum of the stages,
--                          these contributions sum to exactly 1 -- an
--                          identity, not an approximation, which is why this
--                          is a decomposition and not a set of loose
--                          correlations. This is the column that says which
--                          stage makes deliveries unpredictable.
--
--   excess_days_when_late  How many more days does this stage take on a late
--                          order than on an on-time one? The operational
--                          number: the days you would recover by fixing this
--                          stage alone.
--
-- A stage can be large and steady (contributes to duration, not to risk) or
-- small and wild (the reverse). Reading only the first column is the mistake
-- this mart exists to prevent.

with delivered as (
    select
        payment_approval_days,
        seller_handling_days,
        carrier_transit_days,
        total_delivery_days,
        lateness_days,
        is_late
    from {{ ref('mart_order_fact') }}
    where has_delivery_outcome
),

overall as (
    select
        count(*)                        as n_orders,
        avg(total_delivery_days)        as mean_total_days,
        var_samp(total_delivery_days)   as var_total_days,
        avg(is_late::int)               as late_rate
    from delivered
),

{% set stages = [
    ('payment_approval', 'payment_approval_days'),
    ('seller_handling',  'seller_handling_days'),
    ('carrier_transit',  'carrier_transit_days')
] %}

stacked as (
    {% for stage_name, stage_col in stages %}
    select
        '{{ stage_name }}'                                          as stage,
        {{ loop.index }}                                            as stage_order,
        avg({{ stage_col }})                                        as mean_days,
        median({{ stage_col }})                                     as median_days,
        stddev_samp({{ stage_col }})                                as stddev_days,
        quantile_cont({{ stage_col }}, 0.95)                        as p95_days,

        covar_samp({{ stage_col }}, total_delivery_days)            as cov_with_total,
        corr({{ stage_col }}, lateness_days)                        as corr_with_lateness,

        avg(case when is_late     then {{ stage_col }} end)         as mean_days_when_late,
        avg(case when not is_late then {{ stage_col }} end)         as mean_days_when_on_time
    from delivered
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select
    s.stage,
    o.n_orders,
    o.late_rate,

    s.mean_days,
    s.median_days,
    s.stddev_days,
    s.p95_days,

    s.mean_days / nullif(o.mean_total_days, 0)          as share_of_mean_days,
    s.cov_with_total / nullif(o.var_total_days, 0)      as variance_contribution,
    s.corr_with_lateness,

    s.mean_days_when_late,
    s.mean_days_when_on_time,
    s.mean_days_when_late - s.mean_days_when_on_time    as excess_days_when_late,

    o.mean_total_days,
    o.var_total_days,
    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from stacked s
cross join overall o
order by s.stage_order
