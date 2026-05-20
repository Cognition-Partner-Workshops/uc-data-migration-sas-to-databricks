/*
  stg_claims.sql
  Migrated from: Programs/Insurance/claims_processing.sas (Steps 1-2)

  SAS Original:
    Step 1: DATA step validating incoming claims feed against policy data
    using a hash object lookup (declare hash h_pol) for policy validation.
    Step 2: PROC SQL fraud screening by joining to TERA_DW.FRAUD_INDICATORS.

  dbt Equivalent:
    Hash object lookup → SQL JOIN (broadcast join hint for Spark)
    DATA step IF/THEN validation → SQL CASE for rejection routing
    PROC SQL fraud join → SQL LEFT JOIN with CASE-based risk classification
*/

with claims_raw as (
    select * from {{ source('insurance_raw', 'claims') }}
),

-- SAS: Hash object h_pol loaded from RAW_INS.POLICIES(where=(STATUS='ACTIVE'))
active_policies as (
    select
        policy_id,
        policy_type,
        effective_date,
        expiration_date,
        sum_insured,
        deductible
    from {{ source('insurance_raw', 'policies') }}
    where status = 'ACTIVE'
),

-- SAS: Hash lookup + validation (rc = h_pol.find())
-- Replace hash object with broadcast join
validated as (
    select /*+ BROADCAST(p) */
        c.*,
        p.policy_type,
        p.effective_date,
        p.expiration_date,
        p.sum_insured,
        p.deductible,
        case
            when p.policy_id is null
                then 'Policy not found or inactive'
            when c.loss_date < p.effective_date or c.loss_date > p.expiration_date
                then 'Loss date outside policy period'
            when c.claimed_amount > p.sum_insured
                then 'Claimed amount exceeds sum insured'
            else null
        end as validation_error
    from claims_raw c
    left join active_policies p
        on c.policy_id = p.policy_id
),

-- SAS: output WORK.CLAIMS_VALID (only valid claims pass through)
valid_claims as (
    select * from validated
    where validation_error is null
),

-- SAS Step 2: Fraud screening via PROC SQL join to TERA_DW.FRAUD_INDICATORS
fraud_indicators as (
    select * from {{ source('insurance_raw', 'fraud_indicators') }}
),

fraud_screened as (
    select
        v.*,
        f.fraud_score,
        f.indicator_flags,
        -- SAS: CASE-based fraud risk classification
        case
            when f.fraud_score >= 80 then 'HIGH'
            when f.fraud_score >= 50 then 'MEDIUM'
            else 'LOW'
        end as fraud_risk
    from valid_claims v
    left join fraud_indicators f
        on v.policy_id = f.policy_id
        and v.claimant_id = f.claimant_id
)

select * from fraud_screened
