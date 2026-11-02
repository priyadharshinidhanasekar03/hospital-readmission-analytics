-- =====================================================================
-- tests/run_tests.sql
-- Data-quality and unit tests. Any failure raises an exception, so
--   psql -v ON_ERROR_STOP=1 -f tests/run_tests.sql
-- exits non-zero (works in CI).
-- =====================================================================
SET search_path TO hosp;

-- Helper ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.assert(p_ok BOOLEAN, p_name TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED: %', p_name;
    END IF;
    RAISE NOTICE 'PASS: %', p_name;
END;
$$;

-- 1. Load reconciliation: staged = loaded + rejected
SELECT pg_temp.assert(
    (SELECT COUNT(*) FROM stg_encounter) =
    (SELECT COUNT(*) FROM encounter) + (SELECT COUNT(*) FROM stg_rejected),
    'every staged row is either loaded or rejected');

SELECT pg_temp.assert((SELECT COUNT(*) FROM encounter) = 101763,
    'encounter row count = 101,763');

-- 2. Uniqueness / integrity
SELECT pg_temp.assert(
    (SELECT COUNT(*) FROM patient) = (SELECT COUNT(DISTINCT patient_nbr) FROM encounter),
    'one patient row per distinct patient');

SELECT pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM encounter_diagnosis d
    LEFT JOIN encounter e USING (encounter_id) WHERE e.encounter_id IS NULL),
    'no orphan diagnoses');

-- 3. Cleaning rules
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM patient WHERE race = '?'),
    'no "?" markers left in race');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM encounter WHERE medical_specialty = '?'),
    'no "?" markers left in medical_specialty');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM encounter_medication WHERE dose_status = 'No'),
    'only prescribed medications are stored');

-- 4. Generated KPI column matches source label
SELECT pg_temp.assert(
    (SELECT COUNT(*) FROM encounter WHERE readmitted_30d) =
    (SELECT COUNT(*) FROM stg_encounter WHERE readmitted = '<30'
                                          AND gender IN ('Male','Female')),
    'readmitted_30d flag matches source "<30" count');

-- 5. Eligibility rule: deaths / hospice excluded from KPI population
SELECT pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM vw_eligible_encounter WHERE discharge_disposition_id IN (11,13,14,19,20,21)),
    'expired and hospice discharges excluded from KPI population');

-- 6. fn_icd9_category unit tests
SELECT pg_temp.assert(fn_icd9_category('250.83') = 'Diabetes',    'icd9 250.83 -> Diabetes');
SELECT pg_temp.assert(fn_icd9_category('428')    = 'Circulatory', 'icd9 428 -> Circulatory');
SELECT pg_temp.assert(fn_icd9_category('786')    = 'Respiratory', 'icd9 786 -> Respiratory');
SELECT pg_temp.assert(fn_icd9_category('V57')    = 'Other',       'icd9 V57 -> Other');
SELECT pg_temp.assert(fn_icd9_category('?')      = 'Missing',     'icd9 ? -> Missing');

-- 7. Risk score always within 0-100
SELECT pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM (SELECT fn_readmission_risk_score(encounter_id) s
                   FROM encounter TABLESAMPLE SYSTEM (5)) x
    WHERE s NOT BETWEEN 0 AND 100),
    'risk score bounded 0-100');

-- 8. Risk score rejects unknown encounter
DO $$
BEGIN
    PERFORM hosp.fn_readmission_risk_score(-1);
    RAISE EXCEPTION 'TEST FAILED: unknown encounter should raise';
EXCEPTION WHEN no_data_found THEN
    RAISE NOTICE 'PASS: risk score raises on unknown encounter';
END $$;

-- 9. Dynamic report rejects non-whitelisted input (SQL-injection guard)
DO $$
BEGIN
    PERFORM * FROM hosp.fn_readmission_rate_by('race; DROP TABLE hosp.patient');
    RAISE EXCEPTION 'TEST FAILED: injection string accepted';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'TEST FAILED%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS: dynamic report rejects unknown dimension';
END $$;

-- 10. Audit trigger records corrections (rolled back afterwards)
BEGIN;
UPDATE encounter SET readmitted = 'NO'
WHERE  encounter_id = (SELECT MIN(encounter_id) FROM encounter WHERE readmitted = '<30');
SELECT pg_temp.assert(
    EXISTS (SELECT 1 FROM encounter_audit WHERE column_name = 'readmitted'
                                            AND old_value = '<30' AND new_value = 'NO'),
    'audit trigger captures readmitted correction');
ROLLBACK;

-- 11. Nightly procedure succeeds and logs its run
CALL sp_refresh_high_risk_report();
SELECT pg_temp.assert(
    (SELECT status FROM etl_run_log ORDER BY run_id DESC LIMIT 1) = 'SUCCESS',
    'sp_refresh_high_risk_report logs SUCCESS');
SELECT pg_temp.assert((SELECT COUNT(*) FROM rpt_high_risk_patient) > 0,
    'high-risk report is populated');
SELECT pg_temp.assert(NOT EXISTS (SELECT 1 FROM rpt_high_risk_patient WHERE max_risk_score < 40),
    'report only contains patients at or above threshold');

\echo 'ALL TESTS PASSED'
