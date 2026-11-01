# Migration Log — SSCMPS Database

Chronological record of every database correction applied to this project.
Each entry links to the corresponding file in `db/migrations/`.

---

## 2026-11-01 — Round 2 Corrections

Source: Treasurer correction letter (2026-10-31) + `ADDITIONAL LOANS2.xlsx`
Verified on: copy DB (restored from `backup-public.sql`) then main DB
All entries idempotent and re-run tested.

### Phase 1a — Member name corrections
**File:** `migrations/20261101000001_phase1a_name_corrections.sql`
**Applied to:** main DB only
**Changes:**
- 0019 Mamman Zacchaeus Ndaba → Zacchaeus Ndaba Mamman
- 0023 Daniel Olanrewaju Adewara → Olanrewaju Daniel Adewara
- 0071 Winnifred Wodu Tsado → Winifred Wodu Tsado
**Verified:** ✅

### Phase 1b — Savings corrections
**File:** `migrations/20261101000002_phase1b_savings_corrections.sql`
**Applied to:** copy DB (verified) → main DB (verified)
**Changes:**
- 0003 Enoch N Gana: ₦1,260,000 → ₦2,191,512 (+₦931,512 CONTRIBUTION)
- 0028 John Jiya Ahmed: ₦402,650 → ₦385,650 (−₦17,000 REVERSAL,
  parent entry `1300f60a-9c1c-45aa-89c4-6688237b4f1b`)
**Verified:** ✅ copy, ✅ main. Idempotent (re-run → no changes).

### Phase 2 — Eight additional loans
**File:** `migrations/20261101000003_phase2_additional_loans.sql`
**Applied to:** copy DB (verified) → main DB (verified)
**Loans inserted:**

| Reference | Member | Reg | Product | Principal | Term |
|---|---|---|---|---|---|
| LOAN/EM/010 | Enoch N Gana | 0003 | Emergency | ₦500,000 | 10 |
| LOAN/LT/028 | Elijah Santali | 0004 | Long-Term | ₦500,000 | 24 |
| LOAN/LT/029 | James B Kolo | 0007 | Long-Term | ₦2,500,000 | 24 |
| LOAN/LT/030 | Hassan Ndafatima | 0027 | Long-Term | ₦1,000,000 | 24 |
| LOAN/LT/031 | Peter Bake | 0032 | Long-Term | ₦1,250,000 | 24 |
| LOAN/LT/032 | Enoch Adama | 0045 | Long-Term | ₦2,000,000 | 24 |
| LOAN/ST/003 | Grace Gajere | 0062 | Short-Term | ₦100,000 | 6 |
| LOAN/LT/033 | James Jibrin | 0069 | Long-Term | ₦200,000 | 15 |

**Result:** 8 loans, 151 schedule rows, 11 ledger entries, 8 audit records.

**Verification:**
- V1 (arithmetic): ✅ all 8 correct
- V2 (schedule sum = repayable): ✅ all 8 exact
- V3 (paid sum = repaid): ✅ all 8 exact
- V4 (Peter has 2 loans): ✅ LT/017 + LT/031
- V5 (counts): ✅ loans = 46, schedule = 909
- V6 (idempotency): ✅ re-run → no duplicates

**Notes:**
- Hassan (LT/030) and James Jibrin (LT/033) use Bye-Law §43 two-tier
  interest. The blended amount is stored in `normal_interest_applied`
  with `surplus_interest_applied = 0`; the split is documented in each
  loan's `application_notes` field.
- Peter Bake (LT/031) is a **second loan** — he already holds
  LOAN/LT/017. Combined outstanding: ₦2,107,200 vs savings ₦1,441,355,
  a pre-existing §44(a) over-limit condition recorded per Treasurer.
- Partial-payment cases confirmed by Treasurer:
  - EM/010: 7th instalment ₦30,000 of ₦55,000
  - LT/031: 17th instalment ₦53,700 of ₦54,700
  - LT/033: 1st instalment ₦13,000 of ₦15,625

---

## How to add a new entry

After applying a new migration, append a section above with:
- Date and short title
- Source (letter, spreadsheet, committee decision)
- File path and applied-to scope (copy/main/both)
- Changes summary (bullet list or table)
- Verification results
- Any caveats or partial-payment cases