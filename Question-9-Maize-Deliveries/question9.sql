-- ============================================================
-- ICT371 - QUESTION 9
-- FARMER COOPERATIVE MAIZE DELIVERIES
-- PostgreSQL / PLpgSQL
-- ============================================================

-- Create schema
CREATE SCHEMA IF NOT EXISTS q9_maize;

SET search_path TO q9_maize;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- Farmers table
CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);


-- Deliveries table
CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INT NOT NULL,
    grade CHAR(1) NOT NULL,
    weight_kg NUMERIC(12,2) NOT NULL,
    unit_rate NUMERIC(10,2),
    total_value NUMERIC(14,2),
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN DEFAULT FALSE,

    CONSTRAINT fk_farmer
        FOREIGN KEY (farmer_id)
        REFERENCES farmers(farmer_id),

    CONSTRAINT chk_grade
        CHECK (grade IN ('A', 'B', 'C')),

    CONSTRAINT chk_weight
        CHECK (weight_kg > 0),

    CONSTRAINT chk_unit_rate
        CHECK (unit_rate IS NULL OR unit_rate > 0),

    CONSTRAINT chk_total_value
        CHECK (total_value IS NULL OR total_value >= 0)
);


-- Daily purchases table
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(14,2) NOT NULL,
    total_value NUMERIC(14,2) NOT NULL,

    CONSTRAINT chk_total_weight
        CHECK (total_weight >= 0),

    CONSTRAINT chk_total_value
        CHECK (total_value >= 0)
);


-- Insert sample farmers
INSERT INTO farmers (farmer_number, full_name)
VALUES
('FARM001', 'John Banda'),
('FARM002', 'Mary Phiri'),
('FARM003', 'Peter Zulu');


-- ============================================================
-- (b) FUNCTION TO RETURN MAIZE RATE
-- ============================================================

CREATE OR REPLACE FUNCTION fn_maize_rate(
    p_grade CHAR(1)
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    CASE UPPER(p_grade)

        WHEN 'A' THEN
            RETURN 5.00;

        WHEN 'B' THEN
            RETURN 4.00;

        WHEN 'C' THEN
            RETURN 3.00;

        ELSE
            RAISE EXCEPTION 'Invalid maize grade: %', p_grade;

    END CASE;

END;
$$;


-- ============================================================
-- (c) PROCEDURE TO RECEIVE MAIZE DELIVERY
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade CHAR(1),
    p_weight NUMERIC,
    p_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate farmer ID
    IF p_farmer_id IS NULL THEN
        RAISE EXCEPTION 'Farmer ID cannot be NULL';
    END IF;

    -- Validate grade
    IF p_grade IS NULL OR UPPER(p_grade) NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid maize grade';
    END IF;

    -- Validate weight
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be greater than zero';
    END IF;

    -- Validate delivery date
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date cannot be NULL';
    END IF;

    -- Check farmer exists
    PERFORM 1
    FROM farmers
    WHERE farmer_id = p_farmer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Farmer ID % does not exist', p_farmer_id;
    END IF;

    -- Insert delivery.
    -- Trigger calculates the unit rate and total value.
    INSERT INTO deliveries (
        farmer_id,
        grade,
        weight_kg,
        delivered_on,
        is_paid
    )
    VALUES (
        p_farmer_id,
        UPPER(p_grade),
        p_weight,
        p_date,
        FALSE
    );

    RAISE NOTICE 'Delivery received successfully from farmer %',
        p_farmer_id;

END;
$$;


-- ============================================================
-- (d) BEFORE INSERT OR UPDATE TRIGGER
-- AUTOMATICALLY CALCULATE DELIVERY VALUE
-- ============================================================

CREATE OR REPLACE FUNCTION fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate weight
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be greater than zero';
    END IF;

    -- Validate grade
    IF NEW.grade IS NULL THEN
        RAISE EXCEPTION 'Maize grade cannot be NULL';
    END IF;

    NEW.grade := UPPER(NEW.grade);

    -- Calculate rate from grade
    NEW.unit_rate := fn_maize_rate(NEW.grade);

    -- Calculate total delivery value
    NEW.total_value := ROUND(
        NEW.weight_kg * NEW.unit_rate,
        2
    );

    RETURN NEW;

END;
$$;


-- Create trigger
CREATE TRIGGER trg_calculate_delivery_value
BEFORE INSERT OR UPDATE
ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_value();


-- ============================================================
-- INSERT SIX SAMPLE DELIVERIES USING THE PROCEDURE
-- ============================================================

-- Farmer 1: John Banda
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 5);
CALL pr_receive_delivery(1, 'B', 150, CURRENT_DATE - 4);

-- Farmer 2: Mary Phiri
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 3);
CALL pr_receive_delivery(2, 'A', 120, CURRENT_DATE - 2);

-- Farmer 3: Peter Zulu
CALL pr_receive_delivery(3, 'B', 180, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 250, CURRENT_DATE);


-- ============================================================
-- UPDATE PAYMENT STATUS FOR TESTING
-- ============================================================

-- John pays his first delivery
UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id = 1;

-- Mary pays her first delivery
UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id = 3;

-- Peter pays his second delivery
UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id = 6;


-- ============================================================
-- (e) CREATE VIEW FOR FARMER AMOUNTS DUE
-- ============================================================

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(
        SUM(
            CASE
                WHEN d.is_paid = FALSE
                THEN d.total_value
                ELSE 0
            END
        ),
        0
    ) AS total_amount_due

FROM farmers f

LEFT JOIN deliveries d
    ON f.farmer_id = d.farmer_id

GROUP BY
    f.farmer_id,
    f.farmer_number,
    f.full_name;


-- Display farmer amounts due
SELECT *
FROM v_farmer_amount_due;


-- ============================================================
-- (f) CREATE COMPOSITE INDEX FOR FARMER AND DELIVERY DATE
-- ============================================================

CREATE INDEX idx_deliveries_farmer_date
ON deliveries(farmer_id, delivered_on);


-- Query deliveries for a particular farmer within a date range
EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ============================================================
-- (g) PROCEDURE TO REFRESH DAILY PURCHASE SUMMARY
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_weight NUMERIC(14,2);
    v_total_value NUMERIC(14,2);
BEGIN

    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Purchase date cannot be NULL';
    END IF;

    -- Calculate total weight and value for the selected day
    SELECT
        COALESCE(SUM(weight_kg), 0),
        COALESCE(SUM(total_value), 0)
    INTO
        v_total_weight,
        v_total_value
    FROM deliveries
    WHERE delivered_on = p_day;

    -- Insert or replace daily summary
    INSERT INTO daily_purchases (
        purchase_date,
        total_weight,
        total_value
    )
    VALUES (
        p_day,
        v_total_weight,
        v_total_value
    )

    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;

    RAISE NOTICE
        'Daily purchase summary refreshed for %',
        p_day;

END;
$$;


-- Refresh today's purchases
CALL pr_refresh_purchases(CURRENT_DATE);


-- ============================================================
-- SCHEDULE DAILY EXECUTION AT 01:30
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
    WHERE jobname = 'q9_refresh_purchases';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

END;
$$;


-- Schedule daily execution at 01:30
-- Refreshes the previous day's purchases.
SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',
    'CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1);'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. Display all farmers
SELECT * FROM farmers;

-- 2. Display all deliveries
SELECT * FROM deliveries;

-- 3. Display farmer amounts due
SELECT * FROM v_farmer_amount_due;

-- 4. Display daily purchase summaries
SELECT * FROM daily_purchases;

-- 5. Test maize rate function
SELECT fn_maize_rate('A') AS grade_a_rate;
SELECT fn_maize_rate('B') AS grade_b_rate;
SELECT fn_maize_rate('C') AS grade_c_rate;

-- 6. Test delivery index
EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- 7. Display scheduled job (requires pg_cron)
SELECT *
FROM cron.job
WHERE jobname = 'q9_refresh_purchases';


-- ============================================================
-- END OF QUESTION 9
-- ============================================================