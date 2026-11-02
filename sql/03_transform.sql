-- =====================================================================
-- 03_transform.sql
-- Staging -> normalized model. Run after loading stg_encounter.
-- Cleaning rules:
--   * '?' and 'None' are the dataset's missing-value markers -> NULL
--   * 'Unknown/Invalid' gender -> excluded (3 rows, not analysable)
--   * Patient demographics taken from the patient's FIRST encounter
-- =====================================================================
SET search_path TO hosp;

BEGIN;

-- Rows we refuse to load are kept for review rather than silently dropped
DROP TABLE IF EXISTS stg_rejected;
CREATE TABLE stg_rejected AS
SELECT s.*, 'invalid gender'::TEXT AS reject_reason
FROM   stg_encounter s
WHERE  s.gender NOT IN ('Male', 'Female');

-- 1. Patients ----------------------------------------------------------
INSERT INTO patient (patient_nbr, race, gender, age_band)
SELECT DISTINCT ON (patient_nbr::BIGINT)
       patient_nbr::BIGINT,
       NULLIF(race, '?'),
       gender,
       age
FROM   stg_encounter
WHERE  gender IN ('Male', 'Female')
ORDER  BY patient_nbr::BIGINT, encounter_id::BIGINT;

-- 2. Encounters --------------------------------------------------------
INSERT INTO encounter (
    encounter_id, patient_nbr, admission_type_id, discharge_disposition_id,
    admission_source_id, age_band, time_in_hospital, payer_code, medical_specialty,
    num_lab_procedures, num_procedures, num_medications, number_outpatient,
    number_emergency, number_inpatient, number_diagnoses, max_glu_serum,
    a1c_result, med_changed, on_diabetes_med, readmitted)
SELECT encounter_id::BIGINT,
       patient_nbr::BIGINT,
       admission_type_id::SMALLINT,
       discharge_disposition_id::SMALLINT,
       admission_source_id::SMALLINT,
       age,
       time_in_hospital::SMALLINT,
       NULLIF(payer_code, '?'),
       NULLIF(medical_specialty, '?'),
       num_lab_procedures::SMALLINT,
       num_procedures::SMALLINT,
       num_medications::SMALLINT,
       number_outpatient::SMALLINT,
       number_emergency::SMALLINT,
       number_inpatient::SMALLINT,
       number_diagnoses::SMALLINT,
       NULLIF(max_glu_serum, 'None'),
       NULLIF(a1cresult, 'None'),
       (change = 'Ch'),
       (diabetesmed = 'Yes'),
       readmitted
FROM   stg_encounter
WHERE  gender IN ('Male', 'Female');

-- 3. Diagnoses: unpivot diag_1..diag_3 --------------------------------
INSERT INTO encounter_diagnosis (encounter_id, diag_seq, icd9_code, icd9_category)
SELECT s.encounter_id::BIGINT, d.seq, d.code, fn_icd9_category(d.code)
FROM   stg_encounter s
CROSS  JOIN LATERAL (VALUES (1, s.diag_1), (2, s.diag_2), (3, s.diag_3)) AS d(seq, code)
WHERE  s.gender IN ('Male', 'Female')
  AND  d.code <> '?';

-- 4. Medications: unpivot 23 drug columns ------------------------------
INSERT INTO dim_medication (med_name)
VALUES ('metformin'), ('repaglinide'), ('nateglinide'), ('chlorpropamide'),
       ('glimepiride'), ('acetohexamide'), ('glipizide'), ('glyburide'),
       ('tolbutamide'), ('pioglitazone'), ('rosiglitazone'), ('acarbose'),
       ('miglitol'), ('troglitazone'), ('tolazamide'), ('examide'),
       ('citoglipton'), ('insulin'), ('glyburide-metformin'),
       ('glipizide-metformin'), ('glimepiride-pioglitazone'),
       ('metformin-rosiglitazone'), ('metformin-pioglitazone');

INSERT INTO encounter_medication (encounter_id, med_id, dose_status)
SELECT s.encounter_id::BIGINT, m.med_id, x.status
FROM   stg_encounter s
CROSS  JOIN LATERAL (VALUES
        ('metformin', s.metformin), ('repaglinide', s.repaglinide),
        ('nateglinide', s.nateglinide), ('chlorpropamide', s.chlorpropamide),
        ('glimepiride', s.glimepiride), ('acetohexamide', s.acetohexamide),
        ('glipizide', s.glipizide), ('glyburide', s.glyburide),
        ('tolbutamide', s.tolbutamide), ('pioglitazone', s.pioglitazone),
        ('rosiglitazone', s.rosiglitazone), ('acarbose', s.acarbose),
        ('miglitol', s.miglitol), ('troglitazone', s.troglitazone),
        ('tolazamide', s.tolazamide), ('examide', s.examide),
        ('citoglipton', s.citoglipton), ('insulin', s.insulin),
        ('glyburide-metformin', s.glyburide_metformin),
        ('glipizide-metformin', s.glipizide_metformin),
        ('glimepiride-pioglitazone', s.glimepiride_pioglitazone),
        ('metformin-rosiglitazone', s.metformin_rosiglitazone),
        ('metformin-pioglitazone', s.metformin_pioglitazone)
       ) AS x(med_name, status)
JOIN   dim_medication m ON m.med_name = x.med_name
WHERE  s.gender IN ('Male', 'Female')
  AND  x.status <> 'No';

COMMIT;

ANALYZE;
