-- Every retention and RFM number keys on person_key. A null one would form
-- a silent mega-cohort of unrelated customers.

select order_id from {{ ref('int_order_spine') }} where person_key is null
