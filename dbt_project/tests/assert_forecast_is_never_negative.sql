-- Demand cannot be negative. A damped trend fitted through a declining
-- segment will predict below zero unless clipped, and a negative forecast
-- silently inverts the sign of every variance computed from it.

select grain, segment, measure, model, target_week, forecast
from {{ source('forecast', 'forecast_backtest') }}
where forecast < 0

union all

select grain, segment, measure, model, target_week, forecast
from {{ source('forecast', 'forecast_future') }}
where forecast < 0 or lo80 < 0
