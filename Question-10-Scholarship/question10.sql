-- ============================================================
-- ICT371 - QUESTION 10
-- SCHOLARSHIP APPLICATION MANAGEMENT SYSTEM
-- PostgreSQL / PLpgSQL
-- ============================================================

-- Create schema
CREATE SCHEMA IF NOT EXISTS q10_scholarship;

SET search_path TO q10_scholarship;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- Students table
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);


-- Applications table
CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL,
    age_at_application INT NOT NULL,
    monthly_income NUMERIC(12,2) NOT NULL,
    average_mark NUMERIC(5,2) NOT NULL,
    submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',

    CONSTRAINT fk_student
        FOREIGN KEY (student_id)
        REFERENCES students(student_id),

    CONSTRAINT chk_age
        CHECK (age_at_application > 0),

    CONSTRAINT chk_monthly_income
        CHECK (monthly_income >= 0),

    CONSTRAINT chk_average_mark
        CHECK (average_mark BETWEEN 0 AND 100),

    CONSTRAINT chk_application_status
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);


-- Decision audit table
CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INT NOT NULL,
    old_status VARCHAR(20),
    new_status VARCHAR(20) NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_application
        FOREIGN KEY (application_id)
        REFERENCES applications(application_id)
);


-- Insert sample students
INSERT INTO students (
    student_number,
    full_name
)
VALUES
('2024001', 'John Banda'),
('2024002', 'Mary Phiri'),
('2024003', 'Peter Zulu');


-- Insert six scholarship applications
-- These include eligible, ineligible and boundary cases.

INSERT INTO applications (
    student_id,
    age_at_application,
    monthly_income,
    average_mark,
    submitted_on
)
VALUES

-- Application 1: Eligible
(1, 20, 2000, 85, CURRENT_DATE - 6),

-- Application 2: Eligible at all boundaries
(1, 18, 3000, 70, CURRENT_DATE - 5),

-- Application 3: Ineligible because age is above 25
(2, 26, 2000, 85, CURRENT_DATE - 4),

-- Application 4: Ineligible because income is above K3000
(2, 22, 3500, 80, CURRENT_DATE - 3),

-- Application 5: Ineligible because average mark is below 70
(3, 21, 1500, 65, CURRENT_DATE - 2),

-- Application 6: Eligible
(3, 25, 3000, 90, CURRENT_DATE - 1);


-- ============================================================
-- (b) FUNCTION TO CHECK SCHOLARSHIP ELIGIBILITY
-- ============================================================

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate inputs
    IF p_age IS NULL THEN
        RAISE EXCEPTION 'Age cannot be NULL';
    END IF;

    IF p_income IS NULL THEN
        RAISE EXCEPTION 'Monthly income cannot be NULL';
    END IF;

    IF p_mark IS NULL THEN
        RAISE EXCEPTION 'Average mark cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be greater than zero';
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative';
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100';
    END IF;

    -- Check eligibility conditions
    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );

END;
$$;


-- ============================================================
-- (c) PROCEDURE TO ASSESS A SCHOLARSHIP APPLICATION
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INT;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(20);
    v_new_status VARCHAR(20);
BEGIN

    -- Lock the application to prevent simultaneous assessment
    SELECT
        age_at_application,
        monthly_income,
        average_mark,
        status
    INTO
        v_age,
        v_income,
        v_mark,
        v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    -- Check application exists
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Application ID % does not exist',
            p_application_id;
    END IF;

    -- Only pending applications can be assessed
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION
            'Application % has already been assessed',
            p_application_id;
    END IF;

    -- Determine decision
    IF fn_scholarship_eligible(
        v_age,
        v_income,
        v_mark
    ) THEN

        v_new_status := 'APPROVED';

    ELSE

        v_new_status := 'REJECTED';

    END IF;

    -- Update application status
    UPDATE applications
    SET status = v_new_status
    WHERE application_id = p_application_id;

    RAISE NOTICE
        'Application % assessed: %',
        p_application_id,
        v_new_status;

END;
$$;


-- ============================================================
-- (d) AFTER UPDATE TRIGGER TO RECORD DECISIONS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_audit_decision()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Record only actual status changes
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO decision_audit (
            application_id,
            old_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.application_id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- Create trigger
CREATE TRIGGER trg_audit_decision
AFTER UPDATE
ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_audit_decision();


-- ============================================================
-- ASSESS THE SIX SAMPLE APPLICATIONS
-- ============================================================

CALL pr_assess_application(1);
CALL pr_assess_application(2);
CALL pr_assess_application(3);
CALL pr_assess_application(4);
CALL pr_assess_application(5);
CALL pr_assess_application(6);


-- ============================================================
-- (e) CREATE VIEW FOR APPROVED APPLICANTS
-- ============================================================

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status

FROM applications a

JOIN students s
    ON a.student_id = s.student_id

WHERE a.status = 'APPROVED';


-- Display approved applicants
SELECT *
FROM v_approved_applicants;


-- ============================================================
-- (f) CREATE INDEX FOR STATUS AND SUBMISSION DATE SEARCHES
-- ============================================================

CREATE INDEX idx_applications_status_date
ON applications(status, submitted_on);


-- Query applications by status and submission date
EXPLAIN
SELECT *
FROM applications
WHERE status = 'APPROVED'
AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ============================================================
-- (g) PROCEDURE TO ASSESS ALL PENDING APPLICATIONS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_application RECORD;
    v_count INT := 0;
BEGIN

    -- Process only pending applications
    FOR v_application IN

        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
        FOR UPDATE

    LOOP

        CALL pr_assess_application(
            v_application.application_id
        );

        v_count := v_count + 1;

    END LOOP;

    RAISE NOTICE
        'Assessment completed. Applications processed: %',
        v_count;

END;
$$;


-- Run pending assessment procedure
CALL pr_assess_pending();


-- ============================================================
-- SCHEDULE EVERY MONDAY AT 08:00
-- Requires pg_cron to be installed and configured.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- Remove existing job with the same name to avoid duplicates
DO $$
DECLARE
    v_job_id BIGINT;
BEGIN

    SELECT jobid
    INTO v_job_id
    FROM cron.job
    WHERE jobname = 'q10_assess_pending';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

END;
$$;


-- Schedule every Monday at 08:00
SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',
    'CALL q10_scholarship.pr_assess_pending();'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. Display all students
SELECT * FROM students;

-- 2. Display all applications and decisions
SELECT * FROM applications;

-- 3. Display approved applicants
SELECT * FROM v_approved_applicants;

-- 4. Display decision audit records
SELECT * FROM decision_audit;

-- 5. Test eligibility function
SELECT fn_scholarship_eligible(20, 2000, 85)
AS eligible_student;

SELECT fn_scholarship_eligible(26, 2000, 85)
AS ineligible_student;

-- 6. Test application index
EXPLAIN
SELECT *
FROM applications
WHERE status = 'APPROVED'
AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- 7. Display scheduled job (requires pg_cron)
SELECT *
FROM cron.job
WHERE jobname = 'q10_assess_pending';


-- ============================================================
-- END OF QUESTION 10
-- ============================================================