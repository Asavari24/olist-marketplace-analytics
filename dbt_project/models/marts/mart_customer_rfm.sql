-- RFM at the PERSON level (customer_unique_id), not the per-order
-- customer_id. One row per person.
--
-- READ THIS BEFORE USING THE F SCORE.
--
-- 96.9% of Olist customers in this window bought exactly once. 2,975 people
-- out of 95,774 ever came back -- a 3.11% repeat rate. Frequency is therefore
-- very nearly a constant, and standard RFM machinery breaks on it in a way
-- that is easy to miss and produces confident nonsense:
--
--   ntile(5) over frequency puts identical customers -- everyone with
--   exactly one order -- into five different "segments" purely on tie-break
--   order. The segments then look populated and balanced, and they are
--   entirely an artefact of the sort.
--
-- So F is scored on its actual distribution instead: 1 order scores 1, and
-- the small repeat tail is spread over 2-5. Most customers get f_score = 1
-- because most customers ARE identical on this axis. A flat F column is the
-- correct output here, and `frequency_is_degenerate` says so on every row so
-- the finding travels with the data.
--
-- R and M are genuine quintiles and carry real information.
--
-- Recency is measured from the analysis window end, not from today, so the
-- segmentation is stable and reproducible rather than drifting each run.

with per_person as (
    select
        person_key,

        count(*)                                        as frequency_orders,
        count(distinct case when has_delivery_outcome then order_id end)
                                                        as delivered_orders,

        max(purchased_at)                               as last_purchase_at,
        min(purchased_at)                               as first_purchase_at,
        date_diff('day', max(purchased_at),
                  cast('{{ var("analysis_end") }}' as timestamp) + interval 1 day)
                                                        as recency_days,
        date_diff('day', min(purchased_at), max(purchased_at))
                                                        as customer_lifespan_days,

        sum(coalesce(gmv, 0))                           as monetary_gmv,
        sum(coalesce(order_total, 0))                   as monetary_total_incl_freight,
        avg(gmv)                                        as mean_order_gmv,
        sum(coalesce(freight_total, 0))                 as freight_paid,

        max(customer_state)                             as customer_state,
        max(customer_region)                            as customer_region,
        arg_max(primary_category, coalesce(gmv, 0))     as top_category,

        avg(case when was_reviewed then review_score end)
                                                        as mean_review_score,
        avg(case when has_delivery_outcome then is_late::int end)
                                                        as late_rate

    from {{ ref('mart_order_fact') }}
    group by person_key
),

scored as (
    select
        *,
        -- Recency: 5 = most recent. Reversed so that high is good on every
        -- axis, which is what makes the concatenated RFM cell readable.
        --
        -- person_key is a tiebreaker, not decoration. Thousands of customers
        -- share an identical recency_days (and many share an identical
        -- monetary_gmv), and ntile() has to put tied rows on one side of a
        -- boundary or the other. Without a deterministic tiebreaker DuckDB's
        -- parallel sort picks differently between runs, and segment counts
        -- move by ~50 people each rebuild -- measured, not hypothetical.
        -- Ordering by the key makes the split arbitrary but STABLE, which is
        -- the most that can be asked of a quantile cut through a tie.
        6 - ntile({{ var('rfm_quantiles') }}) over (order by recency_days, person_key)
                                                                                as r_score,
        ntile({{ var('rfm_quantiles') }}) over (order by monetary_gmv, person_key)
                                                                                as m_score,

        -- Frequency scored on the real distribution, not on quantiles.
        case
            when frequency_orders >= 5 then 5
            when frequency_orders =  4 then 4
            when frequency_orders =  3 then 3
            when frequency_orders =  2 then 2
            else                            1
        end                                                                     as f_score
    from per_person
)

select
    person_key,
    customer_state,
    customer_region,
    top_category,

    recency_days,
    frequency_orders,
    delivered_orders,
    monetary_gmv,
    monetary_total_incl_freight,
    mean_order_gmv,
    freight_paid,
    first_purchase_at,
    last_purchase_at,
    customer_lifespan_days,
    mean_review_score,
    late_rate,

    r_score,
    f_score,
    m_score,
    r_score + f_score + m_score                         as rfm_sum,
    cast(r_score as varchar) || cast(f_score as varchar) || cast(m_score as varchar)
                                                        as rfm_cell,

    -- A segmentation that does not pretend F carries information. It is R
    -- and M doing the work, with the repeat buyers pulled out as their own
    -- segment because on this dataset "bought twice" is genuinely rare and
    -- genuinely interesting.
    case
        when frequency_orders > 1 and m_score >= 4      then 'Repeat high value'
        when frequency_orders > 1                       then 'Repeat'
        when r_score >= 4 and m_score >= 4              then 'Recent high value'
        when r_score >= 4                               then 'Recent'
        when r_score <= 2 and m_score >= 4              then 'Lapsed high value'
        when r_score <= 2                               then 'Lapsed'
        else                                                 'Mid'
    end                                                 as segment,

    frequency_orders = 1                                as is_one_time_buyer,

    -- Measured, not asserted. If a future extract has real repeat behaviour
    -- this flips to false on its own and the warning stops firing, rather
    -- than a hardcoded `true` outliving the condition it described.
    avg((frequency_orders = 1)::int) over ()            as one_time_buyer_share,
    avg((frequency_orders = 1)::int) over () > 0.90     as frequency_is_degenerate,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from scored
