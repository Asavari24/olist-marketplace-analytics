{{ config(tags=['forecast']) }}

-- Forecast versus actuals, week by week, with the variance triaged.
--
-- This is the table you sit in front of on a Monday to answer "what missed
-- last week and does it matter". One row per (grain, segment, measure,
-- target week) for the CHAMPION model of that segment, which is the model
-- with the lowest backtest MAE at that horizon.
--
-- Using the per-segment champion rather than one global model is the point.
-- On this data the best model genuinely differs by segment -- an eight-week
-- average wins on total orders, a four-week average on total GMV, and small
-- intermittent category x state cells are often best served by plain naive.
-- Forcing one model everywhere would manufacture variance that is an artefact
-- of model choice and send someone to investigate it.
--
-- TRIAGE, WHICH IS THE WHOLE POINT OF THE TABLE.
--
-- A variance report that flags everything flags nothing. Two filters are
-- applied before a row is worth a human's time:
--
--   MATERIALITY. The absolute miss must be large enough to matter. A
--   category that forecast 3 orders and got 6 is 100% out and completely
--   uninteresting; `is_material` requires the miss to clear an absolute floor
--   as well as a percentage.
--
--   NORMALITY. The miss must be large relative to how wrong this segment
--   USUALLY is. A segment whose backtest MAE is 400 orders missing by 380 is
--   behaving exactly as expected. `variance_vs_typical_error` is the miss
--   divided by that segment's own backtest MAE, so a value near 1 is a normal
--   week and 3+ is genuinely anomalous. This is the column that separates a
--   forecast problem from a business event.
--
-- `needs_investigation` requires both, plus a direction, so the output is a
-- short worklist rather than a wall.

with champion as (
    -- Lowest backtest MAE per segment and horizon.
    select grain, segment, measure, horizon, model, mae as champion_mae, mape, bias
    from {{ ref('mart_forecast_accuracy') }}
    where model_rank = 1
),

joined as (
    select
        b.grain,
        b.segment,
        b.measure,
        b.model,
        b.horizon,
        b.origin_week,
        b.target_week,
        b.actual,
        b.forecast,
        coalesce(b.is_black_friday_window, false)       as is_black_friday,
        c.champion_mae
    from {{ source('forecast', 'forecast_backtest') }} b
    join champion c
      on  b.grain = c.grain and b.segment = c.segment
      and b.measure = c.measure and b.horizon = c.horizon
      and b.model = c.model
),

scored as (
    select
        *,
        forecast - actual                               as variance_abs,
        case when actual > 0
             then (forecast - actual) / actual * 100 end as variance_pct,
        abs(forecast - actual) / nullif(champion_mae, 0)
                                                        as variance_vs_typical_error,
        case when forecast > actual then 'over-forecast'
             when forecast < actual then 'under-forecast'
             else 'exact' end                           as variance_direction
    from joined
),

-- The materiality floor is the segment's own median weekly actual, so it
-- scales with the segment instead of needing a hand-set threshold per series.
floors as (
    select grain, segment, measure, median(actual) as median_actual
    from {{ source('forecast', 'forecast_backtest') }}
    group by grain, segment, measure
)

select
    s.grain,
    s.segment,
    s.measure,
    s.model                                             as champion_model,
    s.horizon,
    s.origin_week,
    s.target_week,

    s.actual,
    s.forecast,
    s.variance_abs,
    s.variance_pct,
    s.variance_direction,
    s.champion_mae,
    s.variance_vs_typical_error,
    f.median_actual,

    s.is_black_friday,

    -- Material: the miss is big in absolute terms relative to the segment's
    -- own typical week, not merely big in percentage terms.
    abs(s.variance_abs) >= greatest(0.25 * f.median_actual, 1)
                                                        as is_material,

    -- Anomalous: the miss is large relative to how wrong this segment
    -- normally is.
    s.variance_vs_typical_error >= 3.0                  as is_anomalous,

    abs(s.variance_abs) >= greatest(0.25 * f.median_actual, 1)
        and s.variance_vs_typical_error >= 3.0
        and not coalesce(s.is_black_friday, false)      as needs_investigation,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from scored s
join floors f
  on s.grain = f.grain and s.segment = f.segment and s.measure = f.measure
