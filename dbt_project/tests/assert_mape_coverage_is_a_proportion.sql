-- mape_coverage is the share of scored points where MAPE was computable.
-- Outside [0,1] means the zero-actual handling is wrong, which would make
-- every MAPE in the mart describe an unknown subset of the data.

select grain, segment, measure, model, horizon, mape_coverage, n_points
from {{ ref('mart_forecast_accuracy') }}
where mape_coverage < 0 or mape_coverage > 1
   or (mape_coverage = 0 and mape is not null)
