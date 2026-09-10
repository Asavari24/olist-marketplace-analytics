-- One row per seller. Operations, economics and reputation on one line.
--
-- Seller-level metrics are computed on ITEM lines, not orders, because a
-- multi-seller order belongs partly to each seller. Attributing the whole
-- order to one of them -- the natural shortcut -- would double-count GMV
-- across the 1,278 multi-seller orders and credit each seller with delivery
-- outcomes it did not control.
--
-- The delivery and review columns are the honest compromise: those outcomes
-- are only observed at ORDER level, so for multi-seller orders they are
-- shared. The share of a seller's orders that are multi-seller is carried as
-- `multi_seller_order_share` so a reader can see how contaminated any given
-- seller's outcome columns are.

with items as (
    select
        i.seller_id,
        i.order_id,
        i.item_price,
        i.item_freight,
        i.category_en,
        i.route_distance_km,
        o.purchased_at,
        o.purchase_month,
        o.has_delivery_outcome,
        o.is_late,
        o.lateness_days,
        o.seller_handling_days,
        o.carrier_transit_days,
        o.total_delivery_days,
        o.seller_missed_dispatch_sla,
        o.is_multi_seller,
        o.review_score,
        o.is_detractor,
        o.was_reviewed
    from {{ ref('int_order_items_enriched') }} i
    join {{ ref('mart_order_fact') }} o on i.order_id = o.order_id
),

per_seller as (
    select
        seller_id,

        -- ---- scale (item-level, no double counting) ----------------------
        count(*)                                        as n_items_sold,
        count(distinct order_id)                        as n_orders,
        sum(item_price)                                 as gmv,
        sum(item_freight)                               as freight_collected,
        avg(item_price)                                 as mean_item_price,
        median(item_price)                              as median_item_price,
        sum(item_freight) / nullif(sum(item_price), 0)  as freight_to_price_ratio,
        count(distinct category_en)                     as n_categories,
        arg_max(category_en, item_price)                as primary_category,

        -- ---- tenure ------------------------------------------------------
        min(purchased_at)                               as first_sale_at,
        max(purchased_at)                               as last_sale_at,
        count(distinct purchase_month)                  as active_months,
        date_diff('day', min(purchased_at), max(purchased_at)) as tenure_days,

        -- ---- operations (order-level outcomes, deduplicated) -------------
        count(distinct case when has_delivery_outcome then order_id end)
                                                        as n_delivered_orders,
        count(distinct case when is_multi_seller then order_id end)::double
            / nullif(count(distinct order_id), 0)       as multi_seller_order_share,

        avg(case when has_delivery_outcome then is_late::int end)
                                                        as late_rate,
        avg(case when has_delivery_outcome then seller_handling_days end)
                                                        as mean_handling_days,
        median(case when has_delivery_outcome then seller_handling_days end)
                                                        as median_handling_days,
        avg(case when has_delivery_outcome then carrier_transit_days end)
                                                        as mean_transit_days,
        avg(seller_missed_dispatch_sla::int)            as dispatch_sla_miss_rate,
        avg(route_distance_km)                          as mean_route_distance_km,

        -- ---- reputation ---------------------------------------------------
        count(distinct case when was_reviewed then order_id end)
                                                        as n_reviewed_orders,
        avg(case when was_reviewed then review_score end)
                                                        as mean_review_score,
        avg(case when was_reviewed then is_detractor::int end)
                                                        as detractor_rate

    from items
    group by seller_id
),

with_concentration as (
    select
        *,
        gmv / nullif(sum(gmv) over (), 0)                       as gmv_share,
        sum(gmv) over (order by gmv desc rows between unbounded preceding and current row)
            / nullif(sum(gmv) over (), 0)                       as gmv_cumulative_share,
        row_number() over (order by gmv desc)                   as gmv_rank,
        ntile(10) over (order by gmv desc)                      as gmv_decile
    from per_seller
)

select
    w.*,
    s.seller_state,
    s.seller_region,

    -- Sellers below this are too thin for their rates to mean anything;
    -- roughly half the seller base sits here and contributes a few percent
    -- of GMV, which is itself the concentration story.
    w.n_orders < 10                                     as suppress_small_n,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from with_concentration w
left join {{ ref('stg_sellers') }} s on w.seller_id = s.seller_id
