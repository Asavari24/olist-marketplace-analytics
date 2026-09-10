-- Geocoded points keyed by zip prefix. One million rows, ~19,015 distinct
-- prefixes -- so roughly 53 points per prefix, and this is emphatically NOT a
-- lookup table yet. int_zip_centroids does the reduction.
--
-- Only the obviously-impossible points are removed here: 31 rows sit outside
-- Brazil's bounding box entirely (they land in the Atlantic or in other
-- continents). Everything subtler -- a point in the right country but the
-- wrong state -- is left in place and handled statistically downstream, where
-- the decision is visible rather than buried in a staging filter.

select
    geolocation_zip_code_prefix                     as zip_prefix,
    cast(geolocation_lat as double)                 as lat,
    cast(geolocation_lng as double)                 as lon,
    lower(trim(geolocation_city))                   as city,
    upper(trim(geolocation_state))                  as state

from {{ source('olist_raw', 'olist_geolocation_dataset') }}
where cast(geolocation_lat as double) between {{ var('brazil_lat_min') }} and {{ var('brazil_lat_max') }}
  and cast(geolocation_lng as double) between {{ var('brazil_lon_min') }} and {{ var('brazil_lon_max') }}
