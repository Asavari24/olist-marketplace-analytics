-- One row per seller. 3,095 sellers, and the origin zip prefix that makes
-- the shipping leg measurable.

select
    seller_id,
    seller_zip_code_prefix                        as seller_zip_prefix,
    lower(trim(seller_city))                      as seller_city,
    upper(trim(seller_state))                     as seller_state,
    {{ br_region('upper(trim(seller_state))') }}  as seller_region

from {{ source('olist_raw', 'olist_sellers_dataset') }}
