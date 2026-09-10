-- The published order fact. One row per in-window order.
--
-- This is the table an analyst should start from and the one the Tableau
-- extracts are cut from. It is the spine with derived bands added -- the
-- bucketings that every downstream question re-invents slightly differently
-- if they are not fixed once here.

select
    s.*,

    -- ---- value bands -----------------------------------------------------
    case
        when s.gmv is null       then 'no items'
        when s.gmv <  50         then '01 under R$50'
        when s.gmv < 100         then '02 R$50-100'
        when s.gmv < 200         then '03 R$100-200'
        when s.gmv < 500         then '04 R$200-500'
        else                          '05 R$500+'
    end                                             as gmv_band,

    -- ---- distance bands --------------------------------------------------
    -- Cut at the points where the delivery problem changes character: within
    -- a metro, within a region, cross-country, and the Amazon/Nordeste haul.
    case
        when s.route_distance_km is null then 'unknown'
        when s.route_distance_km <   50  then '01 under 50km'
        when s.route_distance_km <  200  then '02 50-200km'
        when s.route_distance_km <  600  then '03 200-600km'
        when s.route_distance_km < 1500  then '04 600-1500km'
        else                                  '05 1500km+'
    end                                             as distance_band,

    -- ---- lateness severity ----------------------------------------------
    -- A parcel one day late and a parcel three weeks late are different
    -- failures; averaging a boolean hides that entirely.
    case
        when not s.has_delivery_outcome then 'no outcome'
        when not s.is_late              then '0 on time'
        when s.lateness_days <=  3      then '1 late 0-3d'
        when s.lateness_days <=  7      then '2 late 3-7d'
        when s.lateness_days <= 21      then '3 late 7-21d'
        else                                 '4 late 21d+'
    end                                             as lateness_band,

    -- Which stage consumed the largest share of this order's total time.
    -- The per-order version of the attribution mart.
    case
        when not s.has_delivery_outcome then null
        when s.carrier_transit_days  >= s.seller_handling_days
         and s.carrier_transit_days  >= s.payment_approval_days then 'carrier_transit'
        when s.seller_handling_days  >= s.payment_approval_days then 'seller_handling'
        else                                                         'payment_approval'
    end                                             as dominant_stage,

    -- Share of the promised window that was actually consumed. Below 1.0 the
    -- order beat its promise; the distribution of this ratio is the cleanest
    -- single view of how padded the estimates are.
    s.total_delivery_days / nullif(s.promised_days, 0)
                                                    as promise_utilisation

from {{ ref('int_order_spine') }} s
