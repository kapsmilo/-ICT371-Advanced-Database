-- ============================================================
-- ICT371: ADVANCED DATABASES
-- QUESTION 4: CLINIC APPOINTMENT SCHEDULING
-- DATABASE: POSTGRESQL
-- ============================================================

CREATE SCHEMA IF NOT EXISTS q4_clinic;

SET search_path TO q4_clinic, public;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- CREATE PATIENTS TABLE

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL
);


-- CREATE DOCTORS TABLE

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL
);


-- CREATE APPOINTMENTS TABLE

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,

    patient_id INT NOT NULL
        REFERENCES patients(patient_id),

    doctor_id INT NOT NULL
        REFERENCES doctors(doctor_id),

    appointment_day DATE NOT NULL,

    slot_time TIME NOT NULL,

    status VARCHAR(20) NOT NULL DEFAULT 'BOOKED',

    CONSTRAINT chk_appointment_slot
        CHECK (
            slot_time IN (
                TIME '09:00',
                TIME '10:00',
                TIME '11:00',
                TIME '12:00'
            )
        ),

    CONSTRAINT chk_appointment_status
        CHECK (
            status IN (
                'BOOKED',
                'ATTENDED',
                'CANCELLED'
            )
        )
);


-- CREATE CLINIC SUMMARY TABLE

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL,
    attended_count INT NOT NULL,
    cancelled_count INT NOT NULL
);


-- INSERT THREE PATIENTS

INSERT INTO patients (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');


-- INSERT THREE DOCTORS

INSERT INTO doctors (full_name)
VALUES
('Dr. James Mwila'),
('Dr. Sarah Phiri'),
('Dr. David Chanda');


-- ============================================================
-- (d) CREATE TRIGGER TO PREVENT APPOINTMENT CLASHES
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_existing_appointment INT;
BEGIN

    -- Lock the doctor's record to prevent simultaneous
    -- bookings from creating a clash.

    PERFORM 1
    FROM doctors
    WHERE doctor_id = NEW.doctor_id
    FOR UPDATE;

    -- Check whether another non-cancelled appointment
    -- already occupies the same doctor's time slot.

    SELECT appointment_id
    INTO v_existing_appointment
    FROM appointments
    WHERE doctor_id = NEW.doctor_id
      AND appointment_day = NEW.appointment_day
      AND slot_time = NEW.slot_time
      AND status <> 'CANCELLED'
      AND appointment_id <> COALESCE(NEW.appointment_id, -1)
    LIMIT 1;

    IF FOUND AND NEW.status <> 'CANCELLED' THEN
        RAISE EXCEPTION
            'Appointment clash: Doctor % already has an appointment on % at %',
            NEW.doctor_id,
            NEW.appointment_day,
            NEW.slot_time;
    END IF;

    RETURN NEW;

END;
$$;


-- CREATE BEFORE INSERT OR UPDATE TRIGGER

CREATE TRIGGER trg_check_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();


-- INSERT SIX APPOINTMENTS WITHOUT CLASHES

INSERT INTO appointments (
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
)
VALUES
(1, 1, CURRENT_DATE, TIME '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE, TIME '10:00', 'BOOKED'),
(3, 2, CURRENT_DATE, TIME '09:00', 'BOOKED'),
(1, 2, CURRENT_DATE, TIME '11:00', 'BOOKED'),
(2, 3, CURRENT_DATE, TIME '10:00', 'BOOKED'),
(3, 3, CURRENT_DATE, TIME '12:00', 'BOOKED');


-- ============================================================
-- (b) CREATE FUNCTION TO CALCULATE DAILY DOCTOR LOAD
-- ============================================================

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INT,
    p_day DATE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INT;
BEGIN

    -- Validate date

    IF p_day IS NULL THEN
        RAISE EXCEPTION
            'Appointment date cannot be NULL';
    END IF;

    -- Check whether doctor exists

    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Doctor ID % does not exist',
            p_doctor_id;
    END IF;

    -- Count non-cancelled appointments

    SELECT COUNT(*)
    INTO v_total
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_total;

END;
$$;


-- ============================================================
-- (c) CREATE PROCEDURE TO BOOK APPOINTMENTS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id INT,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate patient

    PERFORM 1
    FROM patients
    WHERE patient_id = p_patient_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Patient ID % does not exist',
            p_patient_id;
    END IF;


    -- Validate doctor

    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Doctor ID % does not exist',
            p_doctor_id;
    END IF;


    -- Validate appointment date

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION
            'Appointment date cannot be in the past or NULL';
    END IF;


    -- Validate appointment slot

    IF p_slot IS NULL OR p_slot NOT IN (
        TIME '09:00',
        TIME '10:00',
        TIME '11:00',
        TIME '12:00'
    ) THEN
        RAISE EXCEPTION
            'Invalid appointment slot. Allowed slots: 09:00, 10:00, 11:00 and 12:00';
    END IF;


    -- Insert appointment.
    -- The trigger checks for appointment clashes.

    INSERT INTO appointments (
        patient_id,
        doctor_id,
        appointment_day,
        slot_time,
        status
    )
    VALUES (
        p_patient_id,
        p_doctor_id,
        p_day,
        p_slot,
        'BOOKED'
    );

    RAISE NOTICE
        'Appointment booked successfully';

END;
$$;


-- ============================================================
-- (e) CREATE VIEW FOR TODAY'S BOOKED APPOINTMENTS
-- ============================================================

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    a.appointment_id,
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time

FROM appointments a

JOIN patients p
    ON a.patient_id = p.patient_id

JOIN doctors d
    ON a.doctor_id = d.doctor_id

WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';


-- ============================================================
-- (f) CREATE INDEX AND DISPLAY EXECUTION PLAN
-- ============================================================

CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);


-- QUERY APPOINTMENTS FOR A PARTICULAR DOCTOR AND DATE

EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
AND doctor_id = 1;


-- ============================================================
-- (g) CREATE DAILY CLINIC SUMMARY PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_day IS NULL THEN
        RAISE EXCEPTION
            'Summary date cannot be NULL';
    END IF;


    INSERT INTO clinic_summary (
        summary_date,
        booked_count,
        attended_count,
        cancelled_count
    )

    SELECT
        p_day,

        COUNT(*) FILTER (
            WHERE status = 'BOOKED'
        ),

        COUNT(*) FILTER (
            WHERE status = 'ATTENDED'
        ),

        COUNT(*) FILTER (
            WHERE status = 'CANCELLED'
        )

    FROM appointments
    WHERE appointment_day = p_day

    ON CONFLICT (summary_date)

    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;


    RAISE NOTICE
        'Clinic summary refreshed for %',
        p_day;

END;
$$;


-- GENERATE TODAY'S CLINIC SUMMARY

CALL pr_refresh_clinic_summary(CURRENT_DATE);


-- ============================================================
-- SCHEDULE DAILY CLINIC SUMMARY AT 01:00
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily-clinic-summary',
    '0 1 * * *',
    'CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. DISPLAY PATIENTS

SELECT * FROM patients;


-- 2. DISPLAY DOCTORS

SELECT * FROM doctors;


-- 3. DISPLAY ALL APPOINTMENTS

SELECT * FROM appointments;


-- 4. TEST DAILY LOAD FUNCTION

SELECT
    doctor_id,
    full_name,
    fn_daily_load(doctor_id, CURRENT_DATE) AS daily_load
FROM doctors;


-- 5. DISPLAY TODAY'S BOOKED APPOINTMENTS

SELECT * FROM v_today_appointments;


-- 6. DISPLAY CLINIC SUMMARY

SELECT * FROM clinic_summary;


-- 7. COUNT TOTAL APPOINTMENTS

SELECT COUNT(*) AS total_appointments
FROM appointments;


-- 8. COUNT BOOKED APPOINTMENTS

SELECT COUNT(*) AS booked_appointments
FROM appointments
WHERE status = 'BOOKED';


-- 9. COUNT CANCELLED APPOINTMENTS

SELECT COUNT(*) AS cancelled_appointments
FROM appointments
WHERE status = 'CANCELLED';


-- 10. COUNT ATTENDED APPOINTMENTS

SELECT COUNT(*) AS attended_appointments
FROM appointments
WHERE status = 'ATTENDED';


-- 11. DISPLAY SCHEDULED JOBS

SELECT * FROM cron.job;


-- ============================================================
-- END OF QUESTION 4
-- ============================================================