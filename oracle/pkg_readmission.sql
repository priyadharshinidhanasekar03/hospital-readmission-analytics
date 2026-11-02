-- =====================================================================
-- oracle/pkg_readmission.sql
-- Oracle PL/SQL port of the procedural layer in sql/05_plpgsql.sql.
-- Assumes the same tables exist in the current Oracle schema
-- (ENCOUNTER, ENCOUNTER_MEDICATION, DIM_MEDICATION, ENCOUNTER_DIAGNOSIS,
--  RPT_HIGH_RISK_PATIENT, ETL_RUN_LOG) with Oracle data types.
-- Oracle 12c+ (uses identity columns / FETCH FIRST in the companions).
-- =====================================================================

CREATE OR REPLACE PACKAGE pkg_readmission AS
    c_high_threshold   CONSTANT PLS_INTEGER := 60;
    c_medium_threshold CONSTANT PLS_INTEGER := 40;

    e_encounter_not_found EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_encounter_not_found, -20001);

    FUNCTION icd9_category (p_code IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC;

    FUNCTION risk_score (p_encounter_id IN NUMBER) RETURN PLS_INTEGER;

    FUNCTION risk_tier (p_score IN PLS_INTEGER) RETURN VARCHAR2 DETERMINISTIC;

    PROCEDURE refresh_high_risk_report (p_min_score IN PLS_INTEGER DEFAULT 40);
END pkg_readmission;
/

CREATE OR REPLACE PACKAGE BODY pkg_readmission AS

    -- Autonomous logging so the log row survives a rollback of the main work
    PROCEDURE log_run (p_run_id IN OUT NUMBER, p_status IN VARCHAR2,
                       p_rows IN NUMBER DEFAULT NULL, p_err IN VARCHAR2 DEFAULT NULL) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        IF p_run_id IS NULL THEN
            INSERT INTO etl_run_log (job_name, started_at, status)
            VALUES ('refresh_high_risk_report', SYSTIMESTAMP, p_status)
            RETURNING run_id INTO p_run_id;
        ELSE
            UPDATE etl_run_log
            SET    finished_at = SYSTIMESTAMP, status = p_status,
                   rows_affected = p_rows, error_message = SUBSTR(p_err, 1, 4000)
            WHERE  run_id = p_run_id;
        END IF;
        COMMIT;
    END log_run;

    FUNCTION icd9_category (p_code IN VARCHAR2) RETURN VARCHAR2 DETERMINISTIC IS
        v_num NUMBER;
    BEGIN
        IF p_code IS NULL OR p_code = '?' THEN
            RETURN 'Missing';
        ELSIF REGEXP_LIKE(p_code, '^[VvEe]') THEN
            RETURN 'Other';
        END IF;

        v_num := TO_NUMBER(p_code);

        RETURN CASE
            WHEN FLOOR(v_num) = 250                                   THEN 'Diabetes'
            WHEN v_num BETWEEN 390 AND 459.99 OR FLOOR(v_num) = 785   THEN 'Circulatory'
            WHEN v_num BETWEEN 460 AND 519.99 OR FLOOR(v_num) = 786   THEN 'Respiratory'
            WHEN v_num BETWEEN 520 AND 579.99 OR FLOOR(v_num) = 787   THEN 'Digestive'
            WHEN v_num BETWEEN 800 AND 999.99                         THEN 'Injury'
            WHEN v_num BETWEEN 710 AND 739.99                         THEN 'Musculoskeletal'
            WHEN v_num BETWEEN 580 AND 629.99 OR FLOOR(v_num) = 788   THEN 'Genitourinary'
            WHEN v_num BETWEEN 140 AND 239.99                         THEN 'Neoplasms'
            ELSE 'Other'
        END;
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            RETURN 'Other';
    END icd9_category;

    FUNCTION risk_score (p_encounter_id IN NUMBER) RETURN PLS_INTEGER IS
        r            encounter%ROWTYPE;
        v_score      PLS_INTEGER := 0;
        v_insulin_ct PLS_INTEGER;
    BEGIN
        BEGIN
            SELECT * INTO r FROM encounter WHERE encounter_id = p_encounter_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20001, 'Encounter ' || p_encounter_id || ' not found');
        END;

        v_score := v_score + LEAST(r.number_inpatient, 4) * 8;
        v_score := v_score + LEAST(r.number_emergency, 4) * 4;
        v_score := v_score + CASE WHEN r.time_in_hospital >= 7 THEN 10
                                  WHEN r.time_in_hospital >= 4 THEN 5
                                  ELSE 0 END;
        IF r.number_diagnoses >= 9 THEN v_score := v_score + 8; END IF;
        IF r.admission_type_id = 1 THEN v_score := v_score + 5; END IF;
        IF r.discharge_disposition_id IN (2, 3, 4, 5, 22, 23, 24) THEN
            v_score := v_score + 10;
        END IF;
        IF r.age_band IN ('[70-80)', '[80-90)', '[90-100)') THEN
            v_score := v_score + 8;
        END IF;

        SELECT COUNT(*) INTO v_insulin_ct
        FROM   encounter_medication em
        JOIN   dim_medication m ON m.med_id = em.med_id
        WHERE  em.encounter_id = p_encounter_id
          AND  m.med_name = 'insulin'
          AND  em.dose_status IN ('Up', 'Down');
        IF v_insulin_ct > 0 THEN v_score := v_score + 6; END IF;

        -- med_changed stored as 'Y'/'N' in Oracle (no BOOLEAN column type before 23ai)
        IF r.a1c_result = '>8' AND r.med_changed = 'N' THEN
            v_score := v_score + 5;
        END IF;

        RETURN LEAST(v_score, 100);
    END risk_score;

    FUNCTION risk_tier (p_score IN PLS_INTEGER) RETURN VARCHAR2 DETERMINISTIC IS
    BEGIN
        RETURN CASE WHEN p_score >= c_high_threshold   THEN 'HIGH'
                    WHEN p_score >= c_medium_threshold THEN 'MEDIUM'
                    ELSE 'LOW' END;
    END risk_tier;

    PROCEDURE refresh_high_risk_report (p_min_score IN PLS_INTEGER DEFAULT 40) IS
        v_run_id NUMBER;
        v_rows   NUMBER;
    BEGIN
        log_run(v_run_id, 'RUNNING');

        DELETE FROM rpt_high_risk_patient;

        INSERT INTO rpt_high_risk_patient (patient_nbr, last_encounter_id, encounters,
               readmits_30d, max_risk_score, primary_condition, risk_tier, generated_at)
        SELECT patient_nbr, encounter_id, n_enc, n_readmit, max_score, icd9_category,
               pkg_readmission.risk_tier(max_score), SYSTIMESTAMP
        FROM (
            SELECT s.*,
                   ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY encounter_id DESC) rn,
                   COUNT(*)     OVER (PARTITION BY patient_nbr)                          n_enc,
                   SUM(CASE WHEN readmitted = '<30' THEN 1 ELSE 0 END)
                                OVER (PARTITION BY patient_nbr)                          n_readmit,
                   MAX(score)   OVER (PARTITION BY patient_nbr)                          max_score
            FROM (
                SELECT e.patient_nbr, e.encounter_id, e.readmitted,
                       pkg_readmission.risk_score(e.encounter_id) score,
                       dx.icd9_category
                FROM   encounter e
                LEFT   JOIN encounter_diagnosis dx
                       ON dx.encounter_id = e.encounter_id AND dx.diag_seq = 1
                WHERE  e.discharge_disposition_id NOT IN (11, 13, 14, 19, 20, 21)
            ) s
        )
        WHERE rn = 1 AND max_score >= p_min_score;

        v_rows := SQL%ROWCOUNT;
        COMMIT;

        log_run(v_run_id, 'SUCCESS', v_rows);
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            log_run(v_run_id, 'FAILED', NULL, SQLERRM);
            RAISE;
    END refresh_high_risk_report;

END pkg_readmission;
/

-- Audit trigger (Oracle syntax)
CREATE OR REPLACE TRIGGER trg_encounter_audit
AFTER UPDATE OF readmitted, discharge_disposition_id ON encounter
FOR EACH ROW
BEGIN
    IF :OLD.readmitted <> :NEW.readmitted THEN
        INSERT INTO encounter_audit (encounter_id, column_name, old_value, new_value, changed_by, changed_at)
        VALUES (:OLD.encounter_id, 'readmitted', :OLD.readmitted, :NEW.readmitted, USER, SYSTIMESTAMP);
    END IF;
    IF :OLD.discharge_disposition_id <> :NEW.discharge_disposition_id THEN
        INSERT INTO encounter_audit (encounter_id, column_name, old_value, new_value, changed_by, changed_at)
        VALUES (:OLD.encounter_id, 'discharge_disposition_id',
                TO_CHAR(:OLD.discharge_disposition_id), TO_CHAR(:NEW.discharge_disposition_id),
                USER, SYSTIMESTAMP);
    END IF;
END;
/

-- Usage:
--   EXEC pkg_readmission.refresh_high_risk_report(40);
--   SELECT pkg_readmission.risk_score(149190) FROM dual;
