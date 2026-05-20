/*
  mart_customer_pnl.sql
  Migrated from: Programs/Reports/customer_profitability.sas (Steps 1-4)

  SAS Original:
    Step 1: PROC SQL computing interest income by customer
            (lending income, deposit cost, net interest margin)
    Step 2: PROC SQL computing fee income from transactions
    Step 3: PROC SQL computing expected credit loss by customer
    Step 4: DATA step MERGE BY CUSTOMER_ID assembling full P&L
            with operating cost allocation and profitability tiers

  dbt Equivalent:
    PROC SQL aggregations → CTEs with GROUP BY
    DATA step MERGE BY → SQL LEFT JOINs
    SAS calculated fields (TOTAL_REVENUE, NET_PROFIT, ROA) → SQL expressions
    SAS IF/THEN tier assignment → SQL CASE
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
        a.customer_id,
        max(a.customer_segment) as customer_segment,
        max(a.region_code) as region_code,
        max(a.branch_id) as branch_id,
        -- SAS: Lending income (loan interest accrual)
        sum(case when a.account_type in ('MTG', 'AUTO', 'PERS', 'CC', 'LOC', 'HELC')
            then a.current_balance * a.interest_rate / 12 else 0 end)
            as lending_income,
        -- SAS: Deposit cost (interest paid on deposits)
        sum(case when a.account_type in ('CHK', 'SAV', 'MMA', 'CD', 'IRA')
            then a.current_balance * a.interest_rate / 12 else 0 end)
            as deposit_cost,
        count(distinct a.account_id) as num_accounts,
        sum(a.current_balance) as total_relationship
    from accounts a
    group by a.customer_id
),

-- SAS Step 2: Fee income from transactions (current month)
fee_income as (
    select
        t.customer_id,
        sum(case when t.transaction_type = 'FEE'
            then abs(t.transaction_amount) else 0 end) as fee_income,
        sum(case when t.transaction_type = 'INT'
            then abs(t.transaction_amount) else 0 end) as int_credited,
        count(*) as txn_volume
    from transactions t
    where t.transaction_date >= date_trunc('MONTH', current_date())
      and t.transaction_date <= current_date()
    group by t.customer_id
),

-- SAS Step 3: Expected credit loss by customer (latest score date)
ecl as (
    select
        r.customer_id,
        sum(r.expected_loss) as total_ecl
    from risk_scores r
    where r.score_date = (
        select max(score_date) from risk_scores
        where score_date <= current_date()
    )
    group by r.customer_id
),

-- SAS Step 4: Customer P&L assembly (DATA step MERGE BY CUSTOMER_ID)
customer_pnl as (
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
        coalesce(ecl.total_ecl, 0) as total_ecl,

        -- SAS: OPERATING_COST = NUM_ACCOUNTS * 15 ($15/account/month)
        ii.num_accounts * 15 as operating_cost,

        -- SAS: TOTAL_REVENUE = sum(NET_INTEREST_INCOME, FEE_INCOME)
        (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
            as total_revenue,

        -- SAS: NET_PROFIT = TOTAL_REVENUE - OPERATING_COST - TOTAL_ECL
        (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
            - (ii.num_accounts * 15)
            - coalesce(ecl.total_ecl, 0)
            as net_profit,

        -- SAS: ROA (annualized) = (NET_PROFIT * 12) / TOTAL_RELATIONSHIP
        case
            when ii.total_relationship > 0
            then (
                (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
                - (ii.num_accounts * 15) - coalesce(ecl.total_ecl, 0)
            ) * 12 / ii.total_relationship
            else null
        end as roa,

        -- SAS: Profitability tier assignment
        case
            when (
                (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
                - (ii.num_accounts * 15) - coalesce(ecl.total_ecl, 0)
            ) >= 500 then 'Highly Profitable'
            when (
                (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
                - (ii.num_accounts * 15) - coalesce(ecl.total_ecl, 0)
            ) >= 100 then 'Profitable'
            when (
                (ii.lending_income - ii.deposit_cost) + coalesce(fi.fee_income, 0)
                - (ii.num_accounts * 15) - coalesce(ecl.total_ecl, 0)
            ) >= 0 then 'Marginal'
            else 'Unprofitable'
        end as profit_tier,

        {{ var('prev_ym') }} as report_month

    from interest_income ii
    left join fee_income fi on ii.customer_id = fi.customer_id
    left join ecl on ii.customer_id = ecl.customer_id
)

select * from customer_pnl
