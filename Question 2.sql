DROP VIEW IF EXISTS v_fee_balances CASCADE;
DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Tables & Constraints
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(10, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    paid_on    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due    NUMERIC(10, 2);
    v_total_paid NUMERIC(10, 2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_total_paid;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(10, 2),
    p_paid_on    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due    NUMERIC(10, 2);
    v_total_paid NUMERIC(10, 2);
    v_balance    NUMERIC(10, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: %', p_amount;
    END IF;

    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    v_balance := v_fee_due - v_total_paid;

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment (%) exceeds outstanding balance (%)', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_TIMESTAMP));
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_log_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_log_payment_audit();

-- (a) Seed Data (3 students, 6 payments, student 3 has 0 payments)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU2026001', 'Alice Banda',  5000.00),
    ('STU2026002', 'Brian Zulu',   3200.00),
    ('STU2026003', 'Chanda Phiri', 4500.00);

CALL pr_receive_payment(1, 1500.00, '2026-11-23 08:30:00');
CALL pr_receive_payment(1, 1000.00, '2026-11-23 10:15:00');
CALL pr_receive_payment(1,  500.00, '2026-11-23 13:00:00');
CALL pr_receive_payment(2, 1200.00, '2026-11-23 09:45:00');
CALL pr_receive_payment(2,  800.00, '2026-11-23 11:20:00');
CALL pr_receive_payment(2, 1200.00, '2026-11-23 15:10:00'); -- fully settled

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0.00) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0;

SELECT * FROM v_fee_balances;

-- (f) Index & EXPLAIN
CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT payment_id, student_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on >= '2026-11-23 00:00:00'
  AND paid_on <  '2026-11-24 00:00:00';

-- (g) Refresh Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_payment_count INTEGER;
    v_total_amount  NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(amount), 0.00)
    INTO v_payment_count, v_total_amount
    FROM payments
    WHERE paid_on >= p_day::timestamp
      AND paid_on <  (p_day + 1)::timestamp;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_payment_count, v_total_amount)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(DATE '2026-11-23');
SELECT * FROM daily_collections;

