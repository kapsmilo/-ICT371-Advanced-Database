-- ============================================================
-- ICT371: ADVANCED DATABASES
-- QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
-- DATABASE: POSTGRESQL
-- ============================================================

CREATE SCHEMA IF NOT EXISTS q3_library;

SET search_path TO q3_library, public;


-- ============================================================
-- (a) CREATE TABLES AND INSERT SAMPLE DATA
-- ============================================================

-- CREATE BOOKS TABLE

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL
);


-- CREATE LOANS TABLE

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(150) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(12,2) NOT NULL DEFAULT 0
        CHECK (fine_amount >= 0),

    CONSTRAINT chk_due_date
        CHECK (due_on >= borrowed_on),

    CONSTRAINT chk_return_date
        CHECK (
            returned_on IS NULL
            OR returned_on >= borrowed_on
        )
);


-- CREATE LOAN AUDIT TABLE

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- CREATE OVERDUE SUMMARY TABLE

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine NUMERIC(14,2) NOT NULL
);


-- INSERT THREE BOOKS

INSERT INTO books (title)
VALUES
('Introduction to Database Systems'),
('Computer Networking Fundamentals'),
('Principles of Cyber Security');


-- INSERT SIX SAMPLE LOANS

INSERT INTO loans (
    book_id,
    borrower_name,
    borrowed_on,
    due_on
)
VALUES
-- Open overdue loan
(1, 'John Banda', CURRENT_DATE - 20, CURRENT_DATE - 10),

-- Another open overdue loan
(2, 'Mary Phiri', CURRENT_DATE - 8, CURRENT_DATE - 2),

-- Open loan that is not yet overdue
(3, 'Peter Zulu', CURRENT_DATE - 5, CURRENT_DATE + 2),

-- Loan that will be returned late
(1, 'Grace Mwila', CURRENT_DATE - 30, CURRENT_DATE - 20),

-- Loan that will be returned on time
(2, 'David Chanda', CURRENT_DATE - 15, CURRENT_DATE - 5),

-- Another open loan that is not yet overdue
(3, 'Sarah Tembo', CURRENT_DATE - 3, CURRENT_DATE + 4);


-- ============================================================
-- (b) CREATE FUNCTION TO CALCULATE LOAN FINES
-- ============================================================

-- Fine rate = K2 per overdue day.

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INT,
    p_as_of DATE
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INT;
    v_fine NUMERIC(12,2);
BEGIN

    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Calculation date cannot be NULL';
    END IF;

    -- Find loan information

    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist',
            p_loan_id;
    END IF;

    -- Determine the date used for fine calculation.
    -- For returned books, use the earlier of the
    -- calculation date and the return date.

    v_effective_date := LEAST(
        p_as_of,
        COALESCE(v_returned_on, p_as_of)
    );

    -- Calculate overdue days

    v_overdue_days := GREATEST(
        v_effective_date - v_due_on,
        0
    );

    -- Calculate fine at K2 per overdue day

    v_fine := v_overdue_days * 2.00;

    RETURN v_fine;

END;
$$;


-- ============================================================
-- (c) CREATE PROCEDURE TO RETURN A BOOK
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INT,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_existing_return DATE;
    v_fine NUMERIC(12,2);
BEGIN

    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL';
    END IF;

    -- Lock the loan record

    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_existing_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan ID % does not exist',
            p_loan_id;
    END IF;

    -- Reject already returned books

    IF v_existing_return IS NOT NULL THEN
        RAISE EXCEPTION
            'Loan ID % has already been returned',
            p_loan_id;
    END IF;

    -- Validate return date

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION
            'Return date cannot be before borrowed date';
    END IF;

    -- Calculate final fine

    v_fine := fn_loan_fine(
        p_loan_id,
        p_returned_on
    );

    -- Update return date and fine together

    UPDATE loans
    SET
        returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;

    RAISE NOTICE
        'Book returned successfully. Fine: K%',
        v_fine;

END;
$$;


-- ============================================================
-- (d) CREATE AFTER UPDATE LOAN AUDIT TRIGGER
-- ============================================================

CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Only record an audit if returned_on changes

    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN

        INSERT INTO loan_audit (
            loan_id,
            old_returned_on,
            new_returned_on,
            changed_at
        )
        VALUES (
            NEW.loan_id,
            OLD.returned_on,
            NEW.returned_on,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


-- CREATE AFTER UPDATE TRIGGER

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_loan_audit();


-- RETURN TWO SAMPLE BOOKS USING THE PROCEDURE

CALL pr_return_loan(
    4,
    CURRENT_DATE - 17
);

CALL pr_return_loan(
    5,
    CURRENT_DATE - 6
);


-- ============================================================
-- (e) CREATE VIEW FOR OVERDUE LOANS
-- ============================================================

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    l.loan_id,
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_amount

FROM loans l

JOIN books b
    ON l.book_id = b.book_id

WHERE
    l.returned_on IS NULL
    AND l.due_on < CURRENT_DATE;


-- DISPLAY OVERDUE LOANS

SELECT * FROM v_overdue_loans;


-- ============================================================
-- (f) CREATE INDEX FOR UNRETURNED LOANS BY BOOK
-- ============================================================

CREATE INDEX idx_loans_book_unreturned
ON loans (book_id)
WHERE returned_on IS NULL;


-- QUERY TO FIND UNRETURNED LOANS FOR A PARTICULAR BOOK

EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
AND returned_on IS NULL;


-- ============================================================
-- (g) CREATE DAILY OVERDUE SUMMARY PROCEDURE
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_as_of IS NULL THEN
        RAISE EXCEPTION
            'Snapshot date cannot be NULL';
    END IF;

    -- Calculate overdue loans and their total fines
    -- as at the specified date.

    INSERT INTO overdue_summary (
        snapshot_date,
        overdue_count,
        total_fine
    )
    SELECT
        p_as_of,
        COUNT(*),
        COALESCE(
            SUM(fn_loan_fine(loan_id, p_as_of)),
            0
        )
    FROM loans
    WHERE
        due_on < p_as_of
        AND (
            returned_on IS NULL
            OR returned_on > p_as_of
        )

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;

    RAISE NOTICE
        'Overdue summary refreshed for %',
        p_as_of;

END;
$$;


-- GENERATE TODAY'S OVERDUE SUMMARY

CALL pr_refresh_overdue(CURRENT_DATE);


-- ============================================================
-- SCHEDULE DAILY OVERDUE SUMMARY AT 00:10
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily-library-overdue-summary',
    '10 0 * * *',
    'CALL q3_library.pr_refresh_overdue(CURRENT_DATE)'
);


-- ============================================================
-- FINAL VERIFICATION
-- ============================================================

-- 1. DISPLAY ALL BOOKS

SELECT * FROM books;


-- 2. DISPLAY ALL LOANS

SELECT * FROM loans;


-- 3. DISPLAY LOAN AUDIT RECORDS

SELECT * FROM loan_audit;


-- 4. TEST FINE CALCULATION FUNCTION

SELECT
    loan_id,
    borrower_name,
    fn_loan_fine(loan_id, CURRENT_DATE) AS calculated_fine
FROM loans;


-- 5. DISPLAY OVERDUE LOANS

SELECT * FROM v_overdue_loans;


-- 6. DISPLAY OVERDUE SUMMARY

SELECT * FROM overdue_summary;


-- 7. COUNT TOTAL LOANS

SELECT COUNT(*) AS total_loans
FROM loans;


-- 8. COUNT RETURNED BOOKS

SELECT COUNT(*) AS returned_books
FROM loans
WHERE returned_on IS NOT NULL;


-- 9. COUNT UNRETURNED BOOKS

SELECT COUNT(*) AS unreturned_books
FROM loans
WHERE returned_on IS NULL;


-- 10. COUNT AUDIT RECORDS

SELECT COUNT(*) AS total_audit_records
FROM loan_audit;


-- 11. DISPLAY SCHEDULED JOBS

SELECT * FROM cron.job;


-- ============================================================
-- END OF QUESTION 3
-- ============================================================