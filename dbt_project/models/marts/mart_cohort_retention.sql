-- Monthly acquisition cohorts and their repeat purchasing.
-- One row per (cohort_month, months_since_first).
--
-- This mart is a NEGATIVE RESULT and is built so that the negative result is
-- unmissable rather than buried. With a 3.11% repeat rate the retention
-- triangle is essentially empty: most cells are a fraction of a percent, and
-- the ones that are not are small-n noise.
--
-- It is included anyway for two reasons. It is the only honest way to answer
-- "what does retention look like", and it quantifies the ceiling on any
-- retention initiative -- which is the actually useful finding. You cannot
-- improve repeat rate from 3% to 30% with lifecycle email; a marketplace
-- where nobody comes back has a positioning problem, not a CRM problem.
--
-- A caveat on the cohort triangle generally: later cohorts have had less
-- time to repeat, so the lower-right of the triangle is empty by
-- construction rather than by behaviour. `is_observable` marks the cells
-- where a cohort had actually reached that age before the window closed;
-- everything else must be excluded from any column average.

with first_purchase as (
    select
        person_key,
        min(purchased_at)                                       as first_purchase_at,
        cast(date_trunc('month', min(purchased_at)) as date)    as cohort_month
    from {{ ref('mart_order_fact') }}
    group by person_key
),

orders_with_cohort as (
    select
        f.cohort_month,
        f.person_key,
        o.order_id,
        o.purchase_month,
        coalesce(o.gmv, 0)                                      as gmv,
        date_diff('month', f.cohort_month, o.purchase_month)    as months_since_first
    from {{ ref('mart_order_fact') }} o
    join first_purchase f on o.person_key = f.person_key
),

cohort_sizes as (
    select cohort_month, count(*) as cohort_size
    from first_purchase
    group by cohort_month
),

-- The widest possible cohort age, i.e. the span of the analysis window in
-- months. Materialised as its own CTE because DuckDB will not accept an
-- aggregate inside the lateral subquery of a cross join.
window_span as (
    select date_diff('month',
                     min(purchase_month),
                     max(purchase_month)) as max_months
    from {{ ref('mart_order_fact') }}
),

ages as (
    select unnest(generate_series(0, (select max_months from window_span)))
               as months_since_first
),

-- Every (cohort, age) cell that could exist, so months with zero repeat
-- buyers appear as an explicit 0 rather than vanishing from the triangle.
scaffold as (
    select
        c.cohort_month,
        c.cohort_size,
        a.months_since_first
    from cohort_sizes c
    cross join ages a
),

activity as (
    select
        cohort_month,
        months_since_first,
        count(distinct person_key)          as active_persons,
        count(*)                            as orders,
        sum(gmv)                            as gmv
    from orders_with_cohort
    group by cohort_month, months_since_first
)

select
    s.cohort_month,
    s.cohort_size,
    s.months_since_first,

    coalesce(a.active_persons, 0)                       as active_persons,
    coalesce(a.orders, 0)                               as orders,
    coalesce(a.gmv, 0)                                  as gmv,

    coalesce(a.active_persons, 0)::double / nullif(s.cohort_size, 0)
                                                        as retention_rate,
    coalesce(a.gmv, 0) / nullif(s.cohort_size, 0)       as gmv_per_cohort_member,

    -- Had this cohort actually aged this far before the window closed?
    -- Cells where it had not are structurally empty and must not be averaged
    -- in with real zeros.
    s.cohort_month + to_months(cast(s.months_since_first as integer))
        <= cast('{{ var("analysis_end") }}' as date)    as is_observable,

    cast('{{ var("analysis_start") }}' as date)         as analysis_start,
    cast('{{ var("analysis_end") }}'   as date)         as analysis_end

from scaffold s
left join activity a
       on s.cohort_month = a.cohort_month
      and s.months_since_first = a.months_since_first
where s.cohort_month + to_months(cast(s.months_since_first as integer))
      <= cast('{{ var("analysis_end") }}' as date)
