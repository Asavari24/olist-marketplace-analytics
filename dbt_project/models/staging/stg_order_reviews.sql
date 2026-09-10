-- Post-delivery satisfaction survey, deduplicated to one row per order.
--
-- The raw table is unique on neither key, and the two duplications have
-- different causes and need different treatment:
--
--   789 review_ids appear against more than one order. In every one of the
--   789 the score is identical across the rows -- this is one survey response
--   covering a customer's multi-order purchase, fanned out. Keeping all rows
--   is correct: each order genuinely carries that score.
--
--   547 order_ids carry more than one review. 345 of them agree on the score
--   and 202 disagree, so this is a real re-survey, not a fan-out. Averaging
--   the disagreements would invent scores that no customer gave (a 1 and a 5
--   becoming a 3), so the LAST review by creation date wins -- the customer's
--   settled opinion -- and the disagreement is flagged so the review-driver
--   models can test whether excluding them changes anything.
--
-- Net effect: 99,224 raw rows -> 98,673 rows, one per reviewed order.

with typed as (
    select
        review_id,
        order_id,
        cast(review_score as integer)                    as review_score,
        nullif(trim(review_comment_title), '')           as review_title,
        nullif(trim(review_comment_message), '')         as review_text,
        cast(review_creation_date as timestamp)          as review_sent_at,
        cast(review_answer_timestamp as timestamp)       as review_answered_at
    from {{ source('olist_raw', 'olist_order_reviews_dataset') }}
),

flagged as (
    select
        *,
        count(*)                    over (partition by order_id) as reviews_on_order,
        count(distinct review_score) over (partition by order_id) as distinct_scores_on_order,
        row_number()                over (
            partition by order_id
            order by review_answered_at desc, review_sent_at desc, review_id
        )                                                        as recency_rank
    from typed
)

select
    review_id,
    order_id,
    review_score,
    review_title,
    review_text,
    review_sent_at,
    review_answered_at,

    review_text is not null                              as has_comment_text,
    review_score <= 2                                    as is_detractor,
    review_score = 5                                     as is_promoter,

    reviews_on_order > 1                                 as order_was_resurveyed,
    distinct_scores_on_order > 1                         as resurvey_scores_disagree,

    -- Hours the customer took to answer after the survey was sent. Long
    -- response lags correlate with indifference; near-instant ones with
    -- strong feeling in either direction.
    {{ hours_between('review_sent_at', 'review_answered_at') }}  as response_lag_hours

from flagged
where recency_rank = 1
