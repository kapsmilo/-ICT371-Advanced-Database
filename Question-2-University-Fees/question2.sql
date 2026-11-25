-- ============================================================
-- ICT371: ADVANCED DATABASES
-- QUESTION 2: UNIVERSITY FEE PAYMENTS
-- PostgreSQL / PLpgSQL
-- ============================================================

CREATE SCHEMA IF NOT EXISTS q2_fees;
SET search_path TO q2_fees, public;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(150) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INT NOT NULL,
    total_amount NUMERIC(14,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due)
VALUES
('2024001', 'John Banda', 1000.00),
('2024002', 'Mary Phiri', 1500.00),
('2024003', 'Peter Zulu', 800.00);


-- ============================================================
-- (b) CREATE FUNCTION TO CALCULATE OUTSTANDING FEE BALANCE
-- ============================================================

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INT
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_total_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
            p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_total_paid;
END;
$$;


-- ============================================================
-- (c) CREATE PROCEDURE TO RECEIVE STUDENT PAYMENTS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount NUMERIC(12,2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_total_paid NUMERIC(12,2);
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION
            'Payment amount must be greater than zero';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION
            'Payment date cannot be NULL';
    END IF;

    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student ID % does not exist',
            p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    v_balance := v_fee_due - v_total_paid;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION
            'Payment exceeds outstanding balance of K%',
            v_balance;
    END IF;

    INSERT INTO payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );

    RAISE NOTICE 'Payment of K% recorded successfully',
        p_amount;
END;
$$;


-- ============================================================
-- (d) CREATE AUTOMATIC PAYMENT AUDIT TRIGGER
-- ============================================================

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();


-- INSERT SIX SAMPLE PAYMENTS THROUGH THE PROCEDURE

CALL pr_receive_payment(1, 300.00, CURRENT_DATE);
CALL pr_receive_payment(1, 200.00, CURRENT_DATE);
CALL pr_receive_payment(1, 150.00, CURRENT_DATE);

CALL pr_receive_payment(2, 500.00, CURRENT_DATE);
CALL pr_receive_payment(2, 400.00, CURRENT_DATE);
CALL pr_receive_payment(2, 100.00, CURRENT_DATE);


-- ============================================================
-- (e) CREATE VIEW FOR STUDENTS WHO STILL OWE FEES
-- ============================================================

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0)
        AS outstanding_balance
FROM students s
LEFT JOIN payments p
    ON s.student_id = p.student_id
GROUP BY
    s.student_id,
    s.student_number,
    s.full_name,
    s.fee_due
HAVING
    s.fee_due - COALESCE(SUM(p.amount), 0) > 0;


-- ============================================================
-- (f) CREATE COMPOSITE INDEX AND DISPLAY EXECUTION PLAN
-- ============================================================

CREATE INDEX idx_payments_student_date
ON payments (student_id, paid_on);

EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
AND paid_on BETWEEN DATE '2026-01-01'
                AND DATE '2026-12-31';


-- ============================================================
-- (g) CREATE DAILY COLLECTIONS SUMMARY PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Collection date cannot be NULL';
    END IF;

    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(*),
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;

    RAISE NOTICE 'Daily collections refreshed for %',
        p_day;
END;
$$;


-- GENERATE TODAY'S COLLECTION SUMMARY

CALL pr_refresh_collections(CURRENT_DATE);


-- SCHEDULE DAILY COLLECTION REPORT AT 01:00

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily-university-collections',
    '0 1 * * *',
    'CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- Display students
SELECT * FROM students;

-- Display payments
SELECT * FROM payments;

-- Display payment audit records
SELECT * FROM payment_audit;

-- Test fee balance function
SELECT
    student_id,
    full_name,
    fn_fee_balance(student_id) AS outstanding_balance
FROM students;

-- Display students who still owe fees
SELECT * FROM v_fee_balances;

-- Display daily collections
SELECT * FROM daily_collections;

-- Count payments
SELECT COUNT(*) AS total_payments
FROM payments;

-- Count audit records
SELECT COUNT(*) AS total_audit_records
FROM payment_audit;

-- Display scheduled jobs (requires pg_cron)
SELECT * FROM cron.job;

-- ============================================================
-- END OF QUESTION 2
-- ============================================================