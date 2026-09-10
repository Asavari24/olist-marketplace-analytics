-- Ranks the candidate review drivers by how much score they actually move.
-- One row per driver.
--
-- Effect size is the n-weighted spread between a driver's best and worst
-- buckets, restricted to buckets with enough reviews to quote. Small buckets
-- are excluded before ranking, not after: a 12-review category with a mean
-- of 1.0 would otherwise top the table on noise alone.
--
-- This is a MARGINAL ranking. Lateness, distance and freight ratio move
-- together, so their marginal effects double-count a shared cause. The joint
-- model in olist/review_drivers.py is what separates them; this table exists
-- to say which variables are worth putting in that model, and to be the
-- sanity check its coefficients are read against.

with usable as (
    select *
    from {{ ref('mart_review_drivers') }}
    where not suppress_small_n
),

-- The n-weighted grand mean per driver, computed first. It cannot be done
-- inline in the dispersion expression below: that would nest a window
-- function inside an aggregate, which no engine allows.
driver_means as (
    select
        driver,
        sum(n_reviews * mean_score) / nullif(sum(n_reviews), 0) as grand_mean_score
    from usable
    group by driver
),

ranked as (
    select
        u.driver,
        count(*)                                        as n_buckets,
        sum(n_reviews)                                  as n_reviews,

        max(mean_score)                                 as best_bucket_score,
        min(mean_score)                                 as worst_bucket_score,
        max(mean_score) - min(mean_score)               as score_spread,

        arg_max(bucket, mean_score)                     as best_bucket,
        arg_min(bucket, mean_score)                     as worst_bucket,

        max(detractor_rate) - min(detractor_rate)       as detractor_rate_spread,

        -- Weighted standard deviation of bucket means around the driver's
        -- own grand mean. Less sensitive than the max-min spread to a single
        -- extreme bucket, so the two together show whether an effect is
        -- broad or driven by one outlier group.
        sqrt(
            sum(u.n_reviews * pow(u.mean_score - d.grand_mean_score, 2))
            / nullif(sum(u.n_reviews), 0)
        )                                               as weighted_bucket_dispersion

    from usable u
    join driver_means d on u.driver = d.driver
    group by u.driver
)

select
    driver,
    n_buckets,
    n_reviews,
    score_spread,
    best_bucket,
    best_bucket_score,
    worst_bucket,
    worst_bucket_score,
    detractor_rate_spread,
    weighted_bucket_dispersion,
    row_number() over (order by score_spread desc)      as rank_by_spread,
    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end
from ranked
order by score_spread desc
