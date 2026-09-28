-- Only weeks lying wholly inside the analysis window may appear. The final
-- week of the raw window holds five days and ~130 orders against ~1,000 in a
-- normal week; included, it reads as a 90% demand collapse and drags every
-- trend estimate and recent backtest origin down with it.

select distinct week_start
from {{ ref('mart_weekly_demand') }}
where week_start < cast('{{ var("analysis_start") }}' as date)
   or week_start + 6 > cast('{{ var("analysis_end") }}' as date)
