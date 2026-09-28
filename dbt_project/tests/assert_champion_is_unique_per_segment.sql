-- mart_forecast_variance joins on model_rank = 1. Two models tying for rank 1
-- would duplicate every variance row for that segment and double-count the
-- investigation worklist.

select grain, segment, measure, horizon, count(*) as n_champions
from {{ ref('mart_forecast_accuracy') }}
where model_rank = 1
group by grain, segment, measure, horizon
having count(*) > 1
