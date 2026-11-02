-- =====================================================================
-- 05_plpgsql.sql
-- Procedural layer: functions, a stored procedure, a trigger.
-- (PL/pgSQL - an Oracle PL/SQL port lives in /oracle)
-- =====================================================================
SET search_path TO hosp;

-- ---------------------------------------------------------------------
-- fn_readmission_risk_score
-- Rule-based 0-100 score inspired by the LACE index
-- (Length of stay, Acuity, Comorbidities, Emergency visits).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_readmission_risk_score(p_encounter_id BIGINT)
RETURNS INT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    r       encounter%ROWTYPE;
    v_score INT := 0;
    v_insulin_adjusted BOOLEAN;
BEGIN
    SELECT * INTO r FROM encounter WHERE encounter_id = p_encounter_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Encounter % not found', p_encounter_id
              USING ERRCODE = 'no_data_found';
    END IF;

    -- Prior utilisation is the strongest predictor
    v_score := v_score + LEAST(r.number_inpatient, 4) * 8;   -- max 32
    v_score := v_score + LEAST(r.number_emergency, 4) * 4;   -- max 16

    -- Length of stay
    v_score := v_score + CASE WHEN r.time_in_hospital >= 7 THEN 10
                              WHEN r.time_in_hospital >= 4 THEN 5
                              ELSE 0 END;

    -- Comorbidity burden
    IF r.number_diagnoses >= 9 THEN v_score := v_score + 8; END IF;

    -- Acute admission through emergency
    IF r.admission_type_id = 1 THEN v_score := v_score + 5; END IF;

    -- Discharged to another facility (SNF, rehab, LTC...)
    IF r.discharge_disposition_id IN (2, 3, 4, 5, 22, 23, 24) THEN
        v_score := v_score + 10;
    END IF;

    -- Elderly
    IF r.age_band IN ('[70-80)', '[80-90)', '[90-100)') THEN
        v_score := v_score + 8;
    END IF;

    -- Unstable glycaemic control: insulin dose changed during the stay
    SELECT EXISTS (
        SELECT 1 FROM encounter_medication em
        JOIN dim_medication m USING (med_id)
        WHERE em.encounter_id = p_encounter_id
          AND m.med_name = 'insulin'
          AND em.dose_status IN ('Up', 'Down'))
    INTO v_insulin_adjusted;
    IF v_insulin_adjusted THEN v_score := v_score + 6; END IF;

    -- Poor control (A1C > 8) with no medication change = missed intervention
    IF r.a1c_result = '>8' AND NOT r.med_changed THEN
        v_score := v_score + 5;
    END IF;

    RETURN LEAST(v_score, 100);
END;
$$;

-- ---------------------------------------------------------------------
-- fn_readmission_rate_by
-- Dynamic, injection-safe breakdown of the 30-day rate by any whitelisted
-- dimension. Used by the reporting API: SELECT * FROM fn_readmission_rate_by('race');
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_readmission_rate_by(p_dimension TEXT)
RETURNS TABLE (dimension_value TEXT, encounters BIGINT, readmit_30d_pct NUMERIC)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_dimension NOT IN ('race', 'gender', 'age_band', 'admission_type',
                           'admission_source', 'discharge_disposition',
                           'medical_specialty', 'payer_code',
                           'primary_condition', 'a1c_result') THEN
        RAISE EXCEPTION 'Unsupported dimension: %', p_dimension
              USING HINT = 'See the whitelist in fn_readmission_rate_by';
    END IF;

    RETURN QUERY EXECUTE format(
        'SELECT COALESCE(%1$I::TEXT, ''Unknown''),
                COUNT(*),
                ROUND(100.0 * AVG(readmitted_30d::INT), 2)
         FROM   hosp.vw_encounter_detail
         GROUP  BY 1
         ORDER  BY 3 DESC', p_dimension);
END;
$$;

-- ---------------------------------------------------------------------
-- sp_refresh_high_risk_report
-- Nightly job: rebuilds the care-management work list and logs the run.
-- Transaction-safe: on any error the report is untouched and the failure
-- is recorded in etl_run_log.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_refresh_high_risk_report(p_min_score INT DEFAULT 40)
LANGUAGE plpgsql AS $$
DECLARE
    v_run_id BIGINT;
    v_rows   BIGINT;
BEGIN
    INSERT INTO etl_run_log (job_name) VALUES ('refresh_high_risk_report')
    RETURNING run_id INTO v_run_id;
    COMMIT;  -- persist the RUNNING row even if the work below fails

    BEGIN
        DELETE FROM rpt_high_risk_patient;

        INSERT INTO rpt_high_risk_patient (patient_nbr, last_encounter_id, encounters,
               readmits_30d, max_risk_score, primary_condition, risk_tier)
        WITH scored AS (
            SELECT e.patient_nbr,
                   e.encounter_id,
                   e.readmitted_30d,
                   fn_readmission_risk_score(e.encounter_id) AS score,
                   dx.icd9_category
            FROM   vw_eligible_encounter e
            LEFT   JOIN encounter_diagnosis dx
                   ON dx.encounter_id = e.encounter_id AND dx.diag_seq = 1
        ), ranked AS (
            SELECT s.*,
                   ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY encounter_id DESC) AS rn,
                   COUNT(*)            OVER (PARTITION BY patient_nbr) AS n_enc,
                   SUM(readmitted_30d::INT) OVER (PARTITION BY patient_nbr) AS n_readmit,
                   MAX(score)          OVER (PARTITION BY patient_nbr) AS max_score
            FROM   scored s
        )
        SELECT patient_nbr, encounter_id, n_enc, n_readmit, max_score, icd9_category,
               CASE WHEN max_score >= 60 THEN 'HIGH'
                    WHEN max_score >= 40 THEN 'MEDIUM'
                    ELSE 'LOW' END
        FROM   ranked
        WHERE  rn = 1 AND max_score >= p_min_score;

        GET DIAGNOSTICS v_rows = ROW_COUNT;

        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_specialty_summary;

        UPDATE etl_run_log
        SET    finished_at = now(), rows_affected = v_rows, status = 'SUCCESS'
        WHERE  run_id = v_run_id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE etl_run_log
        SET    finished_at = now(), status = 'FAILED', error_message = SQLERRM
        WHERE  run_id = v_run_id;
        RAISE NOTICE 'refresh_high_risk_report failed: %', SQLERRM;
    END;
END;
$$;

-- ---------------------------------------------------------------------
-- Audit trigger: any correction to a readmission outcome or discharge
-- disposition is recorded (who / when / old / new) - a typical
-- requirement for clinical data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_encounter_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.readmitted IS DISTINCT FROM OLD.readmitted THEN
        INSERT INTO encounter_audit (encounter_id, column_name, old_value, new_value)
        VALUES (OLD.encounter_id, 'readmitted', OLD.readmitted, NEW.readmitted);
    END IF;
    IF NEW.discharge_disposition_id IS DISTINCT FROM OLD.discharge_disposition_id THEN
        INSERT INTO encounter_audit (encounter_id, column_name, old_value, new_value)
        VALUES (OLD.encounter_id, 'discharge_disposition_id',
                OLD.discharge_disposition_id::TEXT, NEW.discharge_disposition_id::TEXT);
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_encounter_audit ON encounter;
CREATE TRIGGER trg_encounter_audit
AFTER UPDATE OF readmitted, discharge_disposition_id ON encounter
FOR EACH ROW EXECUTE FUNCTION trg_fn_encounter_audit();
