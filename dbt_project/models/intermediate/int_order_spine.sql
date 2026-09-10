-- The analytical spine: one row per in-window order, everything attached.
--
-- Every mart hangs off this model, which is the point -- it means "GMV",
-- "late", "region" and "review score" are defined once. The joins are all
-- LEFT from the order, because each of the three attached tables is
-- legitimately incomplete and inner joins would silently change the
-- denominator:
--
--   basket     775 orders have no item lines (unavailable/canceled).
--   timeline   only delivered orders have a delivery outcome.
--   review     ~1.3% of orders were never reviewed, and non-response is not
--              random -- see mart_review_drivers.

with orders as (
    select *
    from {{ ref('stg_orders') }}
    where {{ in_analysis_window('purchased_at') }}
),

customers as (
    select * from {{ ref('stg_customers') }}
)

select
    o.order_id,
    c.person_key,
    o.customer_id                                   as order_customer_key,

    o.order_status,
    o.has_delivery_outcome,
    o.is_canceled,

    o.purchased_at,
    o.purchase_date,
    o.purchase_month,
    o.purchase_dow,
    o.purchase_hour,
    o.delivered_at,
    o.estimated_delivery_date,
    o.promise_deadline_at,

    -- ---- geography ----------------------------------------------------
    c.customer_zip_prefix,
    c.customer_city,
    c.customer_state,
    c.customer_region,
    b.primary_seller_state,
    b.is_fully_intrastate,
    b.route_distance_km,
    b.mean_route_distance_km,
    b.any_geocode_missing,

    -- ---- basket ---------------------------------------------------------
    b.n_items,
    b.n_sellers,
    b.n_categories,
    b.is_multi_seller,
    b.gmv,
    b.freight_total,
    b.order_total,
    b.freight_to_price_ratio,
    b.max_item_price,
    b.total_weight_g,
    b.total_volume_litres,
    b.primary_category,
    b.primary_seller_id,
    b.earliest_shipping_limit_at,
    b.paid_total,
    b.max_installments,
    b.primary_payment_type,
    b.used_credit_card,
    b.used_boleto,
    b.used_voucher,
    b.payment_reconciliation_gap,
    b.order_id is null                              as basket_missing,

    -- ---- delivery -------------------------------------------------------
    t.payment_approval_days,
    t.seller_handling_days,
    t.carrier_transit_days,
    t.total_delivery_days,
    t.promised_days,
    t.promise_slack_days,
    t.lateness_days,
    t.is_late,
    t.stage_order_clamped,
    t.approval_ts_missing,
    t.handover_ts_missing,

    -- Did the seller miss its own contractual dispatch deadline? This is the
    -- cleanest attributable seller failure in the dataset: the deadline is
    -- given per line in the source, not inferred by us.
    o.carrier_handover_at > b.earliest_shipping_limit_at
                                                    as seller_missed_dispatch_sla,

    -- ---- review ---------------------------------------------------------
    r.review_score,
    r.is_detractor,
    r.is_promoter,
    r.has_comment_text,
    r.response_lag_hours                            as review_response_lag_hours,
    r.order_was_resurveyed,
    r.resurvey_scores_disagree,
    r.order_id is not null                          as was_reviewed,

    -- The window is stamped on every row so a figure lifted out of a mart
    -- carries its own provenance.
    cast('{{ var("analysis_start") }}' as date)     as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)     as analysis_end

from orders o
join      customers c on o.customer_id = c.order_customer_key
left join {{ ref('int_order_basket') }}             b on o.order_id = b.order_id
left join {{ ref('int_order_delivery_timeline') }}  t on o.order_id = t.order_id
left join {{ ref('stg_order_reviews') }}            r on o.order_id = r.order_id
