/*
  mart_customer_pnl.sql
  Migrated from: Programs/Reports/customer_profitability.sas (Steps 1-4)

  SAS Original:
    Step 1: PROC SQL computing interest income by customer from
            STG_BANK.CUST_ACCOUNTS_DAILY (lending income - deposit cost).
    Step 2: PROC SQL computing fee income from CURATED.DAILY_TRANSACTIONS.
    Step 3: PROC SQL computing expected credit loss from CURATED.RISK_SCORES.
    Step 4: DATA step MERGE BY CUSTOMER_ID assembling P&L with
            operating cost allocation, net profit, ROA, and tier.

  dbt Equivalent:
    Multi-source merge → multi-ref LEFT JOIN.
    SAS calculated columns → SQL CASE expressions.
    SAS macro variable &report_month becomes dbt var('prev_ym').
*/

with accounts as (
    select * from {{ ref('int_account_metrics') }}
),

transactions as (
    select * from {{ ref('mart_daily_transactions') }}
),

risk_scores as (
    select * from {{ ref('mart_risk_scores') }}
),

-- SAS Step 1: Interest income by customer
interest_income as (
    select
        customer_id,
        max(customer_segment) as customer_segment,
        max(region_code) as region_code,
        max(branch_id) as branch_id,
        -- Lending income: loan-type accounts × interest rate / 12
        sum(case
            when account_type in ('MTG', 'AUTO', 'PERS', 'CC', 'LOC', 'HELC')
            then current_balance * interest_rate / 12
            else 0
        end) as lending_income,
        -- Deposit cost: deposit-type accounts × interest rate / 12
        sum(case
            when account_type in ('CHK', 'SAV', 'MMA', 'CD', 'IRA')
            then current_balance * interest_rate / 12
            else 0
        end) as deposit_cost,
        count(distinct account_id) as num_accounts,
        sum(current_balance) as total_relationship
    from accounts
    group by customer_id
),

-- SAS Step 2: Fee income from transactions
fee_income as (
    select
        customer_id,
        sum(case
            when transaction_type = 'FEE'
            then abs(transaction_amount) else 0
        end) as fee_income,
        sum(case
            when transaction_type = 'INT'
            then abs(transaction_amount) else 0
        end) as int_credited,
        count(*) as txn_volume
    from transactions
    group by customer_id
),

-- SAS Step 3: Expected credit loss by customer (latest score date)
ecl as (
    select
        customer_id,
        sum(expected_loss) as total_ecl
    from risk_scores
    where score_date = (
        select max(score_date) from risk_scores
    )
    group by customer_id
),

-- SAS Step 4: MERGE BY CUSTOMER_ID → multi-ref LEFT JOIN
pnl as (
    select
        ii.customer_id,
        ii.customer_segment,
        {{ format_customer_segment('ii.customer_segment') }} as customer_segment_desc,
        ii.region_code,
        ii.branch_id,
        ii.num_accounts,
        ii.total_relationship,
        ii.lending_income,
        ii.deposit_cost,

        -- SAS: NET_INTEREST_INCOME = LENDING_INCOME - DEPOSIT_COST
        ii.lending_income - ii.deposit_cost as net_interest_income,

        coalesce(fi.fee_income, 0) as fee_income,
        coalesce(fi.int_credited, 0) as int_credited,
        coalesce(fi.txn_volume, 0) as txn_volume,

        -- SAS: OPERATING_COST = NUM_ACCOUNTS * 15
        ii.num_accounts * 15 as operating_cost,

        coalesce(e.total_ecl, 0) as total_ecl,

        -- SAS: TOTAL_REVENUE = NET_INTEREST_INCOME + FEE_INCOME
        (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
            as total_revenue,

        -- SAS: NET_PROFIT = TOTAL_REVENUE - OPERATING_COST - TOTAL_ECL
        (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
            - (ii.num_accounts * 15)
            - coalesce(e.total_ecl, 0)
            as net_profit,

        -- SAS: ROA = (NET_PROFIT * 12) / TOTAL_RELATIONSHIP (annualized)
        case
            when ii.total_relationship > 0
            then (
                (ii.lending_income - ii.deposit_cost)
                + coalesce(fi.fee_income, 0)
                - (ii.num_accounts * 15)
                - coalesce(e.total_ecl, 0)
            ) * 12 / ii.total_relationship
            else null
        end as roa,

        -- SAS: profitability tier assignment via IF/THEN
        case
            when (ii.lending_income - ii.deposit_cost)
                 + coalesce(fi.fee_income, 0)
                 - (ii.num_accounts * 15)
                 - coalesce(e.total_ecl, 0) >= 500
                then 'Highly Profitable'
            when (ii.lending_income - ii.deposit_cost)
                 + coalesce(fi.fee_income, 0)
                 - (ii.num_accounts * 15)
                 - coalesce(e.total_ecl, 0) >= 100
                then 'Profitable'
            when (ii.lending_income - ii.deposit_cost)
                 + coalesce(fi.fee_income, 0)
                 - (ii.num_accounts * 15)
                 - coalesce(e.total_ecl, 0) >= 0
                then 'Marginal'
            else 'Unprofitable'
        end as profit_tier,

        '{{ var("prev_ym") }}' as report_month,
        current_timestamp() as load_timestamp

    from interest_income ii
    left join fee_income fi on ii.customer_id = fi.customer_id
    left join ecl e on ii.customer_id = e.customer_id
)

select * from pnl
