/*
  int_claims_adjudication.sql
  Migrated from: Programs/Insurance/claims_processing.sas (Step 3)

  SAS Original:
    DATA step applying auto-adjudication rules:
    - Auto-deny: fraud high risk → DENY + SIU referral
    - Auto-approve: low risk, small claim (<=5000, specific policy types)
    - Auto-approve: low risk, within 25% of sum insured and <=50000
    - Manual review: everything else (medium fraud, large claim, etc.)

  dbt Equivalent:
    SQL CASE expressions replace SAS IF/THEN/ELSE adjudication logic
    Approved amount calculation uses GREATEST() instead of SAS max()
    SAS output routing (AUTO_ADJUDICATED vs MANUAL_REVIEW) becomes
    a single model with adjudication_result column for downstream filtering
*/

with claims as (
    select * from {{ ref('stg_claims') }}
),

adjudicated as (
    select
        *,

        -- SAS: Adjudication result routing
        case
            -- SAS: Auto-deny: fraud high risk
            when fraud_risk = 'HIGH'
                then 'DENY'
            -- SAS: Auto-approve: low risk, small claim
            when fraud_risk = 'LOW'
                 and claimed_amount <= 5000
                 and policy_type in ('AUTO', 'HOME', 'RENT')
                then 'APPR'
            -- SAS: Auto-approve: within 25% of sum insured and <= 50000
            when fraud_risk = 'LOW'
                 and claimed_amount <= sum_insured * 0.25
                 and claimed_amount <= 50000
                then 'APPR'
            -- SAS: Everything else → manual review
            else 'PEND'
        end as adjudication_result,

        -- SAS: Adjudication reason
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

        -- SAS: Approved amount (deductible subtracted for approvals)
        case
            when fraud_risk = 'HIGH'
                then 0
            when fraud_risk = 'LOW'
                 and claimed_amount <= 5000
                 and policy_type in ('AUTO', 'HOME', 'RENT')
                then greatest(0, claimed_amount - deductible)
            when fraud_risk = 'LOW'
                 and claimed_amount <= sum_insured * 0.25
                 and claimed_amount <= 50000
                then greatest(0, claimed_amount - deductible)
            else null
        end as approved_amount,

        -- SAS: CLAIM_STATUS = ADJUDICATION_RESULT (format $CLMSTAT.)
        {{ format_claim_status(
            "case
                when fraud_risk = 'HIGH' then 'DENY'
                when fraud_risk = 'LOW' and claimed_amount <= 5000 and policy_type in ('AUTO','HOME','RENT') then 'APPR'
                when fraud_risk = 'LOW' and claimed_amount <= sum_insured * 0.25 and claimed_amount <= 50000 then 'APPR'
                else 'PEND'
            end"
        ) }} as claim_status_desc,

        current_date() as processing_date

    from claims
)

select * from adjudicated
