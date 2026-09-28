-- Every segment that passed the volume gate must appear in the backtest. A
-- segment that silently fell out of the Python loop would leave the accuracy
-- mart looking complete while covering less of the business than it claims.

with gated as (
    select distinct grain, segment
    from {{ ref('mart_weekly_demand') }}
    where is_forecastable
),
scored as (
    select distinct grain, segment
    from {{ source('forecast', 'forecast_backtest') }}
)
select g.grain, g.segment
from gated g
left join scored s on g.grain = s.grain and g.segment = s.segment
where s.segment is null
