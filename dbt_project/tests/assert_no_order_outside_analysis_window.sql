-- Every mart inherits its window from int_order_spine. If an out-of-window
-- order leaks through, the censored September 2018 tail re-enters the
-- on-time rate as an undelivered order and biases it.

select order_id, purchased_at
from {{ ref('int_order_spine') }}
where purchased_at <  cast('{{ var("analysis_start") }}' as timestamp)
   or purchased_at >= cast('{{ var("analysis_end") }}' as timestamp) + interval 1 day
