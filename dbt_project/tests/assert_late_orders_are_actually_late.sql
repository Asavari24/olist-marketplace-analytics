-- is_late must agree with the timestamps it is derived from, including the
-- end-of-day promise convention. This is the off-by-one that inflates the
-- late rate by 20% relative if the deadline is taken as midnight.

select order_id, delivered_at, promise_deadline_at, is_late, lateness_days
from {{ ref('int_order_delivery_timeline') }}
where is_late <> (delivered_at > promise_deadline_at)
   or (is_late and lateness_days <= 0)
   or (not is_late and lateness_days > 0)
