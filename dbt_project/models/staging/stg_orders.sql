-- One row per order, typed and with the delivery promise made explicit.
--
-- No filtering happens here. The analysis window is applied in the
-- intermediate layer so that mart_data_coverage can still see and count the
-- rows the window throws away.

select
    order_id,
    customer_id,
    order_status,

    cast(order_purchase_timestamp     as timestamp)  as purchased_at,
    cast(order_approved_at            as timestamp)  as approved_at,
    cast(order_delivered_carrier_date as timestamp)  as carrier_handover_at,
    cast(order_delivered_customer_date as timestamp) as delivered_at,
    cast(order_estimated_delivery_date as timestamp) as estimated_delivery_date,

    -- The promise the buyer actually saw, as an instant rather than a date.
    {{ promise_deadline('cast(order_estimated_delivery_date as timestamp)') }}
                                                     as promise_deadline_at,

    -- Delivered orders are the only ones with a measurable delivery outcome.
    -- 'shipped' orders left the seller but never recorded arrival; treating
    -- them as on-time or as late are both wrong, so they are excluded from
    -- delivery rates and counted separately in mart_data_coverage.
    order_status = 'delivered'
        and order_delivered_customer_date is not null                as has_delivery_outcome,

    order_status = 'canceled'                                        as is_canceled,

    cast(date_trunc('month', cast(order_purchase_timestamp as timestamp)) as date)
                                                                     as purchase_month,
    cast(order_purchase_timestamp as date)                           as purchase_date,
    extract(dow  from cast(order_purchase_timestamp as timestamp))   as purchase_dow,
    extract(hour from cast(order_purchase_timestamp as timestamp))   as purchase_hour

from {{ source('olist_raw', 'olist_orders_dataset') }}
