-- ============================================================
-- ICT371: ADVANCED DATABASES
-- QUESTION 6: MONTHLY PAYROLL
-- DATABASE: POSTGRESQL
-- ============================================================

CREATE SCHEMA IF NOT EXISTS q6_payroll;

SET search_path TO q6_payroll, public;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- CREATE EMPLOYEES TABLE

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(150) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL
        CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL
        CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL
        CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);


-- CREATE PAYROLL TABLE

CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,

    employee_id INT NOT NULL
        REFERENCES employees(employee_id),

    pay_month DATE NOT NULL,

    gross_pay NUMERIC(12,2) NOT NULL
        CHECK (gross_pay >= 0),

    net_pay NUMERIC(12,2) NOT NULL
        CHECK (net_pay >= 0),

    CONSTRAINT uq_employee_pay_month
        UNIQUE (employee_id, pay_month),

    CONSTRAINT chk_pay_month
        CHECK (
            EXTRACT(DAY FROM pay_month) = 1
        )
);


-- CREATE SALARY AUDIT TABLE

CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,

    employee_id INT NOT NULL
        REFERENCES employees(employee_id),

    old_salary NUMERIC(12,2) NOT NULL,

    new_salary NUMERIC(12,2) NOT NULL,

    changed_at TIMESTAMP NOT NULL
        DEFAULT CURRENT_TIMESTAMP
);


-- INSERT SAMPLE EMPLOYEES

INSERT INTO employees (
    full_name,
    basic_salary,
    allowance,
    deduction,
    active
)
VALUES
('John Banda', 5000.00, 1000.00, 500.00, TRUE),
('Mary Phiri', 6000.00, 1500.00, 800.00, TRUE),
('Peter Zulu', 4500.00, 500.00, 300.00, FALSE),
('Grace Mwila', 7000.00, 1200.00, 700.00, TRUE);


-- ============================================================
-- (b) CREATE FUNCTION TO CALCULATE NET PAY
-- ============================================================

CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INT
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic_salary NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN

    -- Retrieve employee salary information

    SELECT
        basic_salary,
        allowance,
        deduction

    INTO
        v_basic_salary,
        v_allowance,
        v_deduction

    FROM employees
    WHERE employee_id = p_employee_id;


    -- Check employee existence

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Employee ID % does not exist',
            p_employee_id;
    END IF;


    -- Calculate net pay

    v_net_pay :=
        v_basic_salary + v_allowance - v_deduction;


    -- Reject negative net pay

    IF v_net_pay < 0 THEN
        RAISE EXCEPTION
            'Employee ID % has a negative net salary',
            p_employee_id;
    END IF;


    RETURN v_net_pay;

END;
$$;


-- ============================================================
-- (c) CREATE PROCEDURE TO PROCESS MONTHLY PAYROLL
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_employee RECORD;
    v_gross_pay NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN

    -- Validate payroll month

    IF p_month IS NULL THEN
        RAISE EXCEPTION
            'Payroll month cannot be NULL';
    END IF;

    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION
            'Payroll month must be the first day of the month';
    END IF;


    -- Process active employees only

    FOR v_employee IN
        SELECT
            employee_id,
            basic_salary,
            allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id

    LOOP

        -- Calculate gross pay

        v_gross_pay :=
            v_employee.basic_salary
            + v_employee.allowance;


        -- Calculate net pay using the function

        v_net_pay :=
            fn_net_pay(v_employee.employee_id);


        -- Insert payroll record only if it does not exist

        INSERT INTO payroll (
            employee_id,
            pay_month,
            gross_pay,
            net_pay
        )
        VALUES (
            v_employee.employee_id,
            p_month,
            v_gross_pay,
            v_net_pay
        )

        ON CONFLICT (employee_id, pay_month)
        DO NOTHING;

    END LOOP;


    RAISE NOTICE
        'Payroll processed successfully for %',
        p_month;

END;
$$;


-- ============================================================
-- (d) CREATE AFTER UPDATE SALARY AUDIT TRIGGER
-- ============================================================

CREATE OR REPLACE FUNCTION fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Audit only actual changes to basic_salary

    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN

        INSERT INTO salary_audit (
            employee_id,
            old_salary,
            new_salary,
            changed_at
        )
        VALUES (
            NEW.employee_id,
            OLD.basic_salary,
            NEW.basic_salary,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- CREATE AFTER UPDATE TRIGGER

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_salary_audit();


-- ============================================================
-- PROCESS PAYROLL FOR TWO MONTHS
-- ============================================================

-- PROCESS PREVIOUS MONTH

CALL pr_process_payroll(
    (date_trunc('month', CURRENT_DATE)
    - INTERVAL '1 month')::DATE
);


-- PROCESS TWO MONTHS AGO

CALL pr_process_payroll(
    (date_trunc('month', CURRENT_DATE)
    - INTERVAL '2 months')::DATE
);


-- DEACTIVATE ONE EMPLOYEE AFTER PAYROLL PROCESSING

-- This demonstrates that historical payroll records
-- remain available even after an employee becomes inactive.

UPDATE employees
SET active = FALSE
WHERE employee_id = 2;


-- UPDATE ONE EMPLOYEE'S BASIC SALARY
-- This creates a salary audit record.

UPDATE employees
SET basic_salary = basic_salary + 100.00
WHERE employee_id = 1;


-- ============================================================
-- (e) CREATE PAYROLL REPORT VIEW
-- ============================================================

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.employee_id,
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay

FROM payroll p

JOIN employees e
    ON p.employee_id = e.employee_id;


-- DISPLAY PAYROLL REPORT

SELECT * FROM v_payroll_report;


-- ============================================================
-- (f) CREATE INDEX FOR PAYROLL REPORT
-- ============================================================

CREATE INDEX idx_payroll_month_employee
ON payroll (pay_month, employee_id);


-- QUERY PAYROLL FOR A PARTICULAR MONTH

EXPLAIN
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay

FROM payroll p

JOIN employees e
    ON p.employee_id = e.employee_id

WHERE p.pay_month =
    (date_trunc('month', CURRENT_DATE)
    - INTERVAL '1 month')::DATE;


-- ============================================================
-- (g) SCHEDULE MONTHLY PAYROLL PROCESSING
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;


-- SCHEDULE PAYROLL FOR 02:00 ON THE FIRST DAY
-- OF EVERY MONTH.
-- It processes the previous month's payroll.

SELECT cron.schedule(
    'monthly-payroll-processing',
    '0 2 1 * *',
    'CALL q6_payroll.pr_process_payroll(
        (date_trunc(''month'', CURRENT_DATE)
        - INTERVAL ''1 month'')::DATE
    )'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. DISPLAY ALL EMPLOYEES

SELECT * FROM employees;


-- 2. DISPLAY ALL PAYROLL RECORDS

SELECT * FROM payroll;


-- 3. DISPLAY SALARY AUDIT RECORDS

SELECT * FROM salary_audit;


-- 4. TEST NET PAY FUNCTION

SELECT
    employee_id,
    full_name,
    fn_net_pay(employee_id) AS net_pay
FROM employees;


-- 5. DISPLAY PAYROLL REPORT

SELECT * FROM v_payroll_report;


-- 6. COUNT TOTAL EMPLOYEES

SELECT COUNT(*) AS total_employees
FROM employees;


-- 7. COUNT ACTIVE EMPLOYEES

SELECT COUNT(*) AS active_employees
FROM employees
WHERE active = TRUE;


-- 8. COUNT INACTIVE EMPLOYEES

SELECT COUNT(*) AS inactive_employees
FROM employees
WHERE active = FALSE;


-- 9. COUNT PAYROLL RECORDS

SELECT COUNT(*) AS total_payroll_records
FROM payroll;


-- 10. COUNT SALARY AUDIT RECORDS

SELECT COUNT(*) AS total_salary_changes
FROM salary_audit;


-- 11. DISPLAY SCHEDULED PAYROLL JOB

SELECT *
FROM cron.job
WHERE jobname = 'monthly-payroll-processing';


-- ============================================================
-- END OF QUESTION 6
-- ============================================================