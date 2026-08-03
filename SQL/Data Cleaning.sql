/* ============================================================================
   BLINKIT SALES ANALYTICS  |  02 - DATA CLEANING
   ----------------------------------------------------------------------------
   Purpose : Load the raw CSV into staging, profile it in SQL, then build the
             clean analytics table.
   Engine  : MySQL 8.0+
   Run     : mysql -u root -p --local-infile=1 blinkit_analytics < "SQL/Data Cleaning.sql"

   GOLDEN RULE
     The raw CSV and stg_blinkit_raw are READ-ONLY. No UPDATE or DELETE ever
     touches them. Cleaning is a one-way INSERT ... SELECT into blinkit_sales,
     so the whole pipeline is re-runnable and every rule is visible in one
     place instead of buried in a chain of destructive UPDATEs.

   ISSUES HANDLED (evidence in Reports/data_quality_report.md)
     1. 7 spellings of Item Fat Content + stray whitespace
     2. 1,468 missing Item Weight (17.20%)
     3. 2,350 blank Outlet Size (27.53%) - 3 outlets never reported one
     4. 512 Item Visibility = 0.00 (6.00%) - impossible, means "not recorded"
     5. 14 exact duplicate rows
     6. 1,263 over-precise Ratings + 1 value above the 5.0 ceiling
     7. Every column typed as text
============================================================================ */

USE blinkit_analytics;

SET SESSION sql_mode = 'STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO';
-- STRICT mode on purpose: a silent truncation during cleaning is worse than a
-- loud failure. If a value will not fit its declared type, stop and look.


/* ============================================================================
   SECTION 1 - LOAD RAW CSV INTO STAGING
   ============================================================================
   NOTE ON LOCAL INFILE
     Server-side: SHOW VARIABLES LIKE 'secure_file_priv';  -- put CSV there, or
     Client-side: start mysql with --local-infile=1 and run
                  SET GLOBAL local_infile = 1;
     Adjust the path below to your machine.
*/

TRUNCATE TABLE stg_blinkit_raw;

LOAD DATA LOCAL INFILE 'D:/DA-projects/Blinkit-Sales-Analytics/Dataset/BlinkIT Grocery Data.csv'
INTO TABLE stg_blinkit_raw
FIELDS TERMINATED BY ','
       OPTIONALLY ENCLOSED BY '"'
LINES  TERMINATED BY '\n'
IGNORE 1 ROWS                      -- skip the header
(item_identifier, item_weight, item_fat_content, item_visibility, item_type,
 outlet_identifier, outlet_establishment_year, outlet_size, outlet_location_type,
 outlet_type, sales, rating, order_date);

-- Sanity check: expect 8,537 rows (8,523 real + 14 duplicated by the bad batch)
SELECT COUNT(*) AS rows_loaded FROM stg_blinkit_raw;


/* ============================================================================
   SECTION 2 - PROFILE THE RAW DATA IN SQL
   ============================================================================
   Business purpose: quantify every defect BEFORE changing anything, so the
   cleaning can be justified line by line and re-verified after the fact.
*/

-- 2.1 Missing / blank values per column ------------------------------------
SELECT
    COUNT(*)                                                           AS total_rows,
    SUM(item_weight   IS NULL OR TRIM(item_weight)   = '')             AS missing_weight,
    SUM(outlet_size   IS NULL OR TRIM(outlet_size)   = '')             AS missing_outlet_size,
    SUM(sales         IS NULL OR TRIM(sales)         = '')             AS missing_sales,
    SUM(rating        IS NULL OR TRIM(rating)        = '')             AS missing_rating,
    SUM(order_date    IS NULL OR TRIM(order_date)    = '')             AS missing_order_date,
    ROUND(100.0 * SUM(item_weight IS NULL OR TRIM(item_weight) = '')
          / COUNT(*), 2)                                               AS pct_missing_weight
FROM stg_blinkit_raw;

-- 2.2 The fat-content mess --------------------------------------------------
-- Shows why a raw GROUP BY is untrustworthy: 7 labels, 2 real categories.
SELECT
    CONCAT('"', item_fat_content, '"')      AS raw_value_quoted,  -- exposes spaces
    COUNT(*)                                AS row_count,
    CASE UPPER(TRIM(item_fat_content))
        WHEN 'LF'       THEN 'Low Fat'
        WHEN 'LOW FAT'  THEN 'Low Fat'
        WHEN 'REG'      THEN 'Regular'
        WHEN 'REGULAR'  THEN 'Regular'
        ELSE 'UNMAPPED - INVESTIGATE'
    END                                     AS maps_to
FROM stg_blinkit_raw
GROUP BY item_fat_content
ORDER BY row_count DESC;

-- 2.3 Impossible / out-of-range values --------------------------------------
SELECT
    SUM(CAST(item_visibility AS DECIMAL(9,6)) = 0)                     AS zero_visibility,
    SUM(CAST(item_visibility AS DECIMAL(9,6)) NOT BETWEEN 0 AND 1)     AS visibility_out_of_range,
    SUM(CAST(sales  AS DECIMAL(10,4)) <= 0)                            AS non_positive_sales,
    SUM(CAST(rating AS DECIMAL(4,3)) NOT BETWEEN 1 AND 5)              AS rating_out_of_range,
    SUM(CHAR_LENGTH(SUBSTRING_INDEX(rating, '.', -1)) > 1)             AS rating_over_precise,
    SUM(STR_TO_DATE(order_date, '%Y-%m-%d') IS NULL)                   AS unparseable_dates
FROM stg_blinkit_raw;

-- 2.4 Duplicates ------------------------------------------------------------
-- Two different questions: exact-copy rows, and grain violations.
SELECT
    (SELECT COUNT(*) FROM stg_blinkit_raw)                             AS total_rows,
    (SELECT COUNT(*) FROM (
        SELECT 1 FROM stg_blinkit_raw
        GROUP BY item_identifier, item_weight, item_fat_content, item_visibility,
                 item_type, outlet_identifier, outlet_establishment_year,
                 outlet_size, outlet_location_type, outlet_type, sales, rating,
                 order_date
        HAVING COUNT(*) > 1) d)                                        AS dup_groups,
    (SELECT COUNT(*) FROM (
        SELECT 1 FROM stg_blinkit_raw
        GROUP BY item_identifier, outlet_identifier
        HAVING COUNT(*) > 1) g)                                        AS grain_violations;

-- 2.5 Referential consistency ----------------------------------------------
-- Each outlet must have exactly ONE size, tier, type and establishment year.
-- If this returns rows, no store-level roll-up can be trusted.
SELECT
    outlet_identifier,
    COUNT(DISTINCT outlet_size)              AS distinct_sizes,
    COUNT(DISTINCT outlet_location_type)     AS distinct_tiers,
    COUNT(DISTINCT outlet_type)              AS distinct_types,
    COUNT(DISTINCT outlet_establishment_year) AS distinct_years
FROM stg_blinkit_raw
GROUP BY outlet_identifier
HAVING distinct_sizes > 1 OR distinct_tiers > 1
    OR distinct_types > 1 OR distinct_years > 1;

-- 2.6 Sales outliers via the IQR rule ---------------------------------------
-- Business purpose: decide whether extreme baskets are errors or real events.
WITH q AS (
    SELECT
        MAX(CASE WHEN pr <= 0.25 THEN s END) AS q1,
        MAX(CASE WHEN pr <= 0.50 THEN s END) AS median_s,
        MAX(CASE WHEN pr <= 0.75 THEN s END) AS q3
    FROM (
        SELECT CAST(sales AS DECIMAL(10,4)) AS s,
               PERCENT_RANK() OVER (ORDER BY CAST(sales AS DECIMAL(10,4))) AS pr
        FROM stg_blinkit_raw
    ) p
)
SELECT
    q1, median_s, q3,
    ROUND(q3 - q1, 2)                        AS iqr,
    ROUND(q3 + 1.5 * (q3 - q1), 2)           AS upper_fence,
    (SELECT COUNT(*) FROM stg_blinkit_raw
      WHERE CAST(sales AS DECIMAL(10,4)) > q.q3 + 1.5 * (q.q3 - q.q1)) AS rows_above_fence
FROM q;
-- Verdict: outliers are KEPT. A large festive basket at a Supermarket Type3 is
-- a real business event, not a typo. They are reported alongside the median so
-- the right-skew stays visible instead of being hidden by deletion.


/* ============================================================================
   SECTION 3 - BUILD THE CLEAN ANALYTICS TABLE
   ============================================================================
   One INSERT ... SELECT. Each CTE handles one concern, in order.
*/

TRUNCATE TABLE blinkit_sales;

INSERT INTO blinkit_sales (
    item_identifier, item_type, item_fat_content,
    item_weight, item_weight_imputed,
    item_visibility, item_visibility_imputed,
    outlet_identifier, outlet_establishment_year, outlet_age_years,
    outlet_size, outlet_location_type, outlet_type,
    sales, rating,
    order_date, order_year, order_month, order_month_name,
    order_quarter, order_year_month, order_weekday, is_weekend
)
WITH
-- ---------------------------------------------------------------------------
-- STEP 1: TRIM + CAST. Turn text into typed values and strip whitespace.
--         NULLIF converts blank strings to real NULLs so they are not cast
--         to a misleading 0.
-- ---------------------------------------------------------------------------
typed AS (
    SELECT
        TRIM(item_identifier)                                     AS item_identifier,
        TRIM(item_type)                                           AS item_type,

        -- STEP 2: CATEGORY STANDARDISATION. Collapse 7 spellings into 2.
        CASE UPPER(TRIM(item_fat_content))
            WHEN 'LF'      THEN 'Low Fat'
            WHEN 'LOW FAT' THEN 'Low Fat'
            WHEN 'REG'     THEN 'Regular'
            WHEN 'REGULAR' THEN 'Regular'
            ELSE NULL     -- anything unexpected fails loudly, never silently
        END                                                       AS item_fat_content,

        CAST(NULLIF(TRIM(item_weight), '') AS DECIMAL(6,3))       AS item_weight,

        -- STEP 3: ZERO-AS-NULL. 0.00 shelf share is impossible for a stocked
        -- product, so treat it as missing rather than as a real measurement.
        NULLIF(CAST(NULLIF(TRIM(item_visibility), '') AS DECIMAL(9,6)), 0)
                                                                  AS item_visibility,

        TRIM(outlet_identifier)                                   AS outlet_identifier,
        CAST(TRIM(outlet_establishment_year) AS UNSIGNED)         AS outlet_establishment_year,

        -- STEP 4: MISSING CATEGORY -> explicit 'Unknown' band, never a guess.
        COALESCE(NULLIF(TRIM(outlet_size), ''), 'Unknown')        AS outlet_size,

        TRIM(outlet_location_type)                                AS outlet_location_type,
        TRIM(outlet_type)                                         AS outlet_type,
        CAST(TRIM(sales) AS DECIMAL(10,4))                        AS sales,

        -- STEP 5: PRECISION + RANGE. Ratings are collected on a 1-decimal
        -- scale; LEAST/GREATEST clamps the one value that broke the ceiling.
        LEAST(5.00, GREATEST(1.00,
              ROUND(CAST(TRIM(rating) AS DECIMAL(4,3)), 1)))      AS rating,

        -- STEP 6: DATE PARSING. Explicit format, never rely on implicit casts.
        STR_TO_DATE(TRIM(order_date), '%Y-%m-%d')                 AS order_date
    FROM stg_blinkit_raw
),

-- ---------------------------------------------------------------------------
-- STEP 7: DEDUPLICATION. Number the identical copies and keep exactly one.
--         Partitioning on every column means only true duplicates collapse -
--         a legitimate row that merely shares an item or outlet is untouched.
-- ---------------------------------------------------------------------------
deduped AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY item_identifier, item_type, item_fat_content,
                            item_weight, item_visibility, outlet_identifier,
                            outlet_establishment_year, outlet_size,
                            outlet_location_type, outlet_type, sales, rating,
                            order_date
               ORDER BY item_identifier
           ) AS rn
    FROM typed
),
unique_rows AS (
    SELECT * FROM deduped WHERE rn = 1
),

-- ---------------------------------------------------------------------------
-- STEP 8: IMPUTATION LOOKUPS.
--         MySQL has no MEDIAN(), so it is built with window functions.
--         Median over mean because both distributions are skewed - a mean
--         would be dragged by the tail and systematically over-fill.
-- ---------------------------------------------------------------------------
-- 8a. Median weight per ITEM (weight is a property of the product, so the
--     item's own other rows are the most accurate source).
weight_by_item AS (
    SELECT item_identifier, AVG(item_weight) AS median_weight
    FROM (
        SELECT item_identifier, item_weight,
               ROW_NUMBER() OVER (PARTITION BY item_identifier ORDER BY item_weight) AS rn,
               COUNT(*)     OVER (PARTITION BY item_identifier)                      AS cnt
        FROM unique_rows
        WHERE item_weight IS NOT NULL
    ) r
    WHERE rn IN (FLOOR((cnt + 1) / 2), CEILING((cnt + 1) / 2))
    GROUP BY item_identifier
),
-- 8b. Fallback: median weight per ITEM TYPE, for SKUs never weighed at all.
weight_by_type AS (
    SELECT item_type, AVG(item_weight) AS median_weight
    FROM (
        SELECT item_type, item_weight,
               ROW_NUMBER() OVER (PARTITION BY item_type ORDER BY item_weight) AS rn,
               COUNT(*)     OVER (PARTITION BY item_type)                      AS cnt
        FROM unique_rows
        WHERE item_weight IS NOT NULL
    ) r
    WHERE rn IN (FLOOR((cnt + 1) / 2), CEILING((cnt + 1) / 2))
    GROUP BY item_type
),
-- 8c. Median visibility per ITEM TYPE, to replace the 0.00 sentinels.
visibility_by_type AS (
    SELECT item_type, AVG(item_visibility) AS median_visibility
    FROM (
        SELECT item_type, item_visibility,
               ROW_NUMBER() OVER (PARTITION BY item_type ORDER BY item_visibility) AS rn,
               COUNT(*)     OVER (PARTITION BY item_type)                          AS cnt
        FROM unique_rows
        WHERE item_visibility IS NOT NULL
    ) r
    WHERE rn IN (FLOOR((cnt + 1) / 2), CEILING((cnt + 1) / 2))
    GROUP BY item_type
)

-- ---------------------------------------------------------------------------
-- STEP 9: FINAL SELECT - apply imputations, flag them, derive date parts.
-- ---------------------------------------------------------------------------
SELECT
    u.item_identifier,
    u.item_type,
    u.item_fat_content,

    ROUND(COALESCE(u.item_weight, wi.median_weight, wt.median_weight), 3) AS item_weight,
    (u.item_weight IS NULL)                                   AS item_weight_imputed,

    ROUND(COALESCE(u.item_visibility, vt.median_visibility), 6) AS item_visibility,
    (u.item_visibility IS NULL)                               AS item_visibility_imputed,

    u.outlet_identifier,
    u.outlet_establishment_year,
    (2024 - u.outlet_establishment_year)                      AS outlet_age_years,
    u.outlet_size,
    u.outlet_location_type,
    u.outlet_type,

    u.sales,
    u.rating,

    u.order_date,
    YEAR(u.order_date)                                        AS order_year,
    MONTH(u.order_date)                                       AS order_month,
    DATE_FORMAT(u.order_date, '%b')                           AS order_month_name,
    QUARTER(u.order_date)                                     AS order_quarter,
    DATE_FORMAT(u.order_date, '%Y-%m')                        AS order_year_month,
    DATE_FORMAT(u.order_date, '%a')                           AS order_weekday,
    (DAYOFWEEK(u.order_date) IN (1, 7))                       AS is_weekend
FROM unique_rows u
LEFT JOIN weight_by_item     wi ON wi.item_identifier = u.item_identifier
LEFT JOIN weight_by_type     wt ON wt.item_type       = u.item_type
LEFT JOIN visibility_by_type vt ON vt.item_type       = u.item_type;


/* ============================================================================
   SECTION 4 - POST-CLEANING VALIDATION
   ============================================================================
   Cleaning is not finished until it is proven. Every check below must pass;
   if one fails the pipeline is wrong and the dashboard must not be published.
*/

-- 4.1 Row reconciliation: raw - duplicates = clean
SELECT
    (SELECT COUNT(*) FROM stg_blinkit_raw)                     AS raw_rows,
    (SELECT COUNT(*) FROM blinkit_sales)                       AS clean_rows,
    (SELECT COUNT(*) FROM stg_blinkit_raw)
      - (SELECT COUNT(*) FROM blinkit_sales)                   AS rows_removed;

-- 4.2 Revenue reconciliation: the ONLY revenue that should disappear is the
--     revenue that was double-counted by the duplicate rows.
SELECT
    ROUND((SELECT SUM(CAST(sales AS DECIMAL(10,4))) FROM stg_blinkit_raw), 2) AS raw_revenue,
    ROUND((SELECT SUM(sales) FROM blinkit_sales), 2)                          AS clean_revenue,
    ROUND((SELECT SUM(CAST(sales AS DECIMAL(10,4))) FROM stg_blinkit_raw)
        - (SELECT SUM(sales) FROM blinkit_sales), 2)                          AS revenue_removed;

-- 4.3 Every defect must now be zero
SELECT
    SUM(item_weight IS NULL)                              AS null_weights,
    SUM(item_visibility = 0)                              AS zero_visibility,
    SUM(item_visibility NOT BETWEEN 0 AND 1)              AS bad_visibility,
    SUM(sales <= 0)                                       AS bad_sales,
    SUM(rating NOT BETWEEN 1 AND 5)                       AS bad_rating,
    COUNT(DISTINCT item_fat_content)                      AS fat_categories,   -- must be 2
    COUNT(DISTINCT outlet_size)                           AS size_categories,  -- 4 incl. Unknown
    COUNT(*) - COUNT(DISTINCT CONCAT(item_identifier, outlet_identifier))
                                                          AS grain_violations  -- must be 0
FROM blinkit_sales;

-- 4.4 Imputation transparency: how much of the table was filled, not measured?
SELECT
    COUNT(*)                                                          AS total_rows,
    SUM(item_weight_imputed)                                          AS weights_imputed,
    ROUND(100.0 * SUM(item_weight_imputed) / COUNT(*), 2)             AS pct_weight_imputed,
    SUM(item_visibility_imputed)                                      AS visibility_imputed,
    ROUND(100.0 * SUM(item_visibility_imputed) / COUNT(*), 2)         AS pct_visibility_imputed
FROM blinkit_sales;
-- Managers are told these percentages up front. An imputed field is a
-- modelling assumption, and assumptions belong in the open.

-- 4.5 Confirm the fat-content collapse worked
SELECT item_fat_content, COUNT(*) AS rows, ROUND(SUM(sales), 2) AS revenue
FROM blinkit_sales
GROUP BY item_fat_content;

/* Next step: SQL/Exploratory Analysis.sql */
