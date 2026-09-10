-- Any rate column outside [0,1] means a denominator went wrong somewhere.
-- Cheap to assert across the marts that publish rates.

select 'mart_delivery_performance' as model, dimension || '/' || dimension_value as key, late_rate as value
from {{ ref('mart_delivery_performance') }}
where late_rate not between 0 and 1

union all
select 'mart_delivery_performance', dimension || '/' || dimension_value, seller_sla_miss_rate
from {{ ref('mart_delivery_performance') }}
where seller_sla_miss_rate not between 0 and 1

union all
select 'mart_review_drivers', driver || '/' || bucket, detractor_rate
from {{ ref('mart_review_drivers') }}
where detractor_rate not between 0 and 1

union all
select 'mart_seller_performance', seller_id, late_rate
from {{ ref('mart_seller_performance') }}
where late_rate not between 0 and 1

union all
select 'mart_cohort_retention', cast(cohort_month as varchar) || '/' || cast(months_since_first as varchar), retention_rate
from {{ ref('mart_cohort_retention') }}
where retention_rate not between 0 and 1
