-- Item lines with the product, the seller, and the shipping geography
-- attached. Grain is unchanged: one row per (order_id, order_item_seq).
--
-- This is where the shipping leg becomes measurable. Each line carries its
-- own seller, so a two-seller order has two different origins and two
-- different distances -- which is exactly why distance has to be computed
-- here and aggregated up, not computed once at order level from a single
-- "the" seller that does not exist.

with items as (
    select * from {{ ref('stg_order_items') }}
),

orders as (
    select order_id, customer_id, purchased_at from {{ ref('stg_orders') }}
),

customers as (
    select order_customer_key, customer_zip_prefix, customer_state, customer_region
    from {{ ref('stg_customers') }}
),

sellers as (
    select seller_id, seller_zip_prefix, seller_state, seller_region
    from {{ ref('stg_sellers') }}
),

products as (
    select product_id, category_en, weight_g, volume_litres, photos_qty,
           description_length, dimensions_missing
    from {{ ref('stg_products') }}
),

zips as (
    select zip_prefix, lat, lon from {{ ref('int_zip_centroids') }}
)

select
    i.order_id,
    i.order_item_seq,
    i.product_id,
    i.seller_id,
    o.purchased_at,

    p.category_en,
    p.weight_g,
    p.volume_litres,
    p.photos_qty,
    p.description_length,
    p.dimensions_missing,

    c.customer_state,
    c.customer_region,
    s.seller_state,
    s.seller_region,
    c.customer_state = s.seller_state           as is_intrastate,

    i.item_price,
    i.item_freight,
    i.item_total,

    -- Freight as a share of goods value. The headline number for whether
    -- shipping economics work on a given line: above 1.0 the buyer paid more
    -- to move the thing than the thing cost.
    i.item_freight / nullif(i.item_price, 0)    as freight_to_price_ratio,

    i.shipping_limit_at,

    -- Straight-line origin-to-destination distance. A lower bound on the
    -- distance actually driven -- Brazilian road detour factors run ~1.3-1.4x
    -- -- so it is used as a regressor and never as a cost input.
    {{ haversine_km('sz.lat', 'sz.lon', 'cz.lat', 'cz.lon') }}
                                                as route_distance_km,

    -- 157 of 14,994 customer zip prefixes and 7 of 2,246 seller prefixes have
    -- no geolocation row, so distance is null for those lines. Flagged rather
    -- than zero-filled: a zero distance is a Sao-Paulo-to-Sao-Paulo delivery,
    -- which is the single most common real route in the data and would be
    -- indistinguishable from missing.
    cz.lat is null or sz.lat is null            as geocode_missing

from items i
join orders    o on i.order_id  = o.order_id
join customers c on o.customer_id = c.order_customer_key
left join sellers  s on i.seller_id  = s.seller_id
left join products p on i.product_id = p.product_id
left join zips cz on c.customer_zip_prefix = cz.zip_prefix
left join zips sz on s.seller_zip_prefix   = sz.zip_prefix
