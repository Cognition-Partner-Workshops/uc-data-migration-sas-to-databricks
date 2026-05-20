/*
  mart_regulatory_rwa.sql
  Migrated from: Programs/Banking/monthly_regulatory_reporting.sas (Step 1)

  SAS Original:
    PROC SQL aggregating risk-weighted assets by account type and
    customer segment using Basel III standardized risk weights.
    Joins STG_BANK.CUST_ACCOUNTS_DAILY to ORA_DW.LOAN_DETAILS.

  dbt Equivalent:
    SQL GROUP BY replaces PROC SQL aggregation.
    SAS calculated column references become standard SQL column aliases.
    SAS macro variable &report_month becomes dbt var('prev_ym').
    LTV derived from int_account_metrics replaces the inline join to LOAN_DETAILS.
*/

with accounts as (
    select * from {{ ref('int_account_metrics') }}
),

loan_details as (
    select * from {{ source('banking_raw', 'loan_details') }}
),

-- SAS: PROC SQL joining STG_BANK.CUST_ACCOUNTS_DAILY to ORA_DW.LOAN_DETAILS
base as (
    select
        a.account_id,
        a.account_type,
        a.customer_segment,
        a.current_balance,
        case
            when l.collateral_value > 0
            then a.current_balance / l.collateral_value
            else null
        end as ltv
    from accounts a
    left join loan_details l
        on a.account_id = l.account_id
),

-- SAS: Basel III risk weight assignment via CASE
rwa_calc as (
    select
        '{{ var("prev_ym") }}' as report_month,
        account_type,
        customer_segment,
        case
            when account_type in ('CHK', 'SAV', 'MMA') then 0.00
            when account_type = 'CD'                    then 0.00
            when account_type = 'MTG' and ltv <= 0.80   then 0.35
            when account_type = 'MTG' and ltv > 0.80    then 0.50
            when account_type = 'HELC'                  then 0.50
            when account_type in ('AUTO', 'PERS')       then 0.75
            when account_type = 'CC'                    then 0.75
            when account_type = 'LOC'                   then 1.00
            else 1.00
        end as risk_weight,
        count(*) as n_accounts,
        sum(current_balance) as total_exposure,
        sum(
            current_balance * case
                when account_type in ('CHK', 'SAV', 'MMA') then 0.00
                when account_type = 'CD'                    then 0.00
                when account_type = 'MTG' and ltv <= 0.80   then 0.35
                when account_type = 'MTG' and ltv > 0.80    then 0.50
                when account_type = 'HELC'                  then 0.50
                when account_type in ('AUTO', 'PERS')       then 0.75
                when account_type = 'CC'                    then 0.75
                when account_type = 'LOC'                   then 1.00
                else 1.00
            end
        ) as rwa
    from base
    group by 1, 2, 3, 4
)

select
    report_month,
    account_type,
    {{ format_account_type('account_type') }} as account_type_desc,
    customer_segment,
    {{ format_customer_segment('customer_segment') }} as customer_segment_desc,
    risk_weight,
    n_accounts,
    total_exposure,
    rwa,
    current_timestamp() as load_timestamp

from rwa_calc
order by account_type, customer_segment
