-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Student: Luumbi Malambo | Student No: 202408554
-- Run the whole file top to bottom (it is safe to re-run).

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- Seed medicines (sales are loaded later through pr_record_sale)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 5.00, 50),
    ('Amoxicillin 250mg', 12.50, 30),
    ('ORS Sachet',         3.00, 20);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC;
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date is required';
    END IF;

    -- lock the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
            p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- stock is deducted exactly once, here
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    END IF;
    RETURN NULL;   -- return value is ignored for AFTER row triggers
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_medicines_stock_audit();

-- (a) continued: six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3,  8, CURRENT_DATE - 1);
CALL pr_record_sale(1, 15, CURRENT_DATE - 1);
CALL pr_record_sale(2, 22, CURRENT_DATE - 1);   -- leaves 3 Amoxicillin (low stock)
CALL pr_record_sale(3,  4, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Tests for (b)/(c): errors are caught so the script keeps running
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;   -- 20.00
DO $$
BEGIN
    BEGIN PERFORM fn_sale_value(99, 1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_sale_value(1, 0);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_sale(1, 9999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
-- Invalid sale left everything unchanged:
SELECT * FROM medicines ORDER BY medicine_id;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(3, 5, CURRENT_DATE);     -- another sale
SELECT * FROM v_low_stock;                   -- queried after a sale

-- (f) Index ----------------------------------------------------------------
-- Equality on medicine_id first, then a range on sold_on: a composite B-tree
-- (medicine_id, sold_on) lets PostgreSQL jump to one medicine and scan only
-- the requested date range in order.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
-- Tables are tiny, so force the planner to show the index being usable:
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    -- upsert = replace, never add, so reruns cannot double count
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);     -- rerun: same result, no duplicates
SELECT * FROM daily_sales;

-- pg_cron: daily at 00:15 for the previous day
-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_sales_daily', '15 0 * * *',
        $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
