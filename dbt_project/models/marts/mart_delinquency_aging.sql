/*
  mart_delinquency_aging.sql
  Migrated from: Programs/Banking/monthly_regulatory_reporting.sas (Step 2)

  SAS Original:
    PROC SQL computing delinquency aging buckets (30/60/90/120/180+)
    by account type and region, joining accounts to loan details
    for DAYS_PAST_DUE and PAST_DUE_AMOUNT.

  dbt Equivalent:
    SQL CASE replaces SAS BETWEEN-based bucket assignment
    GROUP BY aggregation mirrors PROC SQL summary
    dbt ref() and source() replace SAS LIBNAME references
*/

with accounts as (
    select * from {{ ref('int_account_metrics') }}
),

loan_details as (
    select * from {{ source('banking_raw', 'loan_details') }}
),

-- SAS: JOIN accounts to loan_details for delinquency fields
delinquency_base as (
    select
        a.account_id,
        a.account_type,
        a.region_code,
        a.current_balance,
        l.days_past_due,
        l.past_due_amount,
        -- SAS: Delinquency bucket assignment (mirrors DELQBKT format logic)
        case
            when l.days_past_due = 0                     then 'Current'
            when l.days_past_due between 1 and 29        then '1-29'
            when l.days_past_due between 30 and 59       then '30-59'
            when l.days_past_due between 60 and 89       then '60-89'
            when l.days_past_due between 90 and 119      then '90-119'
            when l.days_past_due between 120 and 179     then '120-179'
            when l.days_past_due >= 180                  then '180+'
            else 'Unknown'
        end as delinq_bucket
    from accounts a
    left join loan_details l
        on a.account_id = l.account_id
    where a.account_type in ('MTG', 'AUTO', 'PERS', 'CC', 'LOC', 'HELC')
),

-- SAS: GROUP BY for aging summary
aging_summary as (
    select
        {{ var('prev_ym') }} as report_month,
        account_type,
        region_code,
        delinq_bucket,
        count(*) as n_accounts,
        sum(current_balance) as total_balance,
        sum(past_due_amount) as total_past_due
    from delinquency_base
    group by 1, 2, 3, 4
)

select * from aging_summary
order by
    account_type,
    region_code,
    case delinq_bucket
        when 'Current'  then 0
        when '1-29'     then 1
        when '30-59'    then 2
        when '60-89'    then 3
        when '90-119'   then 4
        when '120-179'  then 5
        when '180+'     then 6
        else 7
    end
