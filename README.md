# Hospital Readmission Analytics — SQL & PL/pgSQL

End-to-end SQL project that turns 101,766 real hospital encounters from 130 US hospitals into a normalized database, a reporting layer, and a nightly risk-scoring job that finds the patients most likely to return within 30 days.

`SQL` · `PL/pgSQL` · `Oracle PL/SQL` · `21 automated tests`

![Dashboard](docs/dashboard.png)

<img width="1620" height="842" alt="Screenshot 2026-11-04 110949" src="https://github.com/user-attachments/assets/68d81e65-28b5-4c18-89e2-7779cb1a1eaa" />


Live dashboard: https://care-return-radar.lovable.app

**Key results**
- 11.39% overall 30-day readmission rate (11,314 readmissions)
- Only 4.5% of patients cause half of all readmissions
- Prior inpatient visits raise readmission risk from 8.6% (none) to 37.1% (5+)
- HIGH-risk tier readmits at 28.6% vs 9.9% for LOW (about 3x)

## 1. Problem statement

Under the US Hospital Readmissions Reduction Program (HRRP), Medicare cuts payments to hospitals whose patients come back too often within 30 days of discharge. Diabetic patients are a high-risk group: they are readmitted more often and cost more per stay.

A hospital quality team asked for:

- A clean, queryable database built from raw encounter exports.
- Answers to key questions: which patients, conditions, and discharge decisions drive 30-day readmissions?
- A daily work list of high-risk patients for the care-management team to call after discharge.
- Data-quality checks and an audit trail for any changes to clinical outcomes.

## 2. Dataset

Diabetes 130-US Hospitals for Years 1999–2008 — UCI Machine Learning Repository (link), CC BY 4.0. Strack et al., "Impact of HbA1c Measurement on Hospital Readmission Rates", BioMed Research International, 2014.

| | |
|---|---|
| Encounters | 101,766 (101,763 after cleaning) |
| Unique patients | 71,515 |
| Columns | 50 — demographics, admission/discharge, ICD-9 diagnoses, lab tests, 23 diabetes drugs, readmission outcome |

## 3. Architecture

```
diabetic_data.csv ──\copy──> stg_encounter (all TEXT, raw)
                                   │  03_transform.sql (clean, cast, unpivot)
                                   ▼
   dim_admission_type   dim_admission_source   dim_discharge_disposition   dim_medication
            \                    |                        /                     |
             └──────────> encounter (101,763) <── patient (71,515)              |
                           │            │                                       |
              encounter_diagnosis   encounter_medication <──────────────────────┘
               (303,487 rows)         (120,050 rows)
                           │
                           ▼
   vw_eligible_encounter → vw_encounter_detail → vw_readmission_kpi, mv_specialty_summary
                           │
   fn_readmission_risk_score() → sp_refresh_high_risk_report() → rpt_high_risk_patient
                                         └→ etl_run_log          trg_encounter_audit → encounter_audit
```

See `docs/er_diagram.md` for the full entity-relationship diagram.

## 4. What's in the repo

| File | What it shows |
|---|---|
| `sql/01_schema.sql` | 3NF schema, PK/FK, CHECK constraints, generated column, partial index, ICD-9 grouping function |
| `sql/02_seed_lookups.sql` | Reference data from the dataset's code list |
| `sql/03_transform.sql` | Staging → model in one transaction; missing-value handling; unpivoting 3 diagnosis and 23 drug columns with CROSS JOIN LATERAL; rejected-row table |
| `sql/04_views.sql` | Reporting views and a materialized view for BI tools |
| `sql/05_plpgsql.sql` | Risk-score function, dynamic SQL report with injection whitelist, stored procedure with error handling + run log, audit trigger |
| `sql/06_analysis.sql` | 13 business questions — CTEs, window functions (RANK, ROW_NUMBER, running SUM), FILTER, Pareto analysis, gaps-and-islands |
| `tests/run_tests.sql` | 21 tests: load reconciliation, integrity, cleaning rules, function unit tests, trigger + procedure tests |
| `oracle/pkg_readmission.sql` | The same logic as an Oracle PL/SQL package (autonomous-transaction logging, RAISE_APPLICATION_ERROR, row trigger) |

## 5. Key findings

Population: 99,340 encounters (deaths and hospice discharges excluded, since they can't be readmitted).

| Finding | Number |
|---|---|
| Overall 30-day readmission rate | 11.39% (11,314 readmissions) |
| Patients with 0 prior inpatient visits vs 5+ | 8.6% → 37.1% — prior utilisation is the strongest signal |
| Discharged to rehab facility vs home | 27.7% vs 9.3% |
| Length of stay 1–2 days vs 8–14 days | 9.3% → 13.9% |
| HbA1c not tested during the stay | 83% of encounters |
| Patients who cause half of all readmissions | only 4.5% of patients |
| Highest-rate specialties | Hematology/Oncology 21.4%, Oncology 20.1%, Nephrology 16.1% |
| Circulatory diagnoses | most readmissions by volume (3,469) |

**Risk score validation** — the rule-based score separates risk well (checked on the same data used to design it; see Limitations):

| Tier | Encounters | Actual 30-day readmission |
|---|---|---|
| LOW (<40) | 85,954 | 9.9% |
| MEDIUM (40–59) | 11,657 | 19.8% |
| HIGH (60+) | 1,729 | 28.6% — about 3x the low tier |

<img width="1575" height="840" alt="Screenshot 2026-11-04 111016" src="https://github.com/user-attachments/assets/ffafccee-7e94-4958-9f96-18e34591afdf" />

Python analysis (notebooks/readmission_analysis.ipynb)

Uses pandas and scikit-learn on the same dataset to test the findings on patients the model has not seen (80/20 split by patient, so no patient appears in both sets).

<img width="902" height="200" alt="image" src="https://github.com/user-attachments/assets/95e2c051-416c-44a9-93a0-13080558263b" />


- Actual readmission rises from 4.4% in the lowest-risk decile to 26.4% in the highest (test average 11.2%).
- Top factors: prior inpatient visits and discharge destination, far ahead of everything else.
- Four patient segments; the "Frequent returners" group (9.5% of encounters) has the highest rate at 18.8%.


### Recommendations

These are suggestions based on descriptive patterns, not proven causes.

- Findings suggest focusing follow-up calls on the HIGH and MEDIUM tiers (about 13% of discharges, about 2x the base rate). The nightly `rpt_high_risk_patient` table is that list.
- Discharges to rehab and other care facilities have the highest rates, so hand-offs there are worth reviewing.
- 83% of diabetic inpatients were never tested for HbA1c, so testing practice is worth investigating.
- 4.5% of patients cause half of all readmissions, which makes a frequent-visitor program worth considering.

Full output: `docs/analysis_output.txt`

## 6. How to run

Requires PostgreSQL 13+ and `psql`.

```bash
git clone https://github.com/priyadharshinidhanasekar03/hospital-readmission-analytics.git
cd hospital-readmission-analytics
# Download diabetic_data.csv from the UCI repository (link in Section 2)
# and place it in the data/ folder
createdb readmit
DB=readmit ./run_all.sh      # build + load + test + analysis, about 15 seconds
```

Then run individual reports:

```sql
SET search_path TO hosp;
SELECT * FROM vw_readmission_kpi;
SELECT * FROM fn_readmission_rate_by('age_band');
SELECT fn_readmission_risk_score(149190);
CALL sp_refresh_high_risk_report(40);
SELECT * FROM rpt_high_risk_patient WHERE risk_tier = 'HIGH' ORDER BY max_risk_score DESC LIMIT 20;
```

## 7. Design decisions

- **Staging as TEXT:** a bad value can never break the load. Casting happens in one transaction, and invalid rows go to `stg_rejected` instead of being silently dropped.
- **Missing values:** the dataset uses `?` and `None` for missing values. These become NULL so aggregates stay correct.
- **Sparse drug columns → fact table:** 23 mostly-"No" columns become 120k meaningful rows, so new drugs need no schema change.
- **KPI as a generated column:** `readmitted_30d` can't drift from the source label.
- **Eligibility rule in one view:** every report uses the same population, following the CMS convention of excluding deaths and hospice discharges.
- **Run log + audit trail:** operational support and root-cause analysis need to know what ran, when, and what changed.

## 8. Limitations

- The data covers 1999–2008 and has no admission dates, so encounter order uses `encounter_id`.
- The risk score is rule-based (LACE-inspired) and transparent, not a trained model.
- The risk tiers were validated on the same data used to design the score, with no holdout set.
- Findings are descriptive and not adjusted for other factors, so they show association, not cause.
- Patient identifiers in the data are already anonymized.

## 9. License

Code is released under the MIT License (see `LICENSE`). The dataset is CC BY 4.0, from the UCI Machine Learning Repository.
