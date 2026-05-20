/*
  int_policy_valuation.sql
  Migrated from: Programs/Insurance/policy_valuation.sas (Steps 1-4)

  SAS Original:
    PROC SQL extracting in-force policies with earned premium calc,
    PROC SQL aggregating claims experience (12-month window),
    PROC SQL aggregating premium collections,
    DATA step MERGE BY POLICY_ID computing loss ratio, combined ratio,
    IBNR estimate, and total reserve.

  dbt Equivalent:
    MERGE BY → SQL LEFT JOIN (see migration map §6).
    SAS intck/intnx date functions → Databricks months_between/add_months.
    SAS calculated columns → SQL column aliases in CTEs.
    SAS format statements → dbt macro calls.
*/

with policies as (
    select * from {{ source('insurance_raw', 'policies') }}
),

claims as (
    select * from {{ source('insurance_raw', 'claims') }}
),

premiums as (
    select * from {{ source('insurance_raw', 'premiums') }}
),

-- SAS Step 1: Extract in-force policies with earned premium
inforce as (
    select
        p.policy_id,
        p.customer_id,
        p.policy_type,
        p.effective_date,
        p.expiration_date,
        p.annual_premium,
        p.sum_insured,
        p.deductible,
        p.risk_category,
        p.underwriting_class,
        p.agent_id,
        p.branch_code,

        -- SAS: intck('month', EFFECTIVE_DATE, "&val_date"d)
        months_between(current_date(), p.effective_date) as policy_age_months,

        -- SAS: intck('month', "&val_date"d, EXPIRATION_DATE)
        months_between(p.expiration_date, current_date()) as months_to_expiry,

        -- SAS: renewal due flag (expiring within 3 months)
        case
            when p.expiration_date <= add_months(current_date(), 3)
            then 'Y' else 'N'
        end as renewal_due_flag,

        -- SAS: earned premium (monthly pro-rata for YTD)
        p.annual_premium / 12 *
            least(12, months_between(
                least(current_date(), p.expiration_date),
                greatest(p.effective_date, trunc(current_date(), 'YEAR'))
            )) as ytd_earned_premium

    from policies p
    where p.status = 'ACTIVE'
        and p.effective_date <= current_date()
        and p.expiration_date >= current_date()
),

-- SAS Step 2: Claims experience (12-month window)
claims_exp as (
    select
        c.policy_id,
        count(distinct c.claim_id) as num_claims,
        sum(c.incurred_amount) as total_incurred,
        sum(c.paid_amount) as total_paid,
        sum(c.reserved_amount) as total_reserved,
        max(c.loss_date) as last_claim_date,
        sum(case
            when c.claim_status in ('OPEN', 'INV', 'ADJ', 'PEND')
            then c.reserved_amount else 0
        end) as open_reserves,
        sum(case
            when c.claim_status = 'DENY' then 1 else 0
        end) as denied_claims
    from claims c
    where c.loss_date >= add_months(current_date(), -12)
        and c.loss_date <= current_date()
    group by c.policy_id
),

-- SAS Step 3: Premium collections (YTD)
premium_coll as (
    select
        policy_id,
        sum(premium_amount) as collected_premium,
        sum(case
            when payment_status = 'RETURNED' then premium_amount else 0
        end) as returned_premium,
        max(payment_date) as last_payment_date,
        count(case when payment_status = 'LATE' then 1 end) as late_payments
    from premiums
    where payment_date >= trunc(current_date(), 'YEAR')
        and payment_date <= current_date()
    group by policy_id
),

-- SAS Step 4: MERGE BY POLICY_ID → LEFT JOIN
-- Computes loss ratio, combined ratio, IBNR, total reserve
merged as (
    select
        i.*,
        coalesce(ce.num_claims, 0) as num_claims,
        coalesce(ce.total_incurred, 0) as total_incurred,
        coalesce(ce.total_paid, 0) as total_paid,
        coalesce(ce.total_reserved, 0) as total_reserved,
        ce.last_claim_date,
        coalesce(ce.open_reserves, 0) as open_reserves,
        coalesce(ce.denied_claims, 0) as denied_claims,
        coalesce(pc.collected_premium, 0) as collected_premium,
        coalesce(pc.returned_premium, 0) as returned_premium,
        pc.last_payment_date,
        coalesce(pc.late_payments, 0) as late_payments,

        -- SAS: LOSS_RATIO = TOTAL_INCURRED / YTD_EARNED_PREMIUM
        case
            when i.ytd_earned_premium > 0
            then coalesce(ce.total_incurred, 0) / i.ytd_earned_premium
            else null
        end as loss_ratio,

        -- SAS: COMBINED_RATIO = LOSS_RATIO + 0.30 (30% expense load)
        case
            when i.ytd_earned_premium > 0
            then coalesce(ce.total_incurred, 0) / i.ytd_earned_premium + 0.30
            else null
        end as combined_ratio,

        -- SAS: PREMIUM_ADEQUATE flag
        case
            when i.ytd_earned_premium <= 0 then 'N'
            when coalesce(ce.total_incurred, 0) / i.ytd_earned_premium + 0.30 > 1.0 then 'N'
            else 'Y'
        end as premium_adequate,

        -- SAS: IBNR_ESTIMATE = max(0, YTD_EARNED_PREMIUM * 0.15 - TOTAL_PAID)
        greatest(0,
            i.ytd_earned_premium * 0.15 - coalesce(ce.total_paid, 0)
        ) as ibnr_estimate,

        -- SAS: TOTAL_RESERVE = OPEN_RESERVES + IBNR_ESTIMATE
        coalesce(ce.open_reserves, 0) +
            greatest(0, i.ytd_earned_premium * 0.15 - coalesce(ce.total_paid, 0))
            as total_reserve,

        {{ format_policy_type('i.policy_type') }} as policy_type_desc,
        {{ format_risk_category('i.risk_category') }} as risk_category_desc,

        current_date() as valuation_date,
        current_timestamp() as load_timestamp

    from inforce i
    left join claims_exp ce on i.policy_id = ce.policy_id
    left join premium_coll pc on i.policy_id = pc.policy_id
)

select * from merged
