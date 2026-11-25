-- ============================================================
-- ICT371: ADVANCED DATABASES
-- QUESTION 5: HOSTEL ROOM ALLOCATION
-- DATABASE: POSTGRESQL
-- ============================================================

CREATE SCHEMA IF NOT EXISTS q5_hostel;

SET search_path TO q5_hostel, public;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- CREATE STUDENTS TABLE

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(150) NOT NULL
);


-- CREATE ROOMS TABLE

CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INT NOT NULL CHECK (capacity > 0)
);


-- CREATE ALLOCATIONS TABLE

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,

    student_id INT NOT NULL
        REFERENCES students(student_id),

    room_id INT NOT NULL
        REFERENCES rooms(room_id),

    allocated_on DATE NOT NULL,

    released_on DATE,

    status VARCHAR(20) NOT NULL,

    CONSTRAINT chk_allocation_status
        CHECK (status IN ('ACTIVE', 'ENDED')),

    CONSTRAINT chk_allocation_dates
        CHECK (
            (status = 'ACTIVE' AND released_on IS NULL)
            OR
            (status = 'ENDED' AND released_on IS NOT NULL
             AND released_on >= allocated_on)
        )
);


-- CREATE OCCUPANCY SNAPSHOT TABLE

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,

    room_id INT NOT NULL
        REFERENCES rooms(room_id),

    occupied_beds INT NOT NULL,

    free_beds INT NOT NULL,

    PRIMARY KEY (snapshot_date, room_id),

    CHECK (occupied_beds >= 0),

    CHECK (free_beds >= 0)
);


-- INSERT FIVE STUDENTS

INSERT INTO students (
    student_number,
    full_name
)
VALUES
('2024001', 'John Banda'),
('2024002', 'Mary Phiri'),
('2024003', 'Peter Zulu'),
('2024004', 'Grace Mwila'),
('2024005', 'David Chanda');


-- INSERT THREE ROOMS

INSERT INTO rooms (
    room_number,
    capacity
)
VALUES
('R001', 2),
('R002', 3),
('R003', 2);


-- ============================================================
-- (d) CREATE TRIGGER TO ENFORCE ALLOCATION RULES
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_room_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN

    -- Only validate active allocations

    IF NEW.status = 'ACTIVE' THEN

        -- Lock room record to prevent simultaneous
        -- allocations exceeding room capacity.

        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Room ID % does not exist',
                NEW.room_id;
        END IF;


        -- Check whether student already has an
        -- active allocation.

        IF EXISTS (
            SELECT 1
            FROM allocations
            WHERE student_id = NEW.student_id
              AND status = 'ACTIVE'
              AND allocation_id <> COALESCE(
                  NEW.allocation_id, -1
              )
        ) THEN
            RAISE EXCEPTION
                'Student ID % already has an active allocation',
                NEW.student_id;
        END IF;


        -- Count occupied beds, excluding current row
        -- when updating an existing allocation.

        SELECT COUNT(*)
        INTO v_occupied
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND allocation_id <> COALESCE(
              NEW.allocation_id, -1
          );


        -- Check room capacity

        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION
                'Room % is full. Capacity: %',
                NEW.room_id,
                v_capacity;
        END IF;

    END IF;

    RETURN NEW;

END;
$$;


-- CREATE BEFORE INSERT OR UPDATE TRIGGER

CREATE TRIGGER trg_check_room_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_room_allocation();


-- INSERT SAMPLE ALLOCATIONS

-- Room R001: FULL (2 students)
INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES
(1, 1, CURRENT_DATE - 20, NULL, 'ACTIVE'),
(2, 1, CURRENT_DATE - 15, NULL, 'ACTIVE');


-- Room R002: PARTIALLY OCCUPIED (2 out of 3)
INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES
(3, 2, CURRENT_DATE - 10, NULL, 'ACTIVE'),
(4, 2, CURRENT_DATE - 8, NULL, 'ACTIVE');


-- Room R003: EMPTY
-- Student 5 has not been allocated a room.


-- ============================================================
-- (b) CREATE FUNCTION TO CALCULATE FREE BEDS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN

    -- Get room capacity

    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Room ID % does not exist',
            p_room_id;
    END IF;


    -- Count active allocations

    SELECT COUNT(*)
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';


    -- Calculate available beds

    RETURN v_capacity - v_occupied;

END;
$$;


-- ============================================================
-- (c) CREATE PROCEDURE TO ALLOCATE A ROOM
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT,
    p_room_id INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN

    -- Validate allocation date

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION
            'Allocation date cannot be NULL';
    END IF;


    -- Validate student

    PERFORM 1
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Student ID % does not exist',
            p_student_id;
    END IF;


    -- Lock room record and retrieve capacity

    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Room ID % does not exist',
            p_room_id;
    END IF;


    -- Check whether student already has an active room

    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Student already has an active room allocation';
    END IF;


    -- Count occupied beds

    SELECT COUNT(*)
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';


    -- Check room capacity

    IF v_occupied >= v_capacity THEN
        RAISE EXCEPTION
            'Room is full. No free beds available';
    END IF;


    -- Insert allocation

    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

    RAISE NOTICE
        'Student % successfully allocated to room %',
        p_student_id,
        p_room_id;

END;
$$;


-- ============================================================
-- (e) CREATE VIEW FOR ROOM OCCUPANCY
-- ============================================================

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,

    COUNT(a.allocation_id) AS occupied_beds,

    r.capacity - COUNT(a.allocation_id) AS free_beds

FROM rooms r

LEFT JOIN allocations a
    ON r.room_id = a.room_id
    AND a.status = 'ACTIVE'

GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;


-- ============================================================
-- (f) CREATE INDEX FOR ACTIVE ROOM ALLOCATIONS
-- ============================================================

CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';


-- QUERY ACTIVE ALLOCATIONS FOR A PARTICULAR ROOM

EXPLAIN
SELECT *
FROM allocations
WHERE room_id = 1
AND status = 'ACTIVE';


-- ============================================================
-- (g) CREATE DAILY OCCUPANCY SNAPSHOT PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )

    SELECT
        CURRENT_DATE,
        r.room_id,

        COUNT(a.allocation_id) AS occupied_beds,

        r.capacity - COUNT(a.allocation_id) AS free_beds

    FROM rooms r

    LEFT JOIN allocations a
        ON r.room_id = a.room_id
        AND a.status = 'ACTIVE'

    GROUP BY
        r.room_id,
        r.capacity

    ON CONFLICT (snapshot_date, room_id)

    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;


    RAISE NOTICE
        'Daily occupancy snapshot refreshed successfully';

END;
$$;


-- GENERATE TODAY'S OCCUPANCY SNAPSHOT

CALL pr_refresh_occupancy();


-- ============================================================
-- SCHEDULE DAILY OCCUPANCY SNAPSHOT AT 23:55
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily-hostel-occupancy',
    '55 23 * * *',
    'CALL q5_hostel.pr_refresh_occupancy()'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. DISPLAY ALL STUDENTS

SELECT * FROM students;


-- 2. DISPLAY ALL ROOMS

SELECT * FROM rooms;


-- 3. DISPLAY ALL ALLOCATIONS

SELECT * FROM allocations;


-- 4. TEST FREE BEDS FUNCTION

SELECT
    room_id,
    room_number,
    fn_free_beds(room_id) AS free_beds
FROM rooms;


-- 5. DISPLAY ROOM OCCUPANCY VIEW

SELECT * FROM v_room_occupancy;


-- 6. DISPLAY OCCUPANCY SNAPSHOTS

SELECT * FROM occupancy_snapshot;


-- 7. COUNT TOTAL STUDENTS

SELECT COUNT(*) AS total_students
FROM students;


-- 8. COUNT ACTIVE ALLOCATIONS

SELECT COUNT(*) AS active_allocations
FROM allocations
WHERE status = 'ACTIVE';


-- 9. COUNT ENDED ALLOCATIONS

SELECT COUNT(*) AS ended_allocations
FROM allocations
WHERE status = 'ENDED';


-- 10. DISPLAY SCHEDULED JOBS

SELECT * FROM cron.job;


-- ============================================================
-- END OF QUESTION 5
-- ============================================================