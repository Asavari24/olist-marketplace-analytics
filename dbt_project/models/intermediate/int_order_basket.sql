-- Order-level rollup of the basket: value, freight, items, sellers,
-- categories and the shipping geography. One row per order that HAS items.
--
-- 775 orders carry no item lines at all -- almost all of them 'unavailable'
-- or 'canceled' -- so this model is deliberately smaller than stg_orders and
-- is LEFT joined downstream. Inner-joining it would silently drop those
-- orders from the funnel and make the cancellation rate look lower than it is.
--
-- Distance is aggregated as a MAX across the order's item lines, not a mean.
-- An order is delivered when its last parcel arrives, so the binding
-- constraint on the customer's experience is the longest leg, not the
-- average one. The mean is kept alongside for the freight models, where
-- cost genuinely is per-parcel.

with items as (
    select * from {{ ref('int_order_items_enriched') }}
),

payments as (
    select
        order_id,
        sum(payment_value)                                    as paid_total,
        -- Instalments are per instrument, so the order's plan is the longest
        -- one on it, never the sum.
        max(payment_installments)                             as max_installments,
        count(*)                                              as n_payment_instruments,
        bool_or(payment_type = 'credit_card')                 as used_credit_card,
        bool_or(payment_type = 'boleto')                      as used_boleto,
        bool_or(payment_type = 'voucher')                     as used_voucher,
        -- The instrument carrying the most value is the one that
        -- characterises the order.
        arg_max(payment_type, payment_value)                  as primary_payment_type
    from {{ ref('stg_order_payments') }}
    group by order_id
)

select
    i.order_id,

    count(*)                                        as n_items,
    count(distinct i.product_id)                    as n_distinct_products,
    count(distinct i.seller_id)                     as n_sellers,
    count(distinct i.category_en)                   as n_categories,
    count(distinct i.seller_id) > 1                 as is_multi_seller,

    sum(i.item_price)                               as gmv,
    sum(i.item_freight)                             as freight_total,
    sum(i.item_total)                               as order_total,
    sum(i.item_freight) / nullif(sum(i.item_price), 0)
                                                    as freight_to_price_ratio,
    max(i.item_price)                               as max_item_price,

    sum(i.weight_g)                                 as total_weight_g,
    sum(i.volume_litres)                            as total_volume_litres,

    -- The category and seller that dominate the order by value.
    arg_max(i.category_en, i.item_price)            as primary_category,
    arg_max(i.seller_id,   i.item_price)            as primary_seller_id,
    arg_max(i.seller_state, i.item_price)           as primary_seller_state,

    max(i.customer_state)                           as customer_state,
    max(i.customer_region)                          as customer_region,
    bool_and(i.is_intrastate)                       as is_fully_intrastate,

    max(i.route_distance_km)                        as route_distance_km,
    avg(i.route_distance_km)                        as mean_route_distance_km,
    bool_or(i.geocode_missing)                      as any_geocode_missing,

    -- The tightest seller deadline on the order.
    min(i.shipping_limit_at)                        as earliest_shipping_limit_at,

    p.paid_total,
    p.max_installments,
    p.n_payment_instruments,
    p.primary_payment_type,
    p.used_credit_card,
    p.used_boleto,
    p.used_voucher,

    -- Payments should reconcile to price + freight. They do not always: the
    -- gap is carried as a column so the reconciliation is visible in the
    -- warehouse instead of being discovered by whoever sums the wrong one.
    p.paid_total - sum(i.item_total)                as payment_reconciliation_gap

from items i
left join payments p on i.order_id = p.order_id
group by i.order_id, p.paid_total, p.max_installments, p.n_payment_instruments,
         p.primary_payment_type, p.used_credit_card, p.used_boleto, p.used_voucher
