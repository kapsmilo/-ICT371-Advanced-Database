-- ============================================================
-- ICT371 - QUESTION 7
-- WATER METER READING AND BILLING SYSTEM
-- Database: PostgreSQL
-- ============================================================

-- Create a separate schema
CREATE SCHEMA IF NOT EXISTS q7_water;

-- Set schema
SET search_path TO q7_water;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- Customers table
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Readings table
CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL,
    current_reading NUMERIC(12,2) NOT NULL,

    CONSTRAINT fk_customer
        FOREIGN KEY (customer_id)
        REFERENCES customers(customer_id),

    CONSTRAINT chk_previous_reading
        CHECK (previous_reading >= 0),

    CONSTRAINT chk_current_reading
        CHECK (current_reading >= 0),

    CONSTRAINT chk_month_start
        CHECK (EXTRACT(DAY FROM reading_month) = 1),

    CONSTRAINT uq_customer_month
        UNIQUE (customer_id, reading_month)
);

-- Bills table
CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INT NOT NULL UNIQUE,
    charge NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) DEFAULT 0,
    due_on DATE NOT NULL,

    CONSTRAINT fk_reading
        FOREIGN KEY (reading_id)
        REFERENCES readings(reading_id),

    CONSTRAINT chk_charge
        CHECK (charge >= 0),

    CONSTRAINT chk_amount_paid
        CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

-- Receivable snapshot table
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
        CHECK (total_due >= 0)
);


-- Insert customers
INSERT INTO customers (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');


-- ============================================================
-- (b) FUNCTION TO CALCULATE WATER CHARGES
-- ============================================================

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN

    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Water consumption cannot be NULL or negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);

END;
$$;


-- ============================================================
-- (c) PROCEDURE TO GENERATE WATER BILLS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INT,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_units NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN

    -- Validate reading ID
    IF p_reading_id IS NULL THEN
        RAISE EXCEPTION 'Reading ID cannot be NULL';
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    -- Obtain consumption
    SELECT current_reading - previous_reading
    INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading ID % does not exist', p_reading_id;
    END IF;

    -- Calculate charge
    v_charge := fn_water_charge(v_units);

    -- Insert bill
    INSERT INTO bills (
        reading_id,
        charge,
        amount_paid,
        due_on
    )
    VALUES (
        p_reading_id,
        v_charge,
        0,
        p_due_on
    );

    RAISE NOTICE 'Bill generated. Reading ID: %, Units: %, Charge: K%',
        p_reading_id, v_units, v_charge;

END;
$$;


-- ============================================================
-- (d) TRIGGER TO VALIDATE METER READINGS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF NEW.previous_reading < 0 OR NEW.current_reading < 0 THEN
        RAISE EXCEPTION 'Meter readings cannot be negative';
    END IF;

    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Current reading cannot be less than previous reading';
    END IF;

    RETURN NEW;

END;
$$;


CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE
ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();


-- ============================================================
-- INSERT SIX SAMPLE METER READINGS
-- ============================================================

INSERT INTO readings (
    customer_id,
    reading_month,
    previous_reading,
    current_reading
)
VALUES
-- Zero consumption
(1, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 months')::DATE,
 100, 100),

-- Exactly 10 units
(1, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE,
 100, 110),

-- More than 10 units: 15 units
(2, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 months')::DATE,
 200, 215),

-- More than 10 units: 20 units
(2, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE,
 215, 235),

-- Exactly 10 units
(3, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 months')::DATE,
 300, 310),

-- More than 10 units: 12 units
(3, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE,
 310, 322);


-- ============================================================
-- GENERATE BILLS USING THE PROCEDURE
-- ============================================================

CALL pr_generate_bill(1, CURRENT_DATE - 1);
CALL pr_generate_bill(2, CURRENT_DATE - 1);
CALL pr_generate_bill(3, CURRENT_DATE - 1);
CALL pr_generate_bill(4, CURRENT_DATE - 1);
CALL pr_generate_bill(5, CURRENT_DATE - 1);
CALL pr_generate_bill(6, CURRENT_DATE - 1);


-- ============================================================
-- UPDATE SOME PAYMENTS FOR TESTING
-- ============================================================

-- John pays his second bill
UPDATE bills
SET amount_paid = 30
WHERE reading_id = 2;

-- Mary pays her first bill partially
UPDATE bills
SET amount_paid = 40
WHERE reading_id = 3;

-- Peter pays his first bill fully
UPDATE bills
SET amount_paid = 50
WHERE reading_id = 5;


-- ============================================================
-- (e) CREATE VIEW FOR OVERDUE BILLS
-- ============================================================

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name,
    b.bill_id,
    b.due_on,
    b.charge,
    b.amount_paid,
    (b.charge - b.amount_paid) AS outstanding_amount

FROM bills b

JOIN readings r
    ON b.reading_id = r.reading_id

JOIN customers c
    ON r.customer_id = c.customer_id

WHERE
    b.due_on < CURRENT_DATE
    AND b.amount_paid < b.charge;


-- View overdue bills
SELECT *
FROM v_overdue_bills;


-- ============================================================
-- (f) CREATE INDEX FOR OVERDUE BILL DATE SEARCHES
-- ============================================================

CREATE INDEX idx_bills_due_on
ON bills(due_on);


-- Query using the indexed date column
EXPLAIN
SELECT *
FROM bills
WHERE due_on < CURRENT_DATE;


-- ============================================================
-- (g) PROCEDURE TO REFRESH RECEIVABLE SNAPSHOT
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(14,2);
BEGIN

    -- Calculate all outstanding balances
    SELECT COALESCE(
        SUM(charge - amount_paid), 0
    )
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    -- Insert or replace today's snapshot
    INSERT INTO receivable_snapshot (
        snapshot_date,
        total_due
    )
    VALUES (
        CURRENT_DATE,
        v_total_due
    )

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;

    RAISE NOTICE 'Receivable snapshot refreshed. Total due: K%',
        v_total_due;

END;
$$;


-- Run the snapshot procedure
CALL pr_refresh_receivables();


-- ============================================================
-- SCHEDULE DAILY EXECUTION AT 00:30
-- ============================================================

-- pg_cron must be installed and enabled on your PostgreSQL server.
-- Run this scheduling section only if pg_cron is available.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Remove an existing job with the same name to avoid duplicates.
DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    SELECT jobid
    INTO v_job_id
    FROM cron.job
    WHERE jobname = 'q7_refresh_receivables';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;
END;
$$;

-- Schedule daily execution at 00:30
SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    'CALL q7_water.pr_refresh_receivables();'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. Display all customers
SELECT * FROM customers;

-- 2. Display all meter readings
SELECT * FROM readings;

-- 3. Display all generated bills
SELECT * FROM bills;

-- 4. Display overdue bills
SELECT * FROM v_overdue_bills;

-- 5. Display receivable snapshot
SELECT * FROM receivable_snapshot;

-- 6. Test water charge function
SELECT fn_water_charge(0) AS zero_units;
SELECT fn_water_charge(10) AS ten_units;
SELECT fn_water_charge(15) AS fifteen_units;
SELECT fn_water_charge(20) AS twenty_units;

-- 7. Test index query
EXPLAIN
SELECT *
FROM bills
WHERE due_on < CURRENT_DATE;

-- 8. Display scheduled job (requires pg_cron)
SELECT *
FROM cron.job
WHERE jobname = 'q7_refresh_receivables';

-- ============================================================
-- END OF QUESTION 7
-- ============================================================