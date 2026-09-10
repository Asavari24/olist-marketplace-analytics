-- Turns 1,000,163 scattered points into one usable coordinate per zip prefix.
--
-- Two problems have to be solved together:
--
--   Reduction. ~53 points per prefix. The MEDIAN is used rather than the
--   mean, because a single mis-geocoded point 2,000km away drags a mean
--   centroid clean out of the state while barely moving a median.
--
--   Bad geocodes. Beyond the 31 points already outside Brazil's bounding box,
--   there are points inside Brazil but in the wrong state entirely. These are
--   caught by comparing each point to its own state's centroid and dropping
--   anything further than `max_zip_from_state_km`. The state centroid is
--   itself a median, so it is not moved by the outliers it is used to detect.
--
-- 8 zip prefixes appear under more than one state in the raw file. Dropping
-- the out-of-state points resolves 6 of them outright; the modal state wins
-- for the remaining 2 and the ambiguity is flagged rather than hidden.
--
-- Net: 19,015 raw prefixes -> 18,932 with a usable centroid, averaging 52.7
-- surviving points each.

with state_centroids as (
    select
        state,
        median(lat) as state_lat,
        median(lon) as state_lon
    from {{ ref('stg_geolocation') }}
    group by state
),

points_scored as (
    select
        g.zip_prefix,
        g.lat,
        g.lon,
        g.state,
        g.city,
        {{ haversine_km('g.lat', 'g.lon', 's.state_lat', 's.state_lon') }} as km_from_state_centroid
    from {{ ref('stg_geolocation') }} g
    join state_centroids s on g.state = s.state
),

clean_points as (
    select *
    from points_scored
    where km_from_state_centroid <= {{ var('max_zip_from_state_km') }}
),

-- Modal state per prefix, for the 8 prefixes that straddle a border.
state_vote as (
    select
        zip_prefix,
        state,
        count(*)                                                         as n_points,
        row_number() over (partition by zip_prefix order by count(*) desc, state) as rk,
        count(*) over (partition by zip_prefix)                          as n_states
    from clean_points
    group by zip_prefix, state
),

modal_state as (
    select zip_prefix, state as modal_state, n_states > 1 as state_is_ambiguous
    from state_vote
    where rk = 1
)

select
    c.zip_prefix,
    median(c.lat)                       as lat,
    median(c.lon)                       as lon,
    m.modal_state                       as state,
    m.state_is_ambiguous,
    count(*)                            as n_points,
    -- Spread of the surviving points. A prefix whose points scatter over tens
    -- of kilometres gives a centroid that is a weak proxy for any one
    -- address, which matters when the distance is used as a regressor.
    max(c.km_from_state_centroid) - min(c.km_from_state_centroid)
                                        as point_spread_km
from clean_points c
join modal_state m on c.zip_prefix = m.zip_prefix
group by c.zip_prefix, m.modal_state, m.state_is_ambiguous
