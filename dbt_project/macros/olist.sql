{#
    Lateness against the delivery promise.

    order_estimated_delivery_date is a DATE stored at midnight. The promise
    Olist shows the buyer is "arrives by <date>", which is satisfied by any
    delivery before that day is over. Comparing a delivery timestamp directly
    against the midnight value therefore marks a whole day's worth of on-time
    deliveries late -- measured on this extract it moves the late rate from
    6.77% to 8.11%, a 20% relative overstatement of the failure rate.

    The promise deadline is the END of the estimated day, plus whatever grace
    the `late_grace_hours` var allows.
#}
{% macro promise_deadline(estimated_date_col) %}
    (
        date_trunc('day', {{ estimated_date_col }})
        + interval 1 day
        + interval ({{ var('late_grace_hours') }}) hour
    )
{% endmacro %}


{#
    Hours between two timestamps as a float. epoch() returns seconds; writing
    the division out once here keeps every duration in the project on the same
    definition and the same units.
#}
{% macro hours_between(start_ts, end_ts) %}
    (epoch({{ end_ts }}) - epoch({{ start_ts }})) / 3600.0
{% endmacro %}


{#
    Days between two timestamps as a float, signed. Positive means end is
    later. Fractional days are kept: rounding to whole days before averaging
    biases every stage mean by up to half a day, and the delivery
    decomposition adds four such stages together.
#}
{% macro days_between(start_ts, end_ts) %}
    (epoch({{ end_ts }}) - epoch({{ start_ts }})) / 86400.0
{% endmacro %}


{#
    The analysis window predicate, applied on purchase timestamp. Spelled once
    so every model that claims to be "in window" means the same thing.
#}
{% macro in_analysis_window(purchase_ts_col) %}
    (
        {{ purchase_ts_col }} >= cast('{{ var("analysis_start") }}' as timestamp)
        and {{ purchase_ts_col }} < cast('{{ var("analysis_end") }}' as timestamp) + interval 1 day
    )
{% endmacro %}
