-- One row per product category. Where the money is, what it costs to ship,
-- and whether shipping it makes customers unhappy.
--
-- Item-level again, for the same reason as the seller mart: a mixed-category
-- order belongs partly to each category, and assigning it wholly to the
-- largest line inflates big categories at the expense of small ones.
--
-- The column worth reading first is freight_to_price_ratio. Olist's freight
-- is charged to the buyer, so a high ratio is not a margin problem for the
-- marketplace -- it is a conversion and satisfaction problem, and the
-- detractor_rate column next to it is where that shows up.

with items as (
    select
        i.category_en,
        i.order_id,
        i.item_price,
        i.item_freight,
        i.weight_g,
        i.volume_litres,
        i.route_distance_km,
        i.photos_qty,
        i.description_length,
        o.purchase_month,
        o.has_delivery_outcome,
        o.is_late,
        o.total_delivery_days,
        o.seller_handling_days,
        o.carrier_transit_days,
        o.was_reviewed,
        o.review_score,
        o.is_detractor,
        i.seller_id
    from {{ ref('int_order_items_enriched') }} i
    join {{ ref('mart_order_fact') }} o on i.order_id = o.order_id
)

select
    category_en                                         as category,

    -- ---- scale -----------------------------------------------------------
    count(*)                                            as n_items,
    count(distinct order_id)                            as n_orders,
    count(distinct seller_id)                           as n_sellers,
    sum(item_price)                                     as gmv,
    sum(item_price) / nullif(sum(sum(item_price)) over (), 0)
                                                        as gmv_share,
    avg(item_price)                                     as mean_price,
    median(item_price)                                  as median_price,

    -- ---- shipping economics ----------------------------------------------
    sum(item_freight)                                   as freight_total,
    avg(item_freight)                                   as mean_freight,
    sum(item_freight) / nullif(sum(item_price), 0)      as freight_to_price_ratio,

    avg(weight_g)                                       as mean_weight_g,
    avg(volume_litres)                                  as mean_volume_litres,
    -- Freight per kilo separates "expensive because heavy" from "expensive
    -- because awkward". Categories that are cheap per kilo but costly per
    -- item are bulky-light goods, where volumetric pricing bites.
    sum(item_freight) / nullif(sum(weight_g) / 1000.0, 0)
                                                        as freight_per_kg,
    avg(route_distance_km)                              as mean_route_distance_km,

    -- ---- fulfilment ------------------------------------------------------
    avg(case when has_delivery_outcome then is_late::int end)
                                                        as late_rate,
    avg(case when has_delivery_outcome then total_delivery_days end)
                                                        as mean_delivery_days,
    avg(case when has_delivery_outcome then seller_handling_days end)
                                                        as mean_handling_days,
    avg(case when has_delivery_outcome then carrier_transit_days end)
                                                        as mean_transit_days,

    -- ---- listing quality --------------------------------------------------
    avg(photos_qty)                                     as mean_photos,
    avg(description_length)                             as mean_description_length,

    -- ---- satisfaction -----------------------------------------------------
    avg(case when was_reviewed then review_score end)   as mean_review_score,
    avg(case when was_reviewed then is_detractor::int end)
                                                        as detractor_rate,

    count(*) < 30                                       as suppress_small_n,
    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from items
group by category_en
