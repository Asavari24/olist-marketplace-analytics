-- Order GMV in the spine must equal the sum of its own item lines. Guards
-- against a fan-out in int_order_basket's payments join, which would
-- multiply GMV by the number of payment instruments -- the single easiest
-- way to overstate revenue in this schema.

with from_items as (
    select order_id, sum(item_price) as gmv_items
    from {{ ref('int_order_items_enriched') }}
    group by order_id
)
select s.order_id, s.gmv, i.gmv_items
from {{ ref('int_order_spine') }} s
join from_items i on s.order_id = i.order_id
where abs(s.gmv - i.gmv_items) > 0.01
