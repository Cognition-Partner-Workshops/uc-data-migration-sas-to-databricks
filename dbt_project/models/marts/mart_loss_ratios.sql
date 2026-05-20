/*
  mart_loss_ratios.sql
  Migrated from: Programs/Insurance/policy_valuation.sas (Step 5)

  SAS Original:
    PROC MEANS with CLASS POLICY_TYPE computing aggregate loss ratios,
    then a DATA step adding calculated AGG_LOSS_RATIO and AGG_COMBINED_RATIO.

  dbt Equivalent:
    SQL GROUP BY replaces PROC MEANS + CLASS statement
    Aggregate ratios computed inline (no second DATA step needed)
*/

with policy_valuation as (
    select * from {{ ref('int_policy_valuation') }}
),

-- SAS: PROC MEANS ... CLASS POLICY_TYPE
loss_summary as (
    select
        policy_type,
        {{ format_policy_type('policy_type') }} as policy_type_desc,
        count(*) as n_policies,
        sum(ytd_earned_premium) as total_earned,
        sum(total_incurred) as total_incurred,
        sum(total_paid) as total_paid,
        sum(total_reserve) as total_reserves,
        sum(ibnr_estimate) as total_ibnr,

        -- SAS: AGG_LOSS_RATIO = TOTAL_INCURRED / TOTAL_EARNED
        case
            when sum(ytd_earned_premium) > 0
            then sum(coalesce(total_incurred, 0)) / sum(ytd_earned_premium)
            else null
        end as agg_loss_ratio,

        -- SAS: AGG_COMBINED_RATIO = AGG_LOSS_RATIO + 0.30
        case
            when sum(ytd_earned_premium) > 0
            then (sum(coalesce(total_incurred, 0)) / sum(ytd_earned_premium)) + 0.30
            else null
        end as agg_combined_ratio

    from policy_valuation
    group by policy_type
)

select * from loss_summary
