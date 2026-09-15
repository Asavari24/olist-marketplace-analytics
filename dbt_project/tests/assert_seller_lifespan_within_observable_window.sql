-- A seller cannot have traded for longer than the window allowed them to.
-- If this fails the cohort arithmetic is wrong, and every Kaplan-Meier curve
-- built on lifespan_months is wrong with it.

select seller_id, cohort_month, lifespan_months, observable_months
from {{ ref('mart_seller_cohorts') }}
where lifespan_months > observable_months
   or lifespan_months < 1
