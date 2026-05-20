/*
  mart_delinquency_aging.sql
  Migrated from: Programs/Banking/monthly_regulatory_reporting.sas (Step 2)

  SAS Original:
    PROC SQL creating REPORTS.DELINQUENCY_AGING with 30/60/90/120/180+
    delinquency buckets, joining STG_BANK.CUST_ACCOUNTS_DAILY to
    ORA_DW.LOAN_DETAILS for DAYS_PAST_DUE and PAST_DUE_AMOUNT.

  dbt Equivalent:
    SQL CASE replaces SAS bucket assignment.
    SQL GROUP BY replaces PROC SQL aggregation.
    Ordering uses a sort_key column instead of SAS "calculated" references.
*/

with accounts as (
    select * from {{ ref('int_account_metrics') }}
),

loan_details as (
    select * from {{ source('banking_raw', 'loan_details') }}
),

-- SAS: PROC SQL joining accounts to loan_details for delinquency fields
base as (
    select
        a.account_id,
        a.account_type,
        a.region_code,
        a.current_balance,
        coalesce(l.days_past_due, 0) as days_past_due,
        coalesce(l.past_due_amount, 0) as past_due_amount
    from accounts a
    left join loan_details l
        on a.account_id = l.account_id
    where a.account_type in ('MTG', 'AUTO', 'PERS', 'CC', 'LOC', 'HELC')
),

-- SAS: delinquency bucket assignment via CASE
bucketed as (
    select
        '{{ var("prev_ym") }}' as report_month,
        account_type,
        region_code,
        case
            when days_past_due = 0                      then 'Current'
            when days_past_due between 1 and 29         then '1-29'
            when days_past_due between 30 and 59        then '30-59'
            when days_past_due between 60 and 89        then '60-89'
            when days_past_due between 90 and 119       then '90-119'
            when days_past_due between 120 and 179      then '120-179'
            when days_past_due >= 180                   then '180+'
            else 'Unknown'
        end as delinq_bucket,
        case
            when days_past_due = 0                      then 0
            when days_past_due between 1 and 29         then 1
            when days_past_due between 30 and 59        then 2
            when days_past_due between 60 and 89        then 3
            when days_past_due between 90 and 119       then 4
            when days_past_due between 120 and 179      then 5
            when days_past_due >= 180                   then 6
            else 7
        end as bucket_sort_key,
        current_balance,
        past_due_amount
    from base
)

select
    report_month,
    account_type,
    {{ format_account_type('account_type') }} as account_type_desc,
    region_code,
    delinq_bucket,
    bucket_sort_key,
    count(*) as n_accounts,
    sum(current_balance) as total_balance,
    sum(past_due_amount) as total_past_due,
    current_timestamp() as load_timestamp

from bucketed
group by 1, 2, 3, 4, 5, 6
order by account_type, region_code, bucket_sort_key
