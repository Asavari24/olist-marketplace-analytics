-- churn_event is the Kaplan-Meier event indicator and must be the exact
-- complement of is_censored. Any drift between them silently turns censored
-- sellers into observed exits and biases every survival curve downward.

select seller_id, is_censored, churn_event, months_silent_at_window_end
from {{ ref('mart_seller_cohorts') }}
where churn_event <> (case when is_censored then 0 else 1 end)
   or is_censored <> (months_silent_at_window_end <= {{ var('seller_censor_months') }})
