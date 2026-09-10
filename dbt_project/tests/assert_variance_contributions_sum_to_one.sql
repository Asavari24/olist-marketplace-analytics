-- The attribution mart's central claim is that its variance contributions
-- are an exact decomposition. Assert it rather than trusting the algebra.

select sum(variance_contribution) as total_contribution
from {{ ref('mart_delivery_stage_attribution') }}
having abs(sum(variance_contribution) - 1.0) > 1e-9
