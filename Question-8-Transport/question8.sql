-- ============================================================
-- ICT371 - QUESTION 8
-- TRANSPORT FLEET MANAGEMENT SYSTEM
-- PostgreSQL / PLpgSQL
-- ============================================================

-- Create schema
CREATE SCHEMA IF NOT EXISTS q8_transport;

SET search_path TO q8_transport;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- Vehicles table
CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(20) UNIQUE NOT NULL,
    current_odometer NUMERIC(12,2) NOT NULL,
    last_service_odometer NUMERIC(12,2) NOT NULL,

    CONSTRAINT chk_current_odometer
        CHECK (current_odometer >= 0),

    CONSTRAINT chk_last_service_odometer
        CHECK (last_service_odometer >= 0),

    CONSTRAINT chk_service_position
        CHECK (last_service_odometer <= current_odometer)
);


-- Trips table
CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INT NOT NULL,
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL,
    end_odometer NUMERIC(12,2) NOT NULL,

    CONSTRAINT fk_vehicle
        FOREIGN KEY (vehicle_id)
        REFERENCES vehicles(vehicle_id),

    CONSTRAINT chk_start_odometer
        CHECK (start_odometer >= 0),

    CONSTRAINT chk_end_odometer
        CHECK (end_odometer > start_odometer)
);


-- Service alerts table
CREATE TABLE service_alerts (
    vehicle_id INT PRIMARY KEY,
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on DATE NOT NULL,

    CONSTRAINT fk_alert_vehicle
        FOREIGN KEY (vehicle_id)
        REFERENCES vehicles(vehicle_id),

    CONSTRAINT chk_km_since_service
        CHECK (km_since_service >= 0)
);


-- Insert sample vehicles
INSERT INTO vehicles (
    registration,
    current_odometer,
    last_service_odometer
)
VALUES
('ALX 1234', 10000, 6000),
('BMX 5678', 25000, 22000),
('CLX 9012', 50000, 40000);


-- ============================================================
-- (b) FUNCTION TO CHECK WHETHER SERVICE IS DUE
-- ============================================================

CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current NUMERIC(12,2);
    v_last_service NUMERIC(12,2);
BEGIN

    SELECT current_odometer, last_service_odometer
    INTO v_current, v_last_service
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last_service) >= 5000;

END;
$$;


-- ============================================================
-- (c) PROCEDURE TO RECORD VEHICLE TRIPS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on DATE,
    p_start NUMERIC,
    p_end NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate input
    IF p_vehicle_id IS NULL THEN
        RAISE EXCEPTION 'Vehicle ID cannot be NULL';
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL';
    END IF;

    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Odometer readings cannot be NULL';
    END IF;

    IF p_start < 0 THEN
        RAISE EXCEPTION 'Starting odometer cannot be negative';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION
            'Ending odometer must be greater than starting odometer';
    END IF;

    -- Check whether vehicle exists
    PERFORM 1
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    -- Insert trip.
    -- The trigger will update the vehicle odometer.
    INSERT INTO trips (
        vehicle_id,
        trip_on,
        start_odometer,
        end_odometer
    )
    VALUES (
        p_vehicle_id,
        p_trip_on,
        p_start,
        p_end
    );

    RAISE NOTICE 'Trip recorded successfully for vehicle %',
        p_vehicle_id;

END;
$$;


-- ============================================================
-- (d) BEFORE INSERT TRIGGER
-- VALIDATE TRIP AND UPDATE VEHICLE ODOMETER
-- ============================================================

CREATE OR REPLACE FUNCTION fn_update_vehicle_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odometer NUMERIC(12,2);
BEGIN

    -- Lock vehicle row to prevent concurrent trip conflicts
    SELECT current_odometer
    INTO v_current_odometer
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle ID % does not exist',
            NEW.vehicle_id;
    END IF;

    -- Starting reading must match current vehicle reading
    IF NEW.start_odometer <> v_current_odometer THEN
        RAISE EXCEPTION
            'Invalid starting odometer. Current vehicle reading is %',
            v_current_odometer;
    END IF;

    -- Ending reading must be greater than starting reading
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION
            'Ending odometer must be greater than starting odometer';
    END IF;

    -- Update vehicle odometer exactly once
    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;

END;
$$;


-- Create trigger
CREATE TRIGGER trg_update_vehicle_odometer
BEFORE INSERT
ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_update_vehicle_odometer();


-- ============================================================
-- INSERT SIX SAMPLE TRIPS USING THE PROCEDURE
-- ============================================================

-- Vehicle 1: starts at 10000
CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10500);
CALL pr_record_trip(1, CURRENT_DATE - 5, 10500, 11000);

-- Vehicle 2: starts at 25000
CALL pr_record_trip(2, CURRENT_DATE - 4, 25000, 25400);
CALL pr_record_trip(2, CURRENT_DATE - 3, 25400, 26000);

-- Vehicle 3: starts at 50000
CALL pr_record_trip(3, CURRENT_DATE - 2, 50000, 50700);
CALL pr_record_trip(3, CURRENT_DATE - 1, 50700, 51500);


-- ============================================================
-- (e) CREATE VIEW FOR VEHICLES DUE FOR SERVICE
-- ============================================================

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    vehicle_id,
    registration,
    current_odometer,
    last_service_odometer,
    (current_odometer - last_service_odometer)
        AS km_since_service
FROM vehicles
WHERE
    (current_odometer - last_service_odometer) >= 5000;


-- Display vehicles due for service
SELECT *
FROM v_service_due;


-- Test the service function
SELECT
    vehicle_id,
    registration,
    fn_service_due(vehicle_id) AS service_due
FROM vehicles;


-- ============================================================
-- (f) CREATE INDEX FOR VEHICLE TRIP DATE SEARCHES
-- ============================================================

CREATE INDEX idx_trips_vehicle_date
ON trips(vehicle_id, trip_on);


-- Query trips for a specific vehicle within a date range
EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ============================================================
-- (g) PROCEDURE TO REFRESH SERVICE ALERTS
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN

    -- Insert or update alerts for vehicles due for service
    INSERT INTO service_alerts (
        vehicle_id,
        km_since_service,
        flagged_on
    )
    SELECT
        vehicle_id,
        current_odometer - last_service_odometer,
        CURRENT_DATE
    FROM vehicles
    WHERE
        current_odometer - last_service_odometer >= 5000

    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;


    -- Remove alerts for vehicles that are no longer due
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
        AND v.current_odometer - v.last_service_odometer >= 5000
    );

    RAISE NOTICE 'Service alerts refreshed successfully';

END;
$$;


-- Execute procedure
CALL pr_refresh_service_alerts();


-- ============================================================
-- SCHEDULE SERVICE ALERT REFRESH EVERY MONDAY AT 06:00
-- Requires pg_cron extension to be installed and configured.
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
    WHERE jobname = 'q8_refresh_service_alerts';

    IF v_job_id IS NOT NULL THEN
        PERFORM cron.unschedule(v_job_id);
    END IF;

END;
$$;


-- Schedule every Monday at 06:00
SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',
    'CALL q8_transport.pr_refresh_service_alerts();'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. Display all vehicles
SELECT * FROM vehicles;

-- 2. Display all recorded trips
SELECT * FROM trips;

-- 3. Display vehicles due for service
SELECT * FROM v_service_due;

-- 4. Display service alerts
SELECT * FROM service_alerts;

-- 5. Test service function
SELECT
    registration,
    fn_service_due(vehicle_id) AS service_due
FROM vehicles;

-- 6. Test trip index
EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- 7. Display scheduled job (requires pg_cron)
SELECT *
FROM cron.job
WHERE jobname = 'q8_refresh_service_alerts';


-- ============================================================
-- END OF QUESTION 8
-- ============================================================