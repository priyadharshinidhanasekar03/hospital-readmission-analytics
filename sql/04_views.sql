-- =====================================================================
-- 04_views.sql
-- Reporting layer: reusable views for BI tools (Tableau / Power BI)
-- =====================================================================
SET search_path TO hosp;

-- Analysis population. Encounters ending in death or hospice cannot be
-- readmitted, so they are excluded from readmission KPIs (same rule CMS uses).
CREATE OR REPLACE VIEW vw_eligible_encounter AS
SELECT e.*
FROM   encounter e
WHERE  e.discharge_disposition_id NOT IN (11, 13, 14, 19, 20, 21);

-- One wide row per encounter, ready for dashboards
CREATE OR REPLACE VIEW vw_encounter_detail AS
SELECT e.encounter_id,
       e.patient_nbr,
       p.race,
       p.gender,
       e.age_band,
       at.description  AS admission_type,
       src.description AS admission_source,
       dd.description  AS discharge_disposition,
       e.medical_specialty,
       e.payer_code,
       e.time_in_hospital,
       e.num_lab_procedures,
       e.num_medications,
       e.number_inpatient AS prior_inpatient_visits,
       e.number_emergency AS prior_emergency_visits,
       dx.icd9_code     AS primary_icd9,
       dx.icd9_category AS primary_condition,
       e.a1c_result,
       e.med_changed,
       e.readmitted,
       e.readmitted_30d
FROM   vw_eligible_encounter e
JOIN   patient p                   ON p.patient_nbr = e.patient_nbr
JOIN   dim_admission_type at       ON at.id  = e.admission_type_id
JOIN   dim_admission_source src    ON src.id = e.admission_source_id
JOIN   dim_discharge_disposition dd ON dd.id = e.discharge_disposition_id
LEFT   JOIN encounter_diagnosis dx ON dx.encounter_id = e.encounter_id AND dx.diag_seq = 1;

-- Headline KPI tile
CREATE OR REPLACE VIEW vw_readmission_kpi AS
SELECT COUNT(*)                                           AS encounters,
       COUNT(DISTINCT patient_nbr)                        AS patients,
       SUM(readmitted_30d::INT)                           AS readmits_30d,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)         AS readmit_30d_pct,
       ROUND(AVG(time_in_hospital), 2)                    AS avg_length_of_stay
FROM   vw_eligible_encounter;

-- Materialized: expensive specialty roll-up refreshed by the nightly job
DROP MATERIALIZED VIEW IF EXISTS mv_specialty_summary;
CREATE MATERIALIZED VIEW mv_specialty_summary AS
SELECT COALESCE(medical_specialty, 'Unknown')           AS medical_specialty,
       COUNT(*)                                          AS encounters,
       ROUND(100.0 * AVG(readmitted_30d::INT), 2)        AS readmit_30d_pct,
       ROUND(AVG(time_in_hospital), 2)                   AS avg_los,
       ROUND(AVG(num_medications), 1)                    AS avg_medications
FROM   vw_eligible_encounter
GROUP  BY COALESCE(medical_specialty, 'Unknown')
HAVING COUNT(*) >= 100;

CREATE UNIQUE INDEX ux_mv_specialty ON mv_specialty_summary (medical_specialty);
