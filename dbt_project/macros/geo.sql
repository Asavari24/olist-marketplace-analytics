{#
    Great-circle distance in kilometres.

    Road distance in Brazil is materially longer than great-circle -- the
    literature puts the detour factor around 1.3-1.4 for long hauls -- so this
    is a lower bound on how far a parcel actually travelled. It is used as an
    explanatory variable, never as a cost input, and the marts name it
    `route_distance_km` with `_straight_line` in the description so nobody
    mistakes it for a routed distance.
#}
{% macro haversine_km(lat1, lon1, lat2, lon2) %}
    (
        6371.0088 * 2 * asin(
            sqrt(
                  pow(sin(radians(({{ lat2 }}) - ({{ lat1 }})) / 2), 2)
                + cos(radians({{ lat1 }})) * cos(radians({{ lat2 }}))
                * pow(sin(radians(({{ lon2 }}) - ({{ lon1 }})) / 2), 2)
            )
        )
    )
{% endmacro %}


{#
    Brazil's five macro-regions. State-level results are too granular to read
    at a glance and too noisy for the small northern states, so most marts
    carry the region alongside the state.
#}
{% macro br_region(state_col) %}
    case
        when {{ state_col }} in ('AC','AP','AM','PA','RO','RR','TO')            then 'Norte'
        when {{ state_col }} in ('AL','BA','CE','MA','PB','PE','PI','RN','SE')  then 'Nordeste'
        when {{ state_col }} in ('DF','GO','MT','MS')                           then 'Centro-Oeste'
        when {{ state_col }} in ('ES','MG','RJ','SP')                           then 'Sudeste'
        when {{ state_col }} in ('PR','RS','SC')                                then 'Sul'
        else 'Desconhecido'
    end
{% endmacro %}
