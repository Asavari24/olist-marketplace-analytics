-- One row per product, with the English category attached.
--
-- Two publisher artefacts are corrected here rather than propagated:
--
--   The raw columns are misspelled -- product_name_lenght,
--   product_description_lenght. Renaming them at the boundary means the
--   misspelling appears exactly once in the project, in this file.
--
--   The translation table covers 71 categories; the products table contains
--   73. The two without a translation (pc_gamer and
--   portateis_cozinha_e_preparadores_de_alimentos) are given hand-written
--   English names instead of being dropped or left null, because a null
--   category silently disappears from every category-level group-by.
--
-- 610 products carry no category at all. Those keep an explicit
-- 'uncategorized' label for the same reason.

with products as (
    select
        product_id,
        nullif(trim(product_category_name), '')     as category_pt,
        cast(product_name_lenght        as integer) as name_length,
        cast(product_description_lenght as integer) as description_length,
        cast(product_photos_qty         as integer) as photos_qty,
        cast(product_weight_g           as double)  as weight_g,
        cast(product_length_cm          as double)  as length_cm,
        cast(product_height_cm          as double)  as height_cm,
        cast(product_width_cm           as double)  as width_cm
    from {{ source('olist_raw', 'olist_products_dataset') }}
),

translation as (
    select
        product_category_name           as category_pt,
        product_category_name_english   as category_en
    from {{ source('olist_raw', 'product_category_name_translation') }}
)

select
    p.product_id,
    p.category_pt,

    coalesce(
        t.category_en,
        case p.category_pt
            when 'pc_gamer' then 'pc_gamer'
            when 'portateis_cozinha_e_preparadores_de_alimentos'
                 then 'portable_kitchen_food_preparers'
        end,
        'uncategorized'
    )                                               as category_en,

    t.category_en is null and p.category_pt is not null
                                                    as category_translation_missing,

    p.name_length,
    p.description_length,
    p.photos_qty,
    p.weight_g,
    p.length_cm,
    p.height_cm,
    p.width_cm,

    -- Volumetric size drives freight cost more than mass does for light bulky
    -- goods, so both are carried. Litres, to keep the numbers readable.
    (p.length_cm * p.height_cm * p.width_cm) / 1000.0
                                                    as volume_litres,

    p.weight_g is null                              as dimensions_missing

from products p
left join translation t on p.category_pt = t.category_pt
