-- The delivery timeline of every order, cut into the four stages that have
-- different owners. This is the model the whole delivery analysis rests on.
--
-- The stages and who owns each one:
--
--   payment_approval   purchase -> payment approved      Olist / the acquirer
--   seller_handling    approval -> handed to the carrier  the SELLER
--   carrier_transit    handover -> delivered              the CARRIER
--
-- Splitting these matters because "the order was late" is not an actionable
-- statement. "The seller sat on it for six days" and "the carrier took three
-- weeks to cross the country" have different fixes, and mart_delivery_stage_
-- attribution shows they are not equally to blame.
--
-- MONOTONICITY. The raw timestamps are not always ordered. Measured on this
-- extract: 1,350 delivered orders record the carrier handover BEFORE payment
-- approval (a boleto that cleared after dispatch), and 23 record delivery
-- before handover. Left alone these produce negative stage durations that
-- quietly cancel out positive ones when averaged, understating both stages.
--
-- The fix is a running maximum: each checkpoint is pushed to at least the
-- previous checkpoint's time. Stages are then non-negative by construction
-- and sum EXACTLY to the observed total, which is what makes the attribution
-- in the marts a decomposition rather than an approximation. Every clamped
-- order is flagged so its influence can be measured -- and
-- tests/assert_delivery_stages_sum_to_total.sql enforces the identity.

with delivered as (
    select *
    from {{ ref('stg_orders') }}
    where has_delivery_outcome
      and {{ in_analysis_window('purchased_at') }}
),

-- 14 delivered orders have no approval timestamp and 1 has no carrier
-- handover. Rather than drop them, the missing checkpoint is carried forward
-- from the previous one, which assigns that stage a duration of zero and
-- pushes its time into the next stage. The flag says so.
filled as (
    select
        *,
        approved_at is null           as approval_ts_missing,
        carrier_handover_at is null   as handover_ts_missing,
        coalesce(approved_at, purchased_at)                              as approved_filled,
        coalesce(carrier_handover_at, approved_at, purchased_at)         as handover_filled
    from delivered
),

monotonic as (
    select
        *,
        purchased_at                                                     as t0,
        greatest(approved_filled, purchased_at)                          as t1,
        greatest(handover_filled, approved_filled, purchased_at)         as t2,
        greatest(delivered_at, handover_filled, approved_filled, purchased_at)
                                                                         as t3,
        -- Did enforcing order actually move anything on this row?
        approved_filled  < purchased_at
            or handover_filled < approved_filled
            or delivered_at    < handover_filled                         as stage_order_clamped
    from filled
)

select
    order_id,
    customer_id,
    purchased_at,
    purchase_month,
    purchase_date,
    purchase_dow,
    purchase_hour,
    delivered_at,
    estimated_delivery_date,
    promise_deadline_at,

    -- ---- the decomposition -------------------------------------------
    {{ days_between('t0', 't1') }}                  as payment_approval_days,
    {{ days_between('t1', 't2') }}                  as seller_handling_days,
    {{ days_between('t2', 't3') }}                  as carrier_transit_days,
    {{ days_between('t0', 't3') }}                  as total_delivery_days,

    -- ---- the promise -------------------------------------------------
    -- What the buyer was told to expect, measured the same way.
    {{ days_between('t0', 'promise_deadline_at') }} as promised_days,

    -- Signed slack against the promise. Positive = delivered late.
    {{ days_between('promise_deadline_at', 'delivered_at') }}
                                                    as lateness_days,
    delivered_at > promise_deadline_at              as is_late,

    -- Padding in the estimate: how much longer the promise was than the
    -- delivery actually took. Olist's estimates are famously conservative and
    -- this column is what lets mart_delivery_performance quantify by how
    -- much, and show that most "on time" is padding rather than speed.
    {{ days_between('t3', 'promise_deadline_at') }} as promise_slack_days,

    -- ---- data-quality flags ------------------------------------------
    approval_ts_missing,
    handover_ts_missing,
    stage_order_clamped

from monotonic
