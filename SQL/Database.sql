/* ============================================================================
   BLINKIT SALES ANALYTICS  |  01 - DATABASE & SCHEMA
   ----------------------------------------------------------------------------
   Purpose : Create the database and the staging + analytics tables.
   Engine  : MySQL 8.0+
   Author  : Data Analytics Portfolio Project
   Run     : mysql -u root -p < "SQL/Database.sql"

   DESIGN NOTE - why two tables?
     stg_blinkit_raw   Landing zone. Mirrors the CSV exactly, every column
                       permissive (VARCHAR / NULL-able) so a dirty file can
                       never fail the load. NEVER updated after load.
     blinkit_sales     Analytics table. Correct data types, constraints and
                       indexes. Built from staging by "Data Cleaning.sql".

   Loading dirty data straight into a typed table is the classic mistake: MySQL
   silently coerces "Low Fat " and blank weights, and the failure is discovered
   weeks later in a dashboard total. Staging makes the load bulletproof and
   every transformation auditable + re-runnable.
============================================================================ */

-- ---------------------------------------------------------------------------
-- 1. Database
-- ---------------------------------------------------------------------------
DROP DATABASE IF EXISTS blinkit_analytics;

CREATE DATABASE blinkit_analytics
    DEFAULT CHARACTER SET utf8mb4          -- full Unicode (product names, ₹)
    DEFAULT COLLATE utf8mb4_0900_ai_ci;    -- case-insensitive compares

USE blinkit_analytics;


-- ---------------------------------------------------------------------------
-- 2. Staging table - permissive by design
-- ---------------------------------------------------------------------------
-- Every column is text and NULL-able. "Item Weight" arrives blank on ~17% of
-- rows and "Item Visibility" carries 0.00 sentinels; if these were declared
-- DECIMAL NOT NULL the import would abort or silently zero-fill.
DROP TABLE IF EXISTS stg_blinkit_raw;

CREATE TABLE stg_blinkit_raw (
    item_identifier             VARCHAR(20),
    item_weight                 VARCHAR(20),   -- text: blanks allowed
    item_fat_content            VARCHAR(30),   -- text: 7 raw spellings
    item_visibility             VARCHAR(30),
    item_type                   VARCHAR(60),
    outlet_identifier           VARCHAR(20),
    outlet_establishment_year   VARCHAR(10),
    outlet_size                 VARCHAR(30),   -- text: blanks allowed
    outlet_location_type        VARCHAR(30),
    outlet_type                 VARCHAR(40),
    sales                       VARCHAR(30),
    rating                      VARCHAR(30),
    order_date                  VARCHAR(30)
) ENGINE = InnoDB
  COMMENT = 'Raw landing zone - mirrors CSV exactly. Never updated.';


-- ---------------------------------------------------------------------------
-- 3. Analytics table - typed, constrained, indexed
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS blinkit_sales;

CREATE TABLE blinkit_sales (
    -- Surrogate PK. The natural key (item + outlet) is enforced separately as
    -- a UNIQUE constraint; a surrogate id keeps joins and row references cheap.
    sale_id                     INT UNSIGNED NOT NULL AUTO_INCREMENT,

    -- ---- Product dimension ------------------------------------------------
    item_identifier             VARCHAR(10)    NOT NULL,
    item_type                   VARCHAR(40)    NOT NULL,
    item_fat_content            ENUM('Low Fat','Regular') NOT NULL,
        -- ENUM is deliberate: it makes the 7-spellings bug structurally
        -- impossible to reintroduce. A bad INSERT now errors instead of
        -- quietly creating a 3rd bucket.
    item_weight                 DECIMAL(6,3)   NULL,
    item_weight_imputed         TINYINT(1)     NOT NULL DEFAULT 0,
        -- Audit flag. Managers must be able to tell a measured weight from a
        -- filled one; without this the imputation is invisible.
    item_visibility             DECIMAL(9,6)   NOT NULL,
    item_visibility_imputed     TINYINT(1)     NOT NULL DEFAULT 0,

    -- ---- Outlet dimension -------------------------------------------------
    outlet_identifier           CHAR(6)        NOT NULL,
    outlet_establishment_year   SMALLINT UNSIGNED NOT NULL,
    outlet_age_years            SMALLINT UNSIGNED NOT NULL,
        -- Pre-computed so trend queries never hardcode "2024 - year".
    outlet_size                 ENUM('Small','Medium','High','Unknown') NOT NULL,
        -- 'Unknown' is a first-class band, not a NULL: 3 outlets never
        -- reported a size and they still generate real revenue.
    outlet_location_type        ENUM('Tier 1','Tier 2','Tier 3') NOT NULL,
    outlet_type                 ENUM('Grocery Store','Supermarket Type1',
                                     'Supermarket Type2','Supermarket Type3') NOT NULL,

    -- ---- Measures ---------------------------------------------------------
    sales                       DECIMAL(10,4)  NOT NULL,
        -- DECIMAL not FLOAT. Money must never be stored as binary floating
        -- point: FLOAT sums drift by paise and the dashboard stops tying out.
    rating                      DECIMAL(3,2)   NOT NULL,

    -- ---- Time dimension ---------------------------------------------------
    order_date                  DATE           NOT NULL,
    order_year                  SMALLINT UNSIGNED NOT NULL,
    order_month                 TINYINT UNSIGNED  NOT NULL,
    order_month_name            VARCHAR(3)     NOT NULL,
    order_quarter               TINYINT UNSIGNED  NOT NULL,
    order_year_month            CHAR(7)        NOT NULL,   -- 'YYYY-MM' sorts correctly
    order_weekday               VARCHAR(3)     NOT NULL,
    is_weekend                  TINYINT(1)     NOT NULL,
        -- Denormalised date parts. This is a read-only analytics table, so
        -- trading a little storage for sargable GROUP BYs is the right call -
        -- GROUP BY MONTH(order_date) cannot use an index, GROUP BY
        -- order_year_month can.

    PRIMARY KEY (sale_id),

    -- Business grain: one row per product per outlet. This constraint is what
    -- makes the duplicate-row defect impossible to reload.
    UNIQUE KEY uq_item_outlet (item_identifier, outlet_identifier),

    -- ---- Data-integrity guards (MySQL 8.0.16+ enforces CHECK) -------------
    CONSTRAINT chk_sales_positive   CHECK (sales > 0),
    CONSTRAINT chk_rating_range     CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT chk_visibility_range CHECK (item_visibility >= 0 AND item_visibility <= 1),
    CONSTRAINT chk_weight_positive  CHECK (item_weight IS NULL OR item_weight > 0),
    CONSTRAINT chk_month_range      CHECK (order_month BETWEEN 1 AND 12)
) ENGINE = InnoDB
  COMMENT = 'Cleaned, analysis-ready fact table. One row per item per outlet.';


-- ---------------------------------------------------------------------------
-- 4. Indexes
-- ---------------------------------------------------------------------------
-- Chosen from the actual query patterns in Business Questions.sql, not
-- sprinkled at random. Every index costs write time and storage, so each one
-- below earns its place by serving a named group of queries.

-- Category roll-ups: "revenue by Item Type" (Q1-Q12). Covering index - the
-- INCLUDE-style trailing column lets MySQL answer SUM(sales) from the index
-- alone without touching the table.
CREATE INDEX idx_item_type_sales      ON blinkit_sales (item_type, sales);

-- Store league tables and outlet drill-downs (Q13-Q22).
CREATE INDEX idx_outlet_sales         ON blinkit_sales (outlet_identifier, sales);

-- Segment slicing by store format / catchment tier (Q13-Q18).
CREATE INDEX idx_outlet_type          ON blinkit_sales (outlet_type, sales);
CREATE INDEX idx_location_tier        ON blinkit_sales (outlet_location_type, sales);
CREATE INDEX idx_outlet_size          ON blinkit_sales (outlet_size, sales);

-- Time series: monthly trend, YoY, running totals, moving averages (Q26-Q31).
CREATE INDEX idx_order_year_month     ON blinkit_sales (order_year_month, sales);
CREATE INDEX idx_order_date           ON blinkit_sales (order_date);

-- Product league tables + rating analysis (Q1-Q4, Q23-Q25).
CREATE INDEX idx_item_identifier      ON blinkit_sales (item_identifier);
CREATE INDEX idx_rating               ON blinkit_sales (rating);

-- Composite for the visibility-vs-sales study (Q19-Q20) and fat-content
-- cross-tabs (Q17). Column order matters: equality/low-cardinality first.
CREATE INDEX idx_fat_type             ON blinkit_sales (item_fat_content, item_type);
CREATE INDEX idx_visibility           ON blinkit_sales (item_visibility, sales);


-- ---------------------------------------------------------------------------
-- 5. Verify
-- ---------------------------------------------------------------------------
SHOW TABLES;
SELECT
    TABLE_NAME,
    ENGINE,
    TABLE_COMMENT
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'blinkit_analytics';

/* Next step: SQL/Data Cleaning.sql  (loads the CSV and builds blinkit_sales) */
