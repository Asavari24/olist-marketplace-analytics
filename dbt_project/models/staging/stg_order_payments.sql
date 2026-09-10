-- One row per payment instrument on an order. Grain is
-- (order_id, payment_sequential).
--
-- Two traps live in this table. First, an order can be paid with several
-- instruments -- a voucher plus a card is common -- so payment_value is a sum
-- per order and joining it row-to-row against items multiplies both. Second,
-- payment_installments is the number of instalments on THAT instrument, so
-- "the order's instalment count" is the max across instruments, not the sum.

select
    order_id,
    cast(payment_sequential as integer)     as payment_seq,
    payment_type,
    cast(payment_installments as integer)   as payment_installments,
    cast(payment_value as double)           as payment_value

from {{ source('olist_raw', 'olist_order_payments_dataset') }}
