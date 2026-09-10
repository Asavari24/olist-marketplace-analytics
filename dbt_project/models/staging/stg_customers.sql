-- One row per customer_id, which is one row per ORDER, not per person.
--
-- This is the single most consequential naming trap in the dataset. Olist
-- issues a fresh customer_id for every order and keeps customer_unique_id
-- stable across a person's orders. 99,441 customer_ids collapse to 96,096
-- customer_unique_ids. Any retention, RFM or lifetime-value number built on
-- customer_id is guaranteed to report ~zero repeat purchase, because the key
-- cannot repeat by construction.
--
-- Both keys are carried through with names that make the difference
-- impossible to miss: `order_customer_key` and `person_key`.

select
    customer_id                             as order_customer_key,
    customer_unique_id                      as person_key,

    -- Kept as text. These are 5-character prefixes where the leading zero is
    -- meaningful: "01037" is central Sao Paulo, 1037 is not a zip at all.
    customer_zip_code_prefix                as customer_zip_prefix,
    lower(trim(customer_city))              as customer_city,
    upper(trim(customer_state))             as customer_state,
    {{ br_region('upper(trim(customer_state))') }}  as customer_region

from {{ source('olist_raw', 'olist_customers_dataset') }}
