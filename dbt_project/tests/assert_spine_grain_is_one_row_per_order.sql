-- int_order_spine LEFT joins four tables. If any of them is not unique on
-- order_id the spine fans out and every count, sum and rate in every mart is
-- silently multiplied.

select order_id, count(*) as n
from {{ ref('int_order_spine') }}
group by order_id
having count(*) > 1
