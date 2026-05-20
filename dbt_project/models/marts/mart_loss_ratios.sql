/*
  mart_loss_ratios.sql
  Migrated from: Programs/Insurance/policy_valuation.sas (Step 5)

  SAS Original:
    PROC MEANS aggregating STG_INS.POLICY_VALUATION by POLICY_TYPE
    to produce REPORTS.LOSS_RATIO_SUMMARY, then DATA step adding
    calculated aggregate loss ratio and combined ratio.

  dbt Equivalent:
    PROC MEANS with CLASS/VAR/OUTPUT replaced by SQL GROUP BY.
    SAS n= sum= mean= output statistics become SQL count/sum/avg.
*/

with policy_vals as (
    select * from {{ ref('int_policy_valuation') }}
),

-- SAS: PROC MEANS ... CLASS POLICY_TYPE
summary as (
    select
        policy_type,
        {{ format_policy_type('policy_type') }} as policy_type_desc,
        count(*) as n_policies,
        sum(ytd_earned_premium) as total_earned,
        sum(total_incurred) as total_incurred,
        sum(total_paid) as total_paid,
        sum(total_reserve) as total_reserves,
        sum(ibnr_estimate) as total_ibnr,
        sum(collected_premium) as total_collected,

        -- SAS: AGG_LOSS_RATIO = TOTAL_INCURRED / TOTAL_EARNED
        case
            when sum(ytd_earned_premium) > 0
            then sum(total_incurred) / sum(ytd_earned_premium)
            else null
        end as agg_loss_ratio,

        -- SAS: AGG_COMBINED_RATIO = AGG_LOSS_RATIO + 0.30
        case
            when sum(ytd_earned_premium) > 0
            then sum(total_incurred) / sum(ytd_earned_premium) + 0.30
            else null
        end as agg_combined_ratio,

        avg(loss_ratio) as avg_policy_loss_ratio,
        current_date() as report_date,
        current_timestamp() as load_timestamp

    from policy_vals
    group by policy_type
)

select * from summary
order by policy_type
