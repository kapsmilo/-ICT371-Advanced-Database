-- QUESTION 1(a): DATABASE AND TABLE CREATION

CREATE SCHEMA IF NOT EXISTS q1_pharmacy;

SET search_path TO q1_pharmacy, public;

-- 1. Medicines table
CREATE TABLE medicines (
    medicine_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

-- 2. Sales table
CREATE TABLE sales (
    sale_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL
);

-- 3. Stock audit table
CREATE TABLE stock_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INT NOT NULL,
    new_qty INT NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Daily sales table
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INT NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Insert three medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty)
VALUES
('Paracetamol', 5.00, 100),
('Amoxicillin', 15.00, 60),
('Vitamin C', 8.00, 80);

-- Display medicines
SELECT * FROM medicines;


-- QUESTION 1(b): FUNCTION

SET search_path TO q1_pharmacy, public;

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INT,
    p_quantity INT
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN

    -- Validate quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Get medicine price
    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    -- Check medicine existence
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine ID % does not exist',
        p_medicine_id;
    END IF;

    -- Return total sale value
    RETURN v_price * p_quantity;

END;
$$;

-- Test function
SELECT fn_sale_value(1, 5);


-- QUESTION 1(c): PROCEDURE

SET search_path TO q1_pharmacy, public;

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity INT,
    p_sold_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN

    -- Validate inputs
    IF p_medicine_id IS NULL
       OR p_quantity IS NULL
       OR p_sold_on IS NULL THEN
        RAISE EXCEPTION 'All inputs are required';
    END IF;

    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- Lock and retrieve medicine record
    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    -- Check medicine existence
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine does not exist';
    END IF;

    -- Check stock availability
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock available';
    END IF;

    -- Record sale using current price
    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;

-- Insert six valid sales through the procedure
CALL pr_record_sale(1, 5, CURRENT_DATE);
CALL pr_record_sale(2, 3, CURRENT_DATE);
CALL pr_record_sale(3, 10, CURRENT_DATE);
CALL pr_record_sale(1, 8, CURRENT_DATE);
CALL pr_record_sale(2, 2, CURRENT_DATE);
CALL pr_record_sale(3, 5, CURRENT_DATE);

-- Display sales
SELECT * FROM sales;

-- Display updated stock
SELECT * FROM medicines;



-- QUESTION 1(d): TRIGGER

SET search_path TO q1_pharmacy, public;

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO stock_audit (
        medicine_id,
        old_qty,
        new_qty,
        changed_at
    )
    VALUES (
        OLD.medicine_id,
        OLD.stock_qty,
        NEW.stock_qty,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;

END;
$$;


CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION fn_stock_audit();

-- Display stock audit history
SELECT * FROM stock_audit;



-- QUESTION 1(e): VIEW

SET search_path TO q1_pharmacy, public;

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty
FROM medicines
WHERE stock_qty < 10;

-- Display low-stock medicines
SELECT * FROM v_low_stock;

-- Example: Make a medicine's stock fall below 10
CALL pr_record_sale(1, 80, CURRENT_DATE);

-- Query the view again
SELECT * FROM v_low_stock;



-- QUESTION 1(f): INDEX

SET search_path TO q1_pharmacy, public;

-- Create composite index
CREATE INDEX idx_sales_medicine_date
ON sales (medicine_id, sold_on);

-- Matching query
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN DATE '2026-11-01'
AND DATE '2026-11-30';

-- Display execution plan
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN DATE '2026-11-01'
AND DATE '2026-11-30';

-- Display index
SELECT indexname, indexdef
FROM pg_indexes
WHERE schemaname = 'q1_pharmacy';




-- QUESTION 1(g): SCHEDULED JOB

SET search_path TO q1_pharmacy, public;

-- Create procedure
CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Sales date cannot be NULL';
    END IF;

    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;

-- Test procedure
CALL pr_refresh_sales(CURRENT_DATE);

-- Display daily sales report
SELECT * FROM daily_sales;



CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'pharmacy_daily_sales_refresh',
    '15 0 * * *',
    $job$
    CALL q1_pharmacy.pr_refresh_sales(
        CURRENT_DATE - 1
    );
    $job$
);

SELECT *
FROM cron.job;

