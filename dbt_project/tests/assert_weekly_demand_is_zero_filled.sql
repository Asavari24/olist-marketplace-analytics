-- Every segment must have a row for every week in the spine. A missing row is
-- an invisible gap: a model fitted on the surviving rows treats an
-- intermittent series as a dense one and over-forecasts.

with weeks as (select count(distinct week_start) as n from {{ ref('mart_weekly_demand') }})
select grain, segment, count(*) as rows_present, (select n from weeks) as weeks_expected
from {{ ref('mart_weekly_demand') }}
group by grain, segment
having count(*) <> (select n from weeks)
