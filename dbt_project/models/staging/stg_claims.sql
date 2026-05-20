/*
  stg_claims.sql
  Migrated from: Programs/Insurance/claims_processing.sas (Step 1)

  SAS Original:
    DATA step ingesting RAW_INS.CLAIMS_FEED, validating against
    RAW_INS.POLICIES via hash object lookup, checking policy period
    and claimed amount vs sum insured.

  dbt Equivalent:
    Hash object lookup replaced by broadcast JOIN (see migration map §5).
    SAS IF/THEN validation replaced by SQL CASE for rejection_reason.
    Valid records are output; invalid records are filtered out.
*/

with claims_feed as (
    select * from {{ source('insurance_raw', 'claims') }}
),

policies as (
    select * from {{ source('insurance_raw', 'policies') }}
),

-- SAS: hash object h_pol(dataset: "RAW_INS.POLICIES(where=(STATUS='ACTIVE'))")
-- Replaced by broadcast join to active policies
validated as (
    select /*+ BROADCAST(p) */
        c.claim_id,
        c.policy_id,
        c.claimant_id,
        c.loss_date,
        c.reported_date,
        c.claim_type,
        c.claimed_amount,
        c.incurred_amount,
        c.paid_amount,
        c.reserved_amount,
        c.claim_status,
        c.description,
        p.policy_type,
        p.effective_date,
        p.expiration_date,
        p.sum_insured,
        p.deductible,
        p.customer_id,
        p.risk_category,
        p.annual_premium,

        -- SAS: validation error routing (IF/THEN → output CLAIMS_INVALID)
        case
            when p.policy_id is null
                then 'Policy not found or inactive'
            when c.loss_date < p.effective_date or c.loss_date > p.expiration_date
                then 'Loss date outside policy period'
            when c.claimed_amount > p.sum_insured
                then 'Claimed amount exceeds sum insured'
            else null
        end as rejection_reason

    from claims_feed c
    left join policies p
        on c.policy_id = p.policy_id
        and p.status = 'ACTIVE'
),

-- SAS: output WORK.CLAIMS_VALID (keep only valid records)
accepted as (
    select * from validated
    where rejection_reason is null
)

select * from accepted
