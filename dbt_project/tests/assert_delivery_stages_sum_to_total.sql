-- The decomposition identity. If the three stages do not add up to the
-- observed total, mart_delivery_stage_attribution is not a decomposition and
-- its variance contributions will not sum to 1 -- the whole attribution
-- argument collapses. Tolerance is floating-point noise on an epoch
-- subtraction, nothing more.

select
    order_id,
    payment_approval_days + seller_handling_days + carrier_transit_days as sum_stages,
    total_delivery_days
from {{ ref('int_order_delivery_timeline') }}
where abs(
        payment_approval_days + seller_handling_days + carrier_transit_days
        - total_delivery_days
      ) > 1e-6
