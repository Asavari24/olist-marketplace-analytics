-- What this warehouse does NOT cover. One row per exclusion or gap.
--
-- Every mart in this project is filtered, deduplicated or restricted
-- somewhere. This table is where each of those decisions is counted, so the
-- caveats are queryable rather than living only in model comments and a
-- README nobody reads before quoting a number.
--
-- If a figure from any mart is going into a deck, the matching row here is
-- the footnote.

with raw_orders as (
    select * from {{ ref('stg_orders') }}
),
spine as (
    select * from {{ ref('int_order_spine') }}
),
raw_reviews as (
    select count(*) as n from {{ source('olist_raw', 'olist_order_reviews_dataset') }}
),
raw_geo as (
    select count(*) as n from {{ source('olist_raw', 'olist_geolocation_dataset') }}
)

select * from (
    values

    ('window',      'orders in raw extract',
     (select count(*) from raw_orders),
     'All orders in the source, 2016-09-04 to 2018-10-17.'),

    ('window',      'orders excluded: before analysis_start',
     (select count(*) from raw_orders where purchased_at < cast('{{ var("analysis_start") }}' as timestamp)),
     'Sep-Dec 2016 pilot traffic, 283 of it in one week. Too sparse to trend.'),

    ('window',      'orders excluded: after analysis_end',
     (select count(*) from raw_orders where purchased_at >= cast('{{ var("analysis_end") }}' as timestamp) + interval 1 day),
     'Right-censored: none of these had recorded a delivery when the snapshot was cut, so their on-time rate is undefined, not good.'),

    ('window',      'orders in analysis window',
     (select count(*) from spine),
     'The denominator for every mart in this project.'),

    ('delivery',    'orders with a delivery outcome',
     (select count(*) from spine where has_delivery_outcome),
     'status = delivered AND a delivery timestamp exists. The only rows on which late rate is defined.'),

    ('delivery',    'orders without a delivery outcome',
     (select count(*) from spine where not has_delivery_outcome),
     'shipped / canceled / unavailable / processing. Excluded from delivery rates, NOT counted as on-time.'),

    ('delivery',    'delivered orders with clamped stage order',
     (select count(*) from spine where stage_order_clamped),
     'Raw timestamps out of sequence (mostly carrier handover before payment approval). Stages made monotonic; see int_order_delivery_timeline.'),

    ('delivery',    'delivered orders missing an approval timestamp',
     (select count(*) from spine where approval_ts_missing),
     'Approval time carried forward from purchase, giving that stage zero duration.'),

    ('basket',      'orders with no item lines',
     (select count(*) from spine where basket_missing),
     'Almost all unavailable/canceled. GMV, freight and category are null for these; they are retained so cancellation rates stay correct.'),

    ('geography',   'orders with an unresolvable geocode',
     (select count(*) from spine where any_geocode_missing),
     'Customer or seller zip prefix absent from the geolocation file. route_distance_km is null, never zero-filled.'),

    ('geography',   'geolocation points dropped as out of range',
     (select (select n from raw_geo) - (select count(*) from {{ ref('stg_geolocation') }})),
     'Outside Brazil bounding box. A further slice is dropped per-state in int_zip_centroids.'),

    ('reviews',     'orders never reviewed',
     (select count(*) from spine where not was_reviewed),
     'Non-response. Small here (~0.8%) but skewed toward undelivered orders, so review means are mildly optimistic.'),

    ('reviews',     'raw review rows collapsed in dedup',
     (select (select n from raw_reviews) - (select count(*) from {{ ref('stg_order_reviews') }})),
     'Raw survey table is unique on neither review_id nor order_id. Resolved to one row per order, latest response wins.'),

    ('reviews',     'orders re-surveyed with disagreeing scores',
     (select count(*) from spine where resurvey_scores_disagree),
     'Two reviews, different scores. Latest kept; excluding them entirely is a robustness check in olist/review_drivers.py.'),

    ('customers',   'distinct persons',
     (select count(distinct person_key) from spine),
     'customer_unique_id. The per-order customer_id would give 99,092 and a repeat rate of exactly zero.'),

    ('customers',   'persons who ordered more than once',
     (select count(*) from (select person_key from spine group by 1 having count(*) > 1)),
     'The entire basis for every retention number in this project. 3.11% of persons.')

) as t(area, metric, n_orders, note)
