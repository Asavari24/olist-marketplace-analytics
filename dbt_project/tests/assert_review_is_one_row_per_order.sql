-- The raw survey table is unique on neither review_id nor order_id.
-- stg_order_reviews exists to resolve that; if it has not, the spine fans out.

select order_id, count(*) as n
from {{ ref('stg_order_reviews') }}
group by order_id
having count(*) > 1
