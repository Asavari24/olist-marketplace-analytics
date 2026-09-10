-- Monotonicity enforcement actually worked. A negative stage means the
-- running-maximum in int_order_delivery_timeline failed, and negative
-- durations silently cancel positive ones inside every avg() downstream.

select order_id, payment_approval_days, seller_handling_days, carrier_transit_days
from {{ ref('int_order_delivery_timeline') }}
where payment_approval_days < 0
   or seller_handling_days  < 0
   or carrier_transit_days  < 0
