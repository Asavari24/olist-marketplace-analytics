-- The cardinal sin of backtesting: a forecast informed by data it could not
-- have seen. Every target week must be strictly after its origin week, and
-- within the declared horizon of it. If this fails the accuracy mart is
-- reporting hindsight, which looks like an excellent model.

select grain, segment, measure, model, origin_week, target_week, horizon
from {{ source('forecast', 'forecast_backtest') }}
where target_week <= origin_week
   or date_diff('week', origin_week, target_week) <> horizon
   or horizon > {{ var('forecast_horizon_weeks') }}
