-- =====================================================================
-- 06_analysis.sql
-- Business questions from the hospital quality team.
-- Population: vw_eligible_encounter (excludes death / hospice discharges)
-- KPI: 30-day readmission rate (readmitted = '<30')
-- =====================================================================
SET search_path TO hosp;

-- ---------------------------------------------------------------------
-- Q1. What is our overall 30-day readmission rate?
-- ---------------------------------------------------------------------
SELECT * FROM vw_readmission_kpi;

-- ---------------------------------------------------------------------
-- Q2. How does the rate change with age? (with share of total volume)
-- ---------------------------------------------------------------------
SELECT age_band,
       COUNT(*)                                              AS encounters,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)     AS pct_of_volume,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)             AS readmit_30d_pct
FROM   vw_eligible_encounter
GROUP  BY age_band
ORDER  BY age_band;

-- ---------------------------------------------------------------------
-- Q3. Which primary diagnosis groups drive the most readmissions?
--     Rank by absolute readmissions, not just rate.
-- ---------------------------------------------------------------------
SELECT dx.icd9_category                                   AS primary_condition,
       COUNT(*)                                            AS encounters,
       SUM(e.readmitted_30d::INT)                          AS readmits_30d,
       ROUND(100.0 * AVG(e.readmitted_30d::INT), 2)        AS readmit_30d_pct,
       RANK() OVER (ORDER BY SUM(e.readmitted_30d::INT) DESC) AS rank_by_volume
FROM   vw_eligible_encounter e
JOIN   encounter_diagnosis dx ON dx.encounter_id = e.encounter_id AND dx.diag_seq = 1
GROUP  BY dx.icd9_category
ORDER  BY readmits_30d DESC;

-- ---------------------------------------------------------------------
-- Q4. Where do patients go after discharge, and how does it affect risk?
-- ---------------------------------------------------------------------
SELECT dd.description                                   AS discharge_disposition,
       COUNT(*)                                          AS encounters,
       ROUND(100.0 * AVG(e.readmitted_30d::INT), 2)      AS readmit_30d_pct
FROM   vw_eligible_encounter e
JOIN   dim_discharge_disposition dd ON dd.id = e.discharge_disposition_id
GROUP  BY dd.description
HAVING COUNT(*) >= 500
ORDER  BY readmit_30d_pct DESC;

-- ---------------------------------------------------------------------
-- Q5. Is HbA1c being tested, and does testing + acting on it matter?
--     (The original research question of the dataset's paper.)
-- ---------------------------------------------------------------------
SELECT CASE
         WHEN a1c_result IS NULL                 THEN '1. Not tested'
         WHEN a1c_result IN ('Norm', '>7')       THEN '2. Tested - normal / borderline'
         WHEN a1c_result = '>8' AND med_changed  THEN '3. Tested high - meds changed'
         ELSE                                         '4. Tested high - NO med change'
       END                                               AS a1c_group,
       COUNT(*)                                          AS encounters,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_encounters,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)        AS readmit_30d_pct
FROM   vw_eligible_encounter
GROUP  BY 1
ORDER  BY 1;

-- ---------------------------------------------------------------------
-- Q6. Prior utilisation: do frequent inpatients come back more?
-- ---------------------------------------------------------------------
SELECT CASE WHEN number_inpatient >= 5 THEN '5+' ELSE number_inpatient::TEXT END
                                                         AS prior_inpatient_visits,
       COUNT(*)                                          AS encounters,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)        AS readmit_30d_pct
FROM   vw_eligible_encounter
GROUP  BY 1
ORDER  BY MIN(number_inpatient);

-- ---------------------------------------------------------------------
-- Q7. Length of stay vs readmission (does early discharge hurt?)
-- ---------------------------------------------------------------------
SELECT CASE WHEN time_in_hospital <= 2 THEN '1-2 days'
            WHEN time_in_hospital <= 4 THEN '3-4 days'
            WHEN time_in_hospital <= 7 THEN '5-7 days'
            ELSE '8-14 days' END                         AS length_of_stay,
       COUNT(*)                                          AS encounters,
       ROUND(AVG(num_lab_procedures), 1)                 AS avg_lab_tests,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)        AS readmit_30d_pct
FROM   vw_eligible_encounter
GROUP  BY 1
ORDER  BY 1;

-- ---------------------------------------------------------------------
-- Q8. Top 10 specialties by readmission rate (min. 100 encounters)
-- ---------------------------------------------------------------------
SELECT * FROM mv_specialty_summary
ORDER  BY readmit_30d_pct DESC
LIMIT  10;

-- ---------------------------------------------------------------------
-- Q9. Frequent flyers: patients with 3+ readmissions in the data.
--     Uses window functions to show each patient's visit sequence.
-- ---------------------------------------------------------------------
WITH patient_visits AS (
    SELECT patient_nbr,
           encounter_id,
           readmitted,
           ROW_NUMBER() OVER w                       AS visit_no,
           COUNT(*)     OVER (PARTITION BY patient_nbr) AS total_visits,
           SUM(readmitted_30d::INT) OVER (PARTITION BY patient_nbr) AS readmits_30d
    FROM   encounter
    WINDOW w AS (PARTITION BY patient_nbr ORDER BY encounter_id)
)
SELECT patient_nbr,
       total_visits,
       readmits_30d,
       LEFT(STRING_AGG(readmitted, ' -> ' ORDER BY visit_no), 60) || ' ...' AS first_outcomes
FROM   patient_visits
WHERE  readmits_30d >= 3
GROUP  BY patient_nbr, total_visits, readmits_30d
ORDER  BY readmits_30d DESC, total_visits DESC
LIMIT  15;

-- ---------------------------------------------------------------------
-- Q10. What share of patients account for most of the readmissions?
--      (Pareto analysis - who should care management focus on?)
-- ---------------------------------------------------------------------
WITH per_patient AS (
    SELECT patient_nbr, SUM(readmitted_30d::INT) AS readmits
    FROM   vw_eligible_encounter
    GROUP  BY patient_nbr
    HAVING SUM(readmitted_30d::INT) > 0
), cumulative AS (
    SELECT readmits,
           SUM(readmits) OVER (ORDER BY readmits DESC, patient_nbr) AS running_readmits,
           SUM(readmits) OVER ()                                   AS total_readmits,
           ROW_NUMBER()  OVER (ORDER BY readmits DESC, patient_nbr) AS patient_rank,
           (SELECT COUNT(DISTINCT patient_nbr) FROM vw_eligible_encounter) AS all_patients
    FROM   per_patient
)
SELECT ROUND(100.0 * MIN(patient_rank) FILTER (WHERE running_readmits >= 0.5 * total_readmits)
             / MAX(all_patients), 2) AS pct_patients_causing_50pct_of_readmits,
       ROUND(100.0 * COUNT(*) / MAX(all_patients), 2) AS pct_patients_ever_readmitted_30d
FROM   cumulative;

-- ---------------------------------------------------------------------
-- Q11. Which diabetes medications are prescribed most, and how often is
--      the dose adjusted during the stay?
-- ---------------------------------------------------------------------
SELECT m.med_name,
       COUNT(*)                                                     AS encounters_on_drug,
       ROUND(100.0 * COUNT(*) FILTER (WHERE em.dose_status <> 'Steady') / COUNT(*), 1)
                                                                    AS pct_dose_adjusted,
       ROUND(100.0 * AVG(e.readmitted_30d::INT), 2)                 AS readmit_30d_pct
FROM   encounter_medication em
JOIN   dim_medication m USING (med_id)
JOIN   vw_eligible_encounter e USING (encounter_id)
GROUP  BY m.med_name
HAVING COUNT(*) >= 1000
ORDER  BY encounters_on_drug DESC;

-- ---------------------------------------------------------------------
-- Q12. Does the risk score actually separate risk? (validation by decile)
-- ---------------------------------------------------------------------
WITH scored AS (
    SELECT readmitted_30d, fn_readmission_risk_score(encounter_id) AS score
    FROM   vw_eligible_encounter
)
SELECT CASE WHEN score >= 60 THEN '3. HIGH (60+)'
            WHEN score >= 40 THEN '2. MEDIUM (40-59)'
            ELSE '1. LOW (<40)' END                      AS risk_tier,
       COUNT(*)                                          AS encounters,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)        AS actual_readmit_30d_pct
FROM   scored
GROUP  BY 1
ORDER  BY 1;

-- ---------------------------------------------------------------------
-- Q13. Gaps-and-islands: longest streak of consecutive readmissions per patient
-- ---------------------------------------------------------------------
WITH seq AS (
    SELECT patient_nbr, encounter_id, readmitted_30d,
           ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY encounter_id)
         - ROW_NUMBER() OVER (PARTITION BY patient_nbr, readmitted_30d ORDER BY encounter_id) AS grp
    FROM   encounter
), streaks AS (
    SELECT patient_nbr, COUNT(*) AS streak_len
    FROM   seq
    WHERE  readmitted_30d
    GROUP  BY patient_nbr, grp
)
SELECT streak_len AS consecutive_30d_readmits, COUNT(*) AS patients
FROM   (SELECT patient_nbr, MAX(streak_len) AS streak_len FROM streaks GROUP BY patient_nbr) s
GROUP  BY streak_len
ORDER  BY streak_len;
