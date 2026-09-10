-- One row per item line. Grain is (order_id, order_item_id).
--
-- order_item_id is a within-order sequence number, not a product key. Two
-- units of the same product are two rows with the same product_id and
-- different order_item_id -- which means quantity is a COUNT of rows, and
-- `max(order_item_id)` is the item count only because the sequence is dense.
-- The dense-sequence assumption is asserted in
-- tests/assert_order_item_sequence_is_dense.sql rather than trusted.

select
    order_id,
    cast(order_item_id as integer)                    as order_item_seq,
    product_id,
    seller_id,

    -- The contractual deadline for the seller to hand the parcel to the
    -- carrier. Missing it is the seller's failure, not the carrier's -- this
    -- is what makes the handling/transit split in the delivery decomposition
    -- attributable rather than merely descriptive.
    cast(shipping_limit_date as timestamp)            as shipping_limit_at,

    cast(price as double)                             as item_price,
    cast(freight_value as double)                     as item_freight,
    cast(price as double) + cast(freight_value as double)
                                                      as item_total

from {{ source('olist_raw', 'olist_order_items_dataset') }}
