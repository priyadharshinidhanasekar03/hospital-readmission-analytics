-- =====================================================================
-- 01_schema.sql
-- Hospital Readmission Analytics - normalized schema
-- Source: UCI "Diabetes 130-US hospitals for years 1999-2008"
-- =====================================================================
DROP SCHEMA IF EXISTS hosp CASCADE;
CREATE SCHEMA hosp;
SET search_path TO hosp;

-- ---------------------------------------------------------------------
-- Staging: raw CSV lands here as text, exactly as delivered.
-- Every column is TEXT so a bad value can never abort the load.
-- ---------------------------------------------------------------------
CREATE TABLE stg_encounter (
    encounter_id TEXT, patient_nbr TEXT, race TEXT, gender TEXT, age TEXT,
    weight TEXT, admission_type_id TEXT, discharge_disposition_id TEXT,
    admission_source_id TEXT, time_in_hospital TEXT, payer_code TEXT,
    medical_specialty TEXT, num_lab_procedures TEXT, num_procedures TEXT,
    num_medications TEXT, number_outpatient TEXT, number_emergency TEXT,
    number_inpatient TEXT, diag_1 TEXT, diag_2 TEXT, diag_3 TEXT,
    number_diagnoses TEXT, max_glu_serum TEXT, a1cresult TEXT,
    metformin TEXT, repaglinide TEXT, nateglinide TEXT, chlorpropamide TEXT,
    glimepiride TEXT, acetohexamide TEXT, glipizide TEXT, glyburide TEXT,
    tolbutamide TEXT, pioglitazone TEXT, rosiglitazone TEXT, acarbose TEXT,
    miglitol TEXT, troglitazone TEXT, tolazamide TEXT, examide TEXT,
    citoglipton TEXT, insulin TEXT, glyburide_metformin TEXT,
    glipizide_metformin TEXT, glimepiride_pioglitazone TEXT,
    metformin_rosiglitazone TEXT, metformin_pioglitazone TEXT,
    change TEXT, diabetesmed TEXT, readmitted TEXT
);

-- ---------------------------------------------------------------------
-- Lookup / dimension tables
-- ---------------------------------------------------------------------
CREATE TABLE dim_admission_type (
    id          SMALLINT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE dim_discharge_disposition (
    id          SMALLINT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE dim_admission_source (
    id          SMALLINT PRIMARY KEY,
    description TEXT NOT NULL
);

CREATE TABLE dim_medication (
    med_id   SMALLSERIAL PRIMARY KEY,
    med_name TEXT NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------
CREATE TABLE patient (
    patient_nbr BIGINT PRIMARY KEY,
    race        TEXT,                       -- NULL when unknown ('?')
    gender      TEXT CHECK (gender IN ('Male', 'Female')),
    age_band    TEXT NOT NULL               -- e.g. '[70-80)' at first encounter
);

CREATE TABLE encounter (
    encounter_id             BIGINT PRIMARY KEY,
    patient_nbr              BIGINT   NOT NULL REFERENCES patient(patient_nbr),
    admission_type_id        SMALLINT NOT NULL REFERENCES dim_admission_type(id),
    discharge_disposition_id SMALLINT NOT NULL REFERENCES dim_discharge_disposition(id),
    admission_source_id      SMALLINT NOT NULL REFERENCES dim_admission_source(id),
    age_band                 TEXT     NOT NULL,
    time_in_hospital         SMALLINT NOT NULL CHECK (time_in_hospital BETWEEN 1 AND 14),
    payer_code               TEXT,
    medical_specialty        TEXT,
    num_lab_procedures       SMALLINT NOT NULL CHECK (num_lab_procedures >= 0),
    num_procedures           SMALLINT NOT NULL CHECK (num_procedures >= 0),
    num_medications          SMALLINT NOT NULL CHECK (num_medications >= 0),
    number_outpatient        SMALLINT NOT NULL CHECK (number_outpatient >= 0),
    number_emergency         SMALLINT NOT NULL CHECK (number_emergency >= 0),
    number_inpatient         SMALLINT NOT NULL CHECK (number_inpatient >= 0),
    number_diagnoses         SMALLINT NOT NULL CHECK (number_diagnoses >= 0),
    max_glu_serum            TEXT CHECK (max_glu_serum IN ('Norm', '>200', '>300')),
    a1c_result               TEXT CHECK (a1c_result IN ('Norm', '>7', '>8')),
    med_changed              BOOLEAN  NOT NULL,
    on_diabetes_med          BOOLEAN  NOT NULL,
    readmitted               TEXT     NOT NULL CHECK (readmitted IN ('NO', '<30', '>30')),
    -- The KPI hospitals are penalized on (CMS HRRP): readmission within 30 days
    readmitted_30d           BOOLEAN GENERATED ALWAYS AS (readmitted = '<30') STORED
);

CREATE TABLE encounter_diagnosis (
    encounter_id  BIGINT   NOT NULL REFERENCES encounter(encounter_id) ON DELETE CASCADE,
    diag_seq      SMALLINT NOT NULL CHECK (diag_seq BETWEEN 1 AND 3), -- 1 = primary
    icd9_code     TEXT     NOT NULL,
    icd9_category TEXT     NOT NULL,
    PRIMARY KEY (encounter_id, diag_seq)
);

-- Only medications actually prescribed are stored (status <> 'No'),
-- turning 23 sparse columns into a compact fact table.
CREATE TABLE encounter_medication (
    encounter_id BIGINT   NOT NULL REFERENCES encounter(encounter_id) ON DELETE CASCADE,
    med_id       SMALLINT NOT NULL REFERENCES dim_medication(med_id),
    dose_status  TEXT     NOT NULL CHECK (dose_status IN ('Steady', 'Up', 'Down')),
    PRIMARY KEY (encounter_id, med_id)
);

-- ---------------------------------------------------------------------
-- Operational tables (used by the PL/pgSQL layer)
-- ---------------------------------------------------------------------
CREATE TABLE etl_run_log (
    run_id        BIGSERIAL PRIMARY KEY,
    job_name      TEXT        NOT NULL,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    rows_affected BIGINT,
    status        TEXT        NOT NULL DEFAULT 'RUNNING'
                  CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    error_message TEXT
);

CREATE TABLE encounter_audit (
    audit_id       BIGSERIAL PRIMARY KEY,
    encounter_id   BIGINT      NOT NULL,
    column_name    TEXT        NOT NULL,
    old_value      TEXT,
    new_value      TEXT,
    changed_by     TEXT        NOT NULL DEFAULT current_user,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE rpt_high_risk_patient (
    patient_nbr        BIGINT PRIMARY KEY REFERENCES patient(patient_nbr),
    last_encounter_id  BIGINT NOT NULL,
    encounters         INT    NOT NULL,
    readmits_30d       INT    NOT NULL,
    max_risk_score     INT    NOT NULL,
    primary_condition  TEXT,
    risk_tier          TEXT   NOT NULL CHECK (risk_tier IN ('HIGH', 'MEDIUM', 'LOW')),
    generated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Indexes for the access paths used by the reports
-- ---------------------------------------------------------------------
CREATE INDEX ix_encounter_patient     ON encounter (patient_nbr);
CREATE INDEX ix_encounter_discharge   ON encounter (discharge_disposition_id);
CREATE INDEX ix_encounter_readmit30   ON encounter (encounter_id) WHERE readmitted_30d;
CREATE INDEX ix_diag_category         ON encounter_diagnosis (icd9_category, diag_seq);
CREATE INDEX ix_encmed_med            ON encounter_medication (med_id);

-- ---------------------------------------------------------------------
-- ICD-9 grouping (Strack et al., 2014 - the paper that published this dataset)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_icd9_category(p_code TEXT)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_num NUMERIC;
BEGIN
    IF p_code IS NULL OR p_code = '?' THEN
        RETURN 'Missing';
    END IF;
    -- V (supplementary) and E (external cause) codes
    IF p_code ~ '^[VvEe]' THEN
        RETURN 'Other';
    END IF;

    v_num := p_code::NUMERIC;

    IF floor(v_num) = 250                         THEN RETURN 'Diabetes';
    ELSIF v_num BETWEEN 390 AND 459.99 OR floor(v_num) = 785 THEN RETURN 'Circulatory';
    ELSIF v_num BETWEEN 460 AND 519.99 OR floor(v_num) = 786 THEN RETURN 'Respiratory';
    ELSIF v_num BETWEEN 520 AND 579.99 OR floor(v_num) = 787 THEN RETURN 'Digestive';
    ELSIF v_num BETWEEN 800 AND 999.99            THEN RETURN 'Injury';
    ELSIF v_num BETWEEN 710 AND 739.99            THEN RETURN 'Musculoskeletal';
    ELSIF v_num BETWEEN 580 AND 629.99 OR floor(v_num) = 788 THEN RETURN 'Genitourinary';
    ELSIF v_num BETWEEN 140 AND 239.99            THEN RETURN 'Neoplasms';
    ELSE                                               RETURN 'Other';
    END IF;
EXCEPTION
    WHEN invalid_text_representation THEN
        RETURN 'Other';
END;
$$;
