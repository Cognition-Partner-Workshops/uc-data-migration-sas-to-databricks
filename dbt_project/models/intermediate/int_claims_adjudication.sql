/*
  int_claims_adjudication.sql
  Migrated from: Programs/Insurance/claims_processing.sas (Steps 2-4)

  SAS Original:
    PROC SQL fraud screening join to TERA_DW.FRAUD_INDICATORS,
    DATA step auto-adjudication rules (IF/THEN routing to
    AUTO_ADJUDICATED or MANUAL_REVIEW), and claims register update.

  dbt Equivalent:
    Fraud screening JOIN replaces PROC SQL.
    SAS IF/THEN adjudication logic replaced by SQL CASE expressions.
    PROC APPEND to STG_INS.CLAIMS_REGISTER becomes a dbt table materialization.
*/

with claims as (
    select * from {{ ref('stg_claims') }}
),

fraud_indicators as (
    select * from {{ source('insurance_raw', 'fraud_indicators') }}
),

-- SAS: PROC SQL joining WORK.CLAIMS_VALID to TERA_DW.FRAUD_INDICATORS
fraud_screened as (
    select
        c.*,
        f.fraud_score,
        f.indicator_flags,
        case
            when f.fraud_score >= 80 then 'HIGH'
            when f.fraud_score >= 50 then 'MEDIUM'
            else 'LOW'
        end as fraud_risk
    from claims c
    left join fraud_indicators f
        on c.policy_id = f.policy_id
        and c.claimant_id = f.claimant_id
),

-- SAS: DATA step auto-adjudication rules
-- IF/THEN routing to WORK.AUTO_ADJUDICATED or WORK.MANUAL_REVIEW
adjudicated as (
    select
        *,
        case
            -- Auto-deny: high fraud risk → SIU referral
            when fraud_risk = 'HIGH'
                then 'DENY'
            -- Auto-approve: low risk, small claim, standard policy types
            when fraud_risk = 'LOW'
                and claimed_amount <= 5000
                and policy_type in ('AUTO', 'HOME', 'RENT')
                then 'APPR'
            -- Auto-approve: low risk, within 25% of sum insured, under 50k
            when fraud_risk = 'LOW'
                and claimed_amount <= sum_insured * 0.25
                and claimed_amount <= 50000
                then 'APPR'
            -- Everything else goes to manual review
            else 'PEND'
        end as adjudication_result,

        case
            when fraud_risk = 'HIGH'
                then 'High fraud risk - SIU referral'
            when fraud_risk = 'LOW'
                and claimed_amount <= 5000
                and policy_type in ('AUTO', 'HOME', 'RENT')
                then 'Auto-approved: low risk, small claim'
            when fraud_risk = 'LOW'
                and claimed_amount <= sum_insured * 0.25
                and claimed_amount <= 50000
                then 'Auto-approved: within 25% of sum insured'
            else concat_ws('; ',
                nullif(case when fraud_risk = 'MEDIUM' then 'Medium fraud risk' end, ''),
                nullif(case when claimed_amount > 50000 then 'Large claim' end, ''),
                nullif(case when claimed_amount > sum_insured * 0.25 then 'Exceeds 25% threshold' end, '')
            )
        end as adjudication_reason,

        case
            -- Approved: claimed minus deductible (floor at 0)
            when fraud_risk = 'LOW'
                and claimed_amount <= 5000
                and policy_type in ('AUTO', 'HOME', 'RENT')
                then greatest(0, claimed_amount - deductible)
            when fraud_risk = 'LOW'
                and claimed_amount <= sum_insured * 0.25
                and claimed_amount <= 50000
                then greatest(0, claimed_amount - deductible)
            -- Denied or pending: no approved amount
            when fraud_risk = 'HIGH'
                then 0
            else null
        end as approved_amount,

        {{ format_claim_status('claim_status') }} as claim_status_desc,
        {{ format_policy_type('policy_type') }} as policy_type_desc,

        current_date() as processing_date,
        current_timestamp() as load_timestamp

    from fraud_screened
)

select * from adjudicated
