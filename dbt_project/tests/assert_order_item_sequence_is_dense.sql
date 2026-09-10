-- order_item_seq is documented as a dense 1..n sequence within an order.
-- int_order_basket counts items as count(*), which only equals the true
-- quantity if the sequence has no gaps.

select order_id, count(*) as n_lines, max(order_item_seq) as max_seq
from {{ ref('stg_order_items') }}
group by order_id
having count(*) <> max(order_item_seq) or min(order_item_seq) <> 1
