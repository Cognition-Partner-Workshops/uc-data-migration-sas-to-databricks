/*
  mart_regulatory_rwa.sql
  Migrated from: Programs/Banking/monthly_regulatory_reporting.sas (Step 1)

  SAS Original:
    PROC SQL computing Risk-Weighted Assets (RWA) by account type
    and customer segment using Basel III standardized risk weights.
    Joins STG_BANK.CUST_ACCOUNTS_DAILY to ORA_DW.LOAN_DETAILS
    for LTV-based mortgage weighting.

  dbt Equivalent:
    SQL GROUP BY aggregation replaces PROC SQL
    CASE-based risk weight assignment mirrors SAS calculated columns
    dbt ref() replaces SAS LIBNAME references
*/

with accounts as (
    select * from {{ ref('int_account_metrics') }}
),

loan_details as (
    select * from {{ source('banking_raw', 'loan_details') }}
),

-- SAS: JOIN accounts to loan_details for LTV on secured products
account_loans as (
    select
        a.account_id,
        a.account_type,
        a.customer_segment,
        a.current_balance,
        l.ltv,
        -- SAS: Basel III standardized risk weight assignment
        case
            when a.account_type in ('CHK', 'SAV', 'MMA') then 0.00
            when a.account_type = 'CD'                    then 0.00
            when a.account_type = 'MTG' and l.ltv <= 0.80 then 0.35
            when a.account_type = 'MTG' and l.ltv > 0.80  then 0.50
            when a.account_type = 'HELC'                  then 0.50
            when a.account_type in ('AUTO', 'PERS')       then 0.75
            when a.account_type = 'CC'                    then 0.75
            when a.account_type = 'LOC'                   then 1.00
            else 1.00
        end as risk_weight
    from accounts a
    left join loan_details l
        on a.account_id = l.account_id
),

-- SAS: GROUP BY aggregation for RWA summary
rwa_summary as (
    select
        {{ var('prev_ym') }} as report_month,
        account_type,
        customer_segment,
        risk_weight,
        count(*) as n_accounts,
        sum(current_balance) as total_exposure,
        sum(current_balance * risk_weight) as rwa
    from account_loans
    group by 1, 2, 3, 4
)

select * from rwa_summary
order by account_type, customer_segment
