-- Billable weight must be the greater of actual mass and volumetric weight.
-- Invert it and every bulky-light category is flagged as overpriced by the
-- freight model when it is simply being billed by the space it occupies --
-- which is 76% of lines in this dataset.

select order_id, order_item_seq, weight_kg, volumetric_kg, billable_kg
from {{ ref('mart_freight_economics') }}
where billable_kg + 1e-9 < greatest(coalesce(weight_kg, 0), coalesce(volumetric_kg, 0))
