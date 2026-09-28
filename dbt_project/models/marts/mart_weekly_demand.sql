{{ config(tags=['forecast_input']) }}

-- The forecasting input: weekly orders and GMV, zero-filled, at four grains.
--
-- One row per (grain, segment, week). Grains are `total`, `category`,
-- `state` and `category_state`, stacked into one long table so a forecaster
-- can loop over segments without four near-identical queries.
--
-- THREE THINGS THIS MODEL EXISTS TO GET RIGHT.
--
-- 1. ZERO-FILLING. A week in which a segment sold nothing must appear as a
--    zero, not be absent. `group by week` silently drops those weeks, and a
--    model fitted on the surviving rows treats an intermittent series as a
--    dense one -- it never sees the gaps, so it over-forecasts. Viable
--    category x state cells average 16 zero-demand weeks out of 87, so this
--    is most of the signal, not an edge case.
--
-- 2. THE TRUNCATED FINAL WEEK. analysis_end is Friday 2018-08-31, so the week
--    beginning 2018-08-27 contains five days and 130 orders against ~1,000 in
--    a normal week. It is not a demand collapse, it is the window ending
--    mid-week. Included, it drags down every trend estimate and poisons the
--    most recent (and most heavily weighted) backtest origins. Weeks are kept
--    only where all seven days fall inside the analysis window.
--
-- 3. THE VOLUME GATE. Of 1,391 category x state cells only ~170 carry enough
--    history to forecast. The rest are published with is_forecastable = false
--    rather than dropped, so the coverage question ("what share of GMV do we
--    actually forecast?") stays answerable from this table.
--
-- Week starts Monday (DuckDB date_trunc convention).

with orders as (
    select
        order_id,
        purchase_date,
        cast(date_trunc('week', purchased_at) as date)  as week_start,
        coalesce(primary_category, 'uncategorized')     as category,
        customer_state,
        coalesce(gmv, 0)                                as gmv,
        coalesce(n_items, 0)                            as items
    from {{ ref('mart_order_fact') }}
),

-- Only weeks lying wholly inside the analysis window.
complete_weeks as (
    select distinct week_start
    from orders
    where week_start >= cast('{{ var("analysis_start") }}' as date)
      and week_start + 6 <= cast('{{ var("analysis_end") }}' as date)
),

-- Long-format observations at all four grains.
observed as (
    select 'total'          as grain, 'ALL'                          as segment,
           week_start, order_id, gmv, items from orders
    union all
    select 'category',      category,
           week_start, order_id, gmv, items from orders
    union all
    select 'state',         customer_state,
           week_start, order_id, gmv, items from orders
    union all
    select 'category_state', category || ' | ' || customer_state,
           week_start, order_id, gmv, items from orders
),

agg as (
    select
        o.grain,
        o.segment,
        o.week_start,
        count(*)            as orders,
        sum(o.gmv)          as gmv,
        sum(o.items)        as items
    from observed o
    join complete_weeks w on o.week_start = w.week_start
    group by o.grain, o.segment, o.week_start
),

-- Segment-level totals, used for the volume gate and for the MASE scale.
segment_totals as (
    select
        grain,
        segment,
        sum(orders)                 as total_orders,
        sum(gmv)                    as total_gmv,
        count(*)                    as weeks_present,
        min(week_start)             as first_week,
        max(week_start)             as last_week
    from agg
    group by grain, segment
),

-- The zero-fill: every gated segment crossed with every complete week.
spine as (
    select s.grain, s.segment, w.week_start
    from segment_totals s
    cross join complete_weeks w
)

select
    sp.grain,
    sp.segment,
    sp.week_start,
    -- Week index, so a model does not have to reconstruct time ordering.
    dense_rank() over (order by sp.week_start)              as week_index,

    coalesce(a.orders, 0)                                   as orders,
    coalesce(a.gmv, 0)                                      as gmv,
    coalesce(a.items, 0)                                    as items,
    a.order_id_present is null                              as is_zero_week,

    st.total_orders                                         as segment_total_orders,
    st.total_gmv                                            as segment_total_gmv,
    st.weeks_present                                        as segment_weeks_present,
    st.first_week                                           as segment_first_week,

    -- Published for every segment; only the gated ones are forecast.
    st.total_orders >= {{ var('forecast_min_total_orders') }}
        and st.weeks_present >= {{ var('forecast_min_weeks_present') }}
                                                            as is_forecastable,

    -- Black Friday 2017 fell on 24 November. It is the largest week in the
    -- series by some margin and it happens exactly once, so no model here can
    -- learn it. Flagged so the backtest can report accuracy with and without
    -- it rather than quietly averaging a one-off into the error.
    sp.week_start between date '2017-11-20' and date '2017-11-27'
                                                            as is_black_friday_window,

    cast('{{ var("analysis_start") }}' as date)             as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)             as analysis_end

from spine sp
join segment_totals st
  on sp.grain = st.grain and sp.segment = st.segment
left join (
    select grain, segment, week_start, orders, gmv, items,
           1 as order_id_present
    from agg
) a
  on sp.grain = a.grain and sp.segment = a.segment and sp.week_start = a.week_start
