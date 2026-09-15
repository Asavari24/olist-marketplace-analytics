-- mart_freight_economics must preserve item-line grain and total freight.
-- A fan-out here would inflate every freight-per-kg figure in the model.

with from_items as (
    select sum(i.item_freight) as freight, count(*) as lines
    from {{ ref('int_order_items_enriched') }} i
    join {{ ref('mart_order_fact') }} o on i.order_id = o.order_id
),
from_mart as (
    select sum(item_freight) as freight, count(*) as lines
    from {{ ref('mart_freight_economics') }}
)
select m.freight, i.freight as expected_freight, m.lines, i.lines as expected_lines
from from_mart m cross join from_items i
where abs(m.freight - i.freight) > 0.01 or m.lines <> i.lines
