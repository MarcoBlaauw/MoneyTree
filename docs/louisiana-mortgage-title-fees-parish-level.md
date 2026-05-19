# Louisiana Mortgage And Title Fee Research

## Purpose

Normalize the Louisiana parish-level mortgage, recording, title insurance, and related loan-fee research into implementation-ready notes for MoneyTree's Loan Center fee subsystem.

This document is research input for modeled estimates only. It is not legal advice, lender guidance, or a compliance determination.

## Implementation Readiness

| Area | Status | Implementation use |
| --- | --- | --- |
| Louisiana statewide mortgage recording model | Usable | Seed/update statewide Louisiana refinance recording assumptions. |
| Orleans Parish documentary transaction tax | Usable | Seed/update Orleans-specific fixed local tax rule. |
| Roadmap parish recording profiles | Usable | Add/update St. Charles, Jefferson, Orleans, St. John the Baptist, St. Tammany, and East Baton Rouge parish overrides. |
| Mortgage certificate and cancellation fees | Usable | Add as modeled government/recording fee types or jurisdiction rules. |
| Louisiana title insurance lender policy schedule | Usable for first tier range | Replace broad percent estimate with tiered premium calculator through $250k, then extend after full table extraction. |
| Reissue/refinance credit | Usable with caution | Add future title-insurance adjustment option; do not auto-apply without user confirmation. |
| Closing/notary/title service fees | Partial | Keep as service-fee ranges; source-specific, not government-fixed. |
| Auto/personal/student loan fee and rate notes | Partial | Keep as future non-mortgage research; do not seed deterministic defaults yet without source URLs and provider terms. |

## Source Caveat

The raw markdown research is tracked in `docs/deep-research-report-2.md`. The source-bearing PDF export is tracked in `docs/loan-fee-deep-research-sources.pdf`.

For database seed data, every rule should include:

- `source_label`
- `source_url`
- `last_verified_at`
- `confidence_level`
- `notes`

## Source URL Map

Use these URLs as source metadata in fee rules and jurisdiction profiles.

| Source label | Source URL | Implementation use |
| --- | --- | --- |
| St. Charles Parish recorder summary | `https://www.deeds.com/recorder/louisiana/saint-charles/` | St. Charles recording, page, indexed-name fee assumptions. |
| Orleans Civil Clerk land records fee sheet | `https://www.orleanscivilclerk.com/images/Land%20Records%20Fee%20Sheet.pdf` | Orleans recording, certificate, cancellation, and documentary tax assumptions. |
| St. John the Baptist Parish recorder summary | `https://www.deeds.com/recorder/louisiana/st-john-the-baptist/` | St. John recording, page, indexed-name, certificate, and cancellation assumptions. |
| St. Tammany Parish recorder summary | `https://www.deeds.com/recorder/louisiana/saint-tammany/` | St. Tammany recording, page, indexed-name, cancellation, and parish fee assumptions. |
| East Baton Rouge recording fee schedule | `https://static1.squarespace.com/static/666af37e5bc38966393081e0/t/667ac889f12d8660ab339aa8/1719322761497/22_Recording+Fee+Schedule+8_2017.pdf` | East Baton Rouge recording, cancellation, LCRAA, and judicial building fund assumptions. |
| LATISSO title insurance rate manual | `https://www.virtualunderwriter.com/-/media/files/virtualunderwriter/imported/pdfs/latisso-rate-forms-manualeffective-8-1-2024.pdf` | Louisiana lender title insurance premium schedule, endorsements, and refinance/reissue rules. |
| Jefferson Parish recorder summary | `https://www.deeds.com/recorder/louisiana/jefferson/` | Jefferson recording, page, indexed-name, and certificate assumptions. |
| Bankrate average auto loan interest rates by credit score | `https://www.bankrate.com/loans/auto-loans/average-car-loan-interest-rates-by-credit-score/` | Future auto benchmark research; do not use for guaranteed offers. |
| Louisiana OMV vehicle registration, title, and plate fees | `https://www.expresslane.org/vehicles/vehicle-registration-title-plate-fees/` | Future Louisiana auto title/lien fee assumptions. |
| CFPB Regulation Z 1026.47 | `https://www.consumerfinance.gov/rules-policy/regulations/1026/47/` | Future APR disclosure semantics and education copy. |
| CFPB TILA examination procedures | `https://files.consumerfinance.gov/f/201308_cfpb_tila-narrative-exam-procedures.pdf` | Future APR/finance-charge validation reference. |
| NASFAA origination fees issue brief | `https://www.nasfaa.org/issue_brief_origination_fees` | Future federal student loan origination fee reference. |
| Debt.org origination fee explainer | `https://www.debt.org/credit/loans/origination-fees/` | Future personal-loan fee research; lower confidence than official sources. |

## Canonical Fee Codes

Suggested canonical fee codes for implementation:

| Fee code | Category | Kind | True cost? | Timing cost? | Government/local? |
| --- | --- | --- | --- | --- | --- |
| `recording_fee` | recording | fee | yes | no | yes |
| `indexed_name_fee` | recording | fee | yes | no | yes |
| `mortgage_certificate_fee` | recording | fee | yes | no | yes |
| `mortgage_cancellation_or_release` | recording | fee | yes | no | yes |
| `electronic_recording_surcharge` | recording | fee | yes | no | yes |
| `orleans_documentary_transaction_tax` | local_tax | fee | yes | no | yes |
| `title_insurance_lender_policy` | title_insurance | fee | yes | no | no, regulated rate |
| `title_insurance_expanded_coverage_uplift` | title_insurance | fee | yes | no | no, regulated rate |
| `title_insurance_reissue_credit` | title_insurance | credit | yes | no | no, regulated rate |
| `title_endorsements` | title_insurance | fee | yes | no | no, regulated rate |
| `settlement_or_closing_fee` | settlement | fee | yes | no | no |
| `attorney_or_notary_or_document_fee` | settlement | fee | yes | no | no |
| `title_exam_fee` | title | fee | yes | no | no |
| `abstract_search_fee` | title | fee | yes | no | no |
| `closing_protection_letter_fee` | title | fee | yes | no | no |

## Louisiana Recording Fee Model

Louisiana should not be modeled as a statewide percentage mortgage-tax or transfer-tax state for normal residential refinance.

Recommended statewide assumptions:

```text
statewide_mortgage_tax_percent: 0
statewide_transfer_tax_percent: 0
local_transaction_tax_possible: true
requires_parish_check: true
confidence: moderate
```

### Statewide Recording Schedule

The research confirms a statewide tiered recording model under La. R.S. 13:844, with parish schedules commonly reflecting:

| Document size | Base recording fee |
| --- | ---: |
| 1-5 pages | $100-$105 |
| 6-25 pages | $200-$205 |
| 26-50 pages | $300-$305 |
| Over 50 pages | $300-$305 + $5 per page after 50 |

Implementation recommendation:

```text
fee_code: recording_fee
state_code: LA
county_or_parish: null
calculation_method: fixed_amount
fixed_low_amount: 105
fixed_expected_amount: 205
fixed_high_amount: 305
extreme_high_threshold_amount: 605
confidence_level: moderate
requires_local_verification: true
notes: "Louisiana statewide recording estimate. Parish-specific schedules should be verified."
```

### Indexed Name Fee

Most schedules include up to 10 indexed names, then charge about $5 per additional name.

Implementation recommendation for v1:

```text
fee_code: indexed_name_fee
state_code: LA
county_or_parish: null
calculation_method: manual_only
fixed_expected_amount: 0
confidence_level: moderate
requires_local_verification: true
notes: "Commonly $5 per indexed name after the first 10; only apply when document/name count is known."
```

Do not automatically add this fee unless document/indexed-name count is known or user enters it.

### Mortgage Certificate Fee

Research indicates a common mortgage certificate/lien certificate structure:

| Component | Amount |
| --- | ---: |
| First name | $20 |
| Each additional name | $10 |

Implementation recommendation:

```text
fee_code: mortgage_certificate_fee
state_code: LA
county_or_parish: null
calculation_method: fixed_amount
fixed_low_amount: 20
fixed_expected_amount: 20
fixed_high_amount: 40
confidence_level: moderate
requires_local_verification: true
notes: "Modeled first-name mortgage certificate fee; additional names may add $10 each."
```

### Mortgage Cancellation Or Release

Research indicates release/cancellation charges commonly around $50-$55, with some reduced-cost handling when original note is surrendered.

Implementation recommendation:

```text
fee_code: mortgage_cancellation_or_release
state_code: LA
county_or_parish: null
calculation_method: fixed_amount
fixed_low_amount: 55
fixed_expected_amount: 55
fixed_high_amount: 105
confidence_level: moderate
requires_local_verification: true
notes: "Likely payoff/release-related government recording cost; not a lender fee."
```

### Electronic Recording Surcharge

Research indicates a $5 e-recording/LCRAA-style surcharge per recorded document.

Implementation recommendation:

```text
fee_code: electronic_recording_surcharge
state_code: LA
county_or_parish: null
calculation_method: fixed_amount
fixed_low_amount: 5
fixed_expected_amount: 5
fixed_high_amount: 10
confidence_level: moderate
requires_local_verification: true
notes: "Modeled e-recording/LCRAA surcharge. Verify whether parish schedule already includes this amount."
```

Do not double-count this when a parish schedule already includes the surcharge in its base recording fee.

## Parish-Specific Rules

### Roadmap Parish Profile Values

These values are normalized from the PDF source report. Store them as jurisdiction rules where the current schema supports the field, or keep unsupported fields in `raw_payload`/`notes` until a narrower data model exists.

| Parish | Recording base | Per-page after threshold | Indexed names | Mortgage certificate | Cancellation/release | E-recording/local fees | Confidence |
| --- | --- | ---: | ---: | --- | --- | --- | --- |
| St. Charles | 1-5 pages $105; 6-25 $205; 26-50 $305; 51+ $305 + $5/page | $5 | $5 after 10 names | Not listed | $55 standard release, source basis moderate | $5 LCRAA included in base | Moderate-high |
| Jefferson | 1-5 pages $105; 6-25 $205; 26-50 $305; 51+ $305 + $5/page | $5 | $5 after 10 names | $20 first name, $10 additional | Not explicitly listed; model from statewide/nearby parish until verified | $5 LCRAA included | High for recording; low for cancellation |
| Orleans | 1-5 pages $100; 6-25 $200; 26-50 $300; 51+ $300 + $5/page | $5 | $5 after 10 names | $20 first name, $10 additional | $50 per instrument, or $10 with original note | $30 building fund; no separate e-recording assumption | High |
| St. John the Baptist | 1-5 pages $105; 6-25 $205; 26-50 $305; 51+ $305 + $5/page | $5 | $5 after 10 names | $20 first name, $10 additional | $15 with original note + $5 certification | No e-recording charge listed | High |
| St. Tammany | 1-5 pages $110; 6-25 $210; 26-50 $310; 51+ $310 + $5/page | $5 | $5 after 10 names | Not listed | $60 single cancellation | $5 LCRAA + $5 parish council fee included in above rates | High for recording; low for certificate |
| East Baton Rouge | 1-5 pages $135; 6-25 $235; 26-50 $335; 51+ $335 + $5/page | $5 | $5 after 10 names | Not separately listed | $85 per instrument, or $45 with original note | $5 LCRAA and $30 judicial building fund included/listed | High for recording/cancellation; low for certificate |

Statewide rule: do not apply a Louisiana statewide percentage-based transfer tax or mortgage tax. Orleans has a separate local documentary transaction tax for qualifying mortgage documents.

### Orleans Parish

Research confirms Orleans Parish/New Orleans has a special documentary transaction tax for mortgages.

| Mortgage amount | Documentary transaction tax |
| --- | ---: |
| Under $3,000 | $75 |
| $3,000.01-$6,000 | $125 |
| $6,000.01-$9,000 | $175 |
| Over $9,000 | $325 |

Normal residential refinance scenarios should assume the loan amount is over $9,000 unless the scenario says otherwise.

Implementation recommendation:

```text
fee_code: orleans_documentary_transaction_tax
state_code: LA
county_or_parish: Orleans
calculation_method: fixed_amount
fixed_low_amount: 325
fixed_expected_amount: 325
fixed_high_amount: 325
confidence_level: high
requires_local_verification: false
notes: "Applies to Orleans Parish mortgage transactions over $9,000."
```

Orleans recording schedule from research:

```text
fee_code: recording_fee
state_code: LA
county_or_parish: Orleans
calculation_method: fixed_amount
fixed_low_amount: 100
fixed_expected_amount: 200
fixed_high_amount: 300
extreme_high_threshold_amount: 600
confidence_level: high
notes: "1-5 pages $100, 6-25 pages $200, 26-50 pages $300, $5/page over 50."
```

Orleans cancellation/release:

```text
fee_code: mortgage_cancellation_or_release
state_code: LA
county_or_parish: Orleans
calculation_method: fixed_amount
fixed_low_amount: 10
fixed_expected_amount: 50
fixed_high_amount: 50
confidence_level: moderate
notes: "$50 per instrument; research notes possible $10 handling when original note is surrendered."
```

### Jefferson Parish

Research indicates Jefferson Parish uses slightly higher base brackets:

| Document size | Base recording fee |
| --- | ---: |
| 1-5 pages | $105 |
| 6-25 pages | $205 |
| 26-50 pages | $305 |
| Over 50 pages | $305 + $5 per page after 50 |

Implementation recommendation:

```text
fee_code: recording_fee
state_code: LA
county_or_parish: Jefferson
calculation_method: fixed_amount
fixed_low_amount: 105
fixed_expected_amount: 205
fixed_high_amount: 305
extreme_high_threshold_amount: 605
confidence_level: moderate
requires_local_verification: true
source_url: "https://www.deeds.com/recorder/louisiana/jefferson/"
notes: "Jefferson Parish recorder summary. Verify against official clerk schedule when available."
```

Jefferson mortgage cancellation:

```text
fee_code: mortgage_cancellation_or_release
state_code: LA
county_or_parish: Jefferson
calculation_method: fixed_amount
fixed_low_amount: 55
fixed_expected_amount: 55
fixed_high_amount: 105
confidence_level: moderate
requires_local_verification: true
source_url: "https://www.deeds.com/recorder/louisiana/jefferson/"
notes: "Use modeled statewide/nearby-parish cancellation range until Jefferson-specific cancellation charge is confirmed."
```

## Louisiana Title Insurance

Louisiana title insurance premiums are regulated statewide. This means a generic percentage estimate is less precise than a tiered premium calculator.

### Lender Policy Rate Table

The source-bearing PDF supersedes the earlier raw markdown summary that appeared to describe a `$100 per $1,000` first tier. Use the fixed-dollar schedule below for the first implementation pass, then extend the table after the full LATISSO manual is parsed.

| Loan amount range | Base lender policy premium |
| --- | ---: |
| $0-$5,000 | $160 |
| $5,001-$10,000 | $220 |
| $10,001-$15,000 | $270 |
| $15,001-$20,000 | $320 |
| $20,001-$25,000 | $370 |
| $25,001-$30,000 | $420 |
| $30,001-$35,000 | $470 |
| $35,001-$40,000 | $520 |
| $40,001-$45,000 | $570 |
| $45,001-$50,000 | $620 |
| $50,001-$55,000 | $670 |
| $55,001-$60,000 | $720 |
| $60,001-$65,000 | $770 |
| $65,001-$70,000 | $820 |
| $70,001-$75,000 | $870 |
| $75,001-$80,000 | $920 |
| $80,001-$85,000 | $970 |
| $85,001-$90,000 | $1,020 |
| $90,001-$95,000 | $1,070 |
| $95,001-$100,000 | $1,120 |
| $100,001-$250,000 | $1,120 + $3.50 per $1,000 over $100,000 |

Implementation recommendation:

- Add a deterministic title-insurance calculator only after the full rate table is represented.
- For loans over $250,000, keep the current percentage estimate or a conservative fallback until the remaining tiers are extracted.
- Store the LATISSO manual URL as source metadata for the rule.
- Label output as a modeled estimate until confirmed against a lender quote or Loan Estimate.

### Expanded Coverage

Research indicates expanded-coverage loan policies at 110% coverage may price above standard filed rates, and the PDF source also cites specific endorsements from the filed manual. Do not infer expanded coverage from ordinary refinance inputs.

Implementation recommendation:

```text
fee_code: title_insurance_expanded_coverage_uplift
state_code: LA
calculation_method: manual_only
confidence_level: moderate
notes: "Potential 10% uplift for expanded coverage. Apply only when quote/document confirms expanded coverage."
```

### Reissue / Refinance Credit

The source-bearing PDF reports a refinance/reissue discount around 50% of the applicable premium subject to policy/insurer conditions. The older raw markdown reported a 60% premium basis. Treat this as an eligibility-based adjustment that must be confirmed from the title insurer or Loan Estimate before applying.

Implementation recommendation:

```text
fee_code: title_insurance_reissue_credit
state_code: LA
calculation_method: manual_only
confidence_level: moderate
notes: "Potential refinance/reissue discount. Source reports 50% credit in the PDF; older raw notes mention 60% basis. Do not auto-apply without user confirmation."
```

### Endorsements

Research notes common ALTA endorsements, including 9.x and 7.x forms. Endorsement fees are filed/rate-manual driven.

The PDF source report cites example filed endorsement fees such as survey endorsement `$35`, ALTA 3.1 `$75`, and environmental hazard `$85`. Keep endorsements manual-only until the filed endorsement table is represented directly.

Implementation recommendation:

```text
fee_code: title_endorsements
state_code: LA
calculation_method: manual_only
confidence_level: low
notes: "Add only from lender quote, Loan Estimate, or verified title rate manual schedule."
```

## Louisiana Closing And Settlement Services

Louisiana does not appear to regulate settlement/notary/title-service fees in the same way as title insurance premiums.

Research example ranges from a title company fee sheet:

| Service | Example amount |
| --- | ---: |
| Document preparation | $350-$1,000 |
| Title exam | $250 |
| Abstract search | $350 |
| Closing protection letter | $25 |

Implementation recommendation:

Keep these as service-fee assumptions with moderate/low confidence unless a lender quote or Loan Estimate confirms the charge.

```text
fee_code: settlement_or_closing_fee
state_code: LA
fixed_low_amount: 300
fixed_expected_amount: 600
fixed_high_amount: 1200
confidence_level: moderate
```

```text
fee_code: attorney_or_notary_or_document_fee
state_code: LA
fixed_low_amount: 250
fixed_expected_amount: 500
fixed_high_amount: 1000
confidence_level: moderate
```

```text
fee_code: title_exam_fee
state_code: LA
fixed_low_amount: 200
fixed_expected_amount: 250
fixed_high_amount: 500
confidence_level: low
```

```text
fee_code: abstract_search_fee
state_code: LA
fixed_low_amount: 250
fixed_expected_amount: 350
fixed_high_amount: 700
confidence_level: low
```

```text
fee_code: closing_protection_letter_fee
state_code: LA
fixed_low_amount: 25
fixed_expected_amount: 25
fixed_high_amount: 50
confidence_level: low
```

## Non-Mortgage Research Extract

The source report also includes auto, personal, and student loan rate/fee observations. These should remain future research until source URLs and terms are captured.

### Auto Loans

Research observations:

- New auto APR benchmarks around high single digits.
- Used auto APR benchmarks around high single digits to low double digits.
- Credit union averages can differ materially from bank averages.
- Terms commonly include 36, 48, 60, 72, and 84 months.
- Louisiana OMV title fee was reported as $68.50.
- Louisiana lien/mortgage recording on title was reported as $10-$15.
- License transfer and handling fees were reported as $3 and $8.
- Lender/dealer origination/admin fees are lender-specific.
- GAP/warranty products are optional and should not be assumed.

Implementation recommendation:

Do not seed deterministic auto refinance fee estimates yet. Create a separate auto-loan research/seeding pass after URLs, terms, and geography are verified.

### Personal Loans

Research observations:

- Origination fees may range from 1%-10%.
- APR ranges are broad and credit-tier sensitive.
- Many lenders advertise no prepayment penalty.

Implementation recommendation:

Do not seed deterministic personal loan fee estimates yet. Personal loan fees are lender/product-specific and should be quote-driven until researched by provider.

### Student Loans

Research observations:

- Federal student loan rates and origination fees are program/year-specific.
- Private student loan rates are credit-tier sensitive.
- Student loan prepayment penalties are generally prohibited.
- Private refinance lenders often advertise no origination/application fees.

Implementation recommendation:

Do not seed deterministic student refinance estimates until federal/private product type and program year are modeled.

## Implementation Tasks

1. Add source URLs for each cited rule before seeding new database rows.
2. Verify the Louisiana title insurance first-tier interpretation.
3. Add or update Louisiana parish jurisdiction rules for:
   - Orleans recording
   - Orleans documentary transaction tax
   - Orleans cancellation/release
   - Jefferson recording
   - Jefferson cancellation/release
4. Decide whether `mortgage_certificate_fee`, `indexed_name_fee`, and `electronic_recording_surcharge` should be standalone fee types or bundled into `recording_fee` for v1.
5. Add title-insurance calculator support only after the official rate table is verified.
6. Keep non-mortgage research in docs until source URLs and terms are normalized.

## User-Facing Warning Text

Suggested warning text for Louisiana estimates:

```text
Louisiana recording, certificate, and cancellation costs can vary by parish and document details. MoneyTree is using modeled estimates until the lender quote, title invoice, or official parish schedule is confirmed.
```

For Orleans Parish:

```text
Orleans Parish documentary transaction tax is included because the property is located in Orleans Parish.
```

For title insurance:

```text
Louisiana title insurance is regulated statewide, but this estimate should be verified against the title insurer's filed rate calculation and lender quote.
```
