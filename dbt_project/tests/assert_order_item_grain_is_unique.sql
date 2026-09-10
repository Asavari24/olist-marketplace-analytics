-- stg_order_items claims grain (order_id, order_item_seq). Every per-order
-- rollup in int_order_basket assumes it.

select order_id, order_item_seq, count(*) as n
from {{ ref('stg_order_items') }}
group by order_id, order_item_seq
having count(*) > 1
