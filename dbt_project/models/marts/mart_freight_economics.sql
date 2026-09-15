-- Freight economics at item-line grain, with the drivers that should explain
-- a shipping price sitting next to the price actually charged.
--
-- This is the observational table; the fitted model and the residual ranking
-- live in olist/freight_model.py. The split matters: what freight IS can be
-- stated in SQL and tested, what freight SHOULD BE is a modelling choice and
-- belongs where its assumptions are visible.
--
-- WHAT FREIGHT MEANS HERE. `freight_value` is charged to the BUYER, per item
-- line. It is not Olist's cost and there is no cost column anywhere in this
-- dataset, so nothing in this project can speak to carrier margin. What it
-- can speak to is pricing consistency: whether two shipments with the same
-- weight, size and distance are quoted the same amount. They are not, and the
-- spread is the finding.
--
-- 383 lines carry zero freight -- free-shipping promotions or absorbed cost.
-- They are kept and flagged rather than dropped: excluding them would bias
-- the average freight upward, and they are a real commercial choice worth
-- counting.
--
-- Billable weight uses the standard volumetric convention: carriers charge
-- the greater of actual mass and volume/divisor, because a box of pillows
-- fills a van without weighing anything. 5000 cm3/kg is the common Brazilian
-- courier divisor. Using raw mass alone makes bulky-light categories look
-- systematically overcharged when they are simply being billed by volume.

with lines as (
    select
        i.order_id,
        i.order_item_seq,
        i.seller_id,
        i.product_id,
        i.category_en,
        i.seller_state,
        i.customer_state,
        i.is_intrastate,
        i.route_distance_km,
        i.item_price,
        i.item_freight,
        i.weight_g,
        i.volume_litres,
        o.purchase_month,
        o.customer_region,
        o.seller_missed_dispatch_sla,
        o.is_late,
        o.review_score,
        o.was_reviewed
    from {{ ref('int_order_items_enriched') }} i
    join {{ ref('mart_order_fact') }} o on i.order_id = o.order_id
),

priced as (
    select
        *,
        weight_g / 1000.0                                       as weight_kg,
        -- volume_litres is cm3/1000, so cm3 = litres*1000 and the divisor
        -- converts to kg.
        (volume_litres * 1000.0) / 5000.0                       as volumetric_kg,
        greatest(coalesce(weight_g / 1000.0, 0),
                 coalesce((volume_litres * 1000.0) / 5000.0, 0)) as billable_kg,
        item_freight = 0                                        as is_free_shipping,
        weight_g is null or volume_litres is null               as dimensions_missing
    from lines
)

select
    order_id,
    order_item_seq,
    seller_id,
    product_id,
    category_en,
    purchase_month,

    seller_state,
    customer_state,
    customer_region,
    is_intrastate,
    seller_state || '->' || customer_state                  as route,
    route_distance_km,

    item_price,
    item_freight,
    weight_kg,
    volumetric_kg,
    billable_kg,

    -- TRUE where volume rather than mass sets the billable weight. The share
    -- of a category's lines that are volumetric is what separates "heavy" from
    -- "bulky", and they are priced by different logic.
    coalesce(volumetric_kg, 0) > coalesce(weight_kg, 0)     as is_volumetric,

    -- ---- the unit economics -------------------------------------------
    item_freight / nullif(item_price, 0)                    as freight_to_price_ratio,
    item_freight / nullif(billable_kg, 0)                   as freight_per_billable_kg,
    item_freight / nullif(route_distance_km, 0)             as freight_per_km,
    -- The per-kg-per-1000km figure is the only one comparable across both a
    -- heavy short haul and a light long one, and it is what the benchmark
    -- table in the dashboard sorts on.
    item_freight / nullif(billable_kg * route_distance_km / 1000.0, 0)
                                                            as freight_per_kg_per_1000km,

    is_free_shipping,
    dimensions_missing,

    -- ---- bands, so the dashboard need not compute them -----------------
    case
        when billable_kg is null      then 'unknown'
        when billable_kg <   0.5      then '01 under 0.5kg'
        when billable_kg <   2.0      then '02 0.5-2kg'
        when billable_kg <   5.0      then '03 2-5kg'
        when billable_kg <  15.0      then '04 5-15kg'
        else                               '05 15kg+'
    end                                                     as weight_band,
    case
        when route_distance_km is null then 'unknown'
        when route_distance_km <   50  then '01 under 50km'
        when route_distance_km <  200  then '02 50-200km'
        when route_distance_km <  600  then '03 200-600km'
        when route_distance_km < 1500  then '04 600-1500km'
        else                                '05 1500km+'
    end                                                     as distance_band,

    is_late,
    seller_missed_dispatch_sla,
    case when was_reviewed then review_score end            as review_score,

    cast('{{ var("analysis_start") }}' as date)             as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)             as analysis_end

from priced
