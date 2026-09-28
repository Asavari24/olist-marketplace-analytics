{{ config(tags=['forecast']) }}

-- Backtest accuracy: one row per (grain, segment, measure, model, horizon).
--
-- Every metric a forecasting review actually asks for, computed in SQL where
-- it can be tested, rather than in the Python that produced the forecasts.
-- The split is deliberate: Python does the part SQL cannot (refitting models
-- in a loop, optimising a damped trend), and SQL does the scoring, which is
-- arithmetic over a table and therefore belongs somewhere reviewable.
--
-- HOW TO READ THE ERROR COLUMNS, in the order they should be read.
--
--   rel_mae_vs_naive  The direct question: did this model beat the benchmark?
--                     Model MAE over naive MAE on the IDENTICAL scored points.
--                     Below 1 beats naive. This is the column to sort on.
--
--   mase              Scale-free, so it can be averaged across segments of
--                     wildly different size. Note these are 1-4 step
--                     forecasts scored against a 1-step naive benchmark, so
--                     values above 1 are normal and do NOT mean "worse than
--                     naive" -- that is what rel_mae_vs_naive is for.
--
--   mape              Reported because it is what gets asked for, and
--                     qualified because it misleads on this data. It is
--                     undefined where the actual is zero, so `mape_coverage`
--                     records the share of points it could be computed on;
--                     a MAPE over 80% coverage is a different claim from one
--                     over 100%. It also explodes on small actuals and is
--                     asymmetric, punishing over-forecasts more lightly than
--                     under-forecasts.
--
--   bias / mpe        Signed. POSITIVE MEANS OVER-FORECASTING. This is the
--                     column that matters operationally: a model with
--                     excellent MAE and a consistent negative bias is
--                     quietly under-buying stock every single week, and no
--                     absolute-error metric will ever show it.
--
-- Black Friday 2017 is excluded from the headline metrics and scored
-- separately in `mape_excluding_black_friday`, because it occurs once in the
-- series and no model here can predict a yearly event from one observation.
-- Averaging that week into the error describes the calendar, not the model.

with scored as (
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
        b.mase_scale,
        coalesce(b.is_black_friday_window, false)       as is_black_friday,

        b.forecast - b.actual                           as error,
        abs(b.forecast - b.actual)                      as abs_error,
        abs(b.forecast - b.actual) / nullif(b.mase_scale, 0)
                                                        as abs_scaled_error,
        case when b.actual > 0
             then abs(b.forecast - b.actual) / b.actual * 100 end
                                                        as abs_pct_error,
        case when b.actual > 0
             then (b.forecast - b.actual) / b.actual * 100 end
                                                        as pct_error,
        -- Symmetric MAPE: defined wherever either side is non-zero, so it
        -- survives the zero-demand weeks that make plain MAPE undefined.
        case when (abs(b.actual) + abs(b.forecast)) > 0
             then 2 * abs(b.forecast - b.actual)
                  / (abs(b.actual) + abs(b.forecast)) * 100 end
                                                        as sym_pct_error
    from {{ source('forecast', 'forecast_backtest') }} b
),

agg as (
    select
        grain, segment, measure, model, horizon,

        count(*)                                        as n_points,
        min(target_week)                                as first_target_week,
        max(target_week)                                as last_target_week,

        avg(abs_error)                                  as mae,
        sqrt(avg(pow(error, 2)))                        as rmse,
        avg(abs_scaled_error)                           as mase,

        avg(abs_pct_error)                              as mape,
        avg(sym_pct_error)                              as smape,
        count(abs_pct_error)::double / nullif(count(*), 0)
                                                        as mape_coverage,

        avg(error)                                      as bias,
        avg(pct_error)                                  as mpe,
        -- Share of weeks the model came in high. At 0.5 the model is
        -- unbiased in direction; persistent departures from 0.5 are what a
        -- planner feels even when MAE looks fine.
        avg(case when error > 0 then 1.0 else 0.0 end)  as over_forecast_rate,

        avg(case when not is_black_friday then abs_pct_error end)
                                                        as mape_excluding_black_friday,
        avg(case when is_black_friday then abs_pct_error end)
                                                        as mape_black_friday_only

    from scored
    group by grain, segment, measure, model, horizon
),

naive_baseline as (
    select grain, segment, measure, horizon, mae as naive_mae
    from agg
    where model = 'naive'
)

select
    a.grain,
    a.segment,
    a.measure,
    a.model,
    a.horizon,
    a.n_points,
    a.first_target_week,
    a.last_target_week,

    a.mae,
    a.rmse,
    a.mase,
    a.mape,
    a.smape,
    a.mape_coverage,
    a.bias,
    a.mpe,
    a.over_forecast_rate,
    a.mape_excluding_black_friday,
    a.mape_black_friday_only,

    a.mae / nullif(n.naive_mae, 0)                      as rel_mae_vs_naive,
    a.mae < n.naive_mae                                 as beats_naive,

    -- Rank within the segment, so the champion is readable off one column.
    row_number() over (
        partition by a.grain, a.segment, a.measure, a.horizon
        order by a.mae
    )                                                   as model_rank,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from agg a
left join naive_baseline n
       on a.grain = n.grain and a.segment = n.segment
      and a.measure = n.measure and a.horizon = n.horizon
