-- Centroids feed route_distance_km, which feeds the distance bands and the
-- review-driver regression. One centroid in the Atlantic produces a
-- 4,000km "route" and a spurious distance effect.

select zip_prefix, lat, lon
from {{ ref('int_zip_centroids') }}
where lat not between {{ var('brazil_lat_min') }} and {{ var('brazil_lat_max') }}
   or lon not between {{ var('brazil_lon_min') }} and {{ var('brazil_lon_max') }}
