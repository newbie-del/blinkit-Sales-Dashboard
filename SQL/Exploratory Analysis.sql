/* ============================================================================
   BLINKIT SALES ANALYTICS  |  03 - EXPLORATORY DATA ANALYSIS
   ----------------------------------------------------------------------------
   Purpose : Establish the baseline KPI set - the numbers a category manager
             checks before asking any deeper question.
   Engine  : MySQL 8.0+
   Run     : mysql -u root -p blinkit_analytics < "SQL/Exploratory Analysis.sql"

   HOW TO READ THIS FILE
     Every query states WHY the metric exists and WHAT DECISION it drives.
     A KPI that nobody acts on is a vanity metric, so if a number below could
     not change somebody's behaviour it would not be here.

   GRAIN REMINDER
     One row = one product stocked at one outlet. So "orders" in this dataset
     means product-outlet sales records, not customer checkout baskets. This
     distinction is stated explicitly because calling a row an "order" without
     qualification is the single most common misreading of this dataset.
============================================================================ */

USE blinkit_analytics;


/* ============================================================================
   SECTION 1 - THE EXECUTIVE KPI BLOCK
   ============================================================================
   Business purpose: one row that answers "how is the business doing?".
   This is the query behind the KPI cards at the top of the Excel dashboard.

   Why each KPI is on the card strip:
     Total Revenue      The headline number; every target is set against it.
     Total Records      Volume. Revenue up + volume flat = price/mix driven.
     Avg Sales/Record   Basket value. The lever that separates a healthy
                        revenue rise from one bought with discounts.
     Median Sales       Reported next to the mean on purpose - the gap between
                        them is the skew, i.e. how dependent the topline is on
                        a handful of large baskets.
     Avg Rating         Customer satisfaction. Guards against the trap of
                        celebrating revenue while service quality slides.
     Product / Category
     / Outlet counts    Assortment breadth and footprint - the denominators
                        for every "per product" or "per store" calculation.
*/
SELECT
    ROUND(SUM(sales), 2)                            AS total_revenue_inr,
    COUNT(*)                                        AS total_sales_records,
    COUNT(DISTINCT item_identifier)                 AS distinct_products,
    COUNT(DISTINCT item_type)                       AS product_categories,
    COUNT(DISTINCT outlet_identifier)               AS outlets,
    COUNT(DISTINCT outlet_type)                     AS outlet_types,
    COUNT(DISTINCT outlet_location_type)            AS location_tiers,
    COUNT(DISTINCT outlet_size)                     AS outlet_size_bands,
    ROUND(AVG(sales), 2)                            AS avg_sales_per_record,
    ROUND(AVG(rating), 2)                           AS avg_rating,
    ROUND(AVG(item_weight), 2)                      AS avg_item_weight_kg,
    ROUND(AVG(item_visibility), 4)                  AS avg_item_visibility,
    MIN(order_date)                                 AS first_order_date,
    MAX(order_date)                                 AS last_order_date,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2) AS revenue_per_outlet
FROM blinkit_sales;


/* ----------------------------------------------------------------------------
   1.1 Median sales - the honesty check on the average
   ----------------------------------------------------------------------------
   Business purpose: AVG(sales) alone is misleading on a right-skewed
   distribution. If the mean sits well above the median, the topline leans on a
   thin tail of large baskets and a target built on the mean will be missed.
   MySQL has no MEDIAN(), so PERCENT_RANK() supplies it.
*/
SELECT
    ROUND(AVG(sales), 2)                                         AS mean_sales,
    ROUND(MAX(CASE WHEN pr <= 0.50 THEN sales END), 2)            AS median_sales,
    ROUND(AVG(sales) - MAX(CASE WHEN pr <= 0.50 THEN sales END), 2) AS mean_minus_median,
    ROUND(MAX(CASE WHEN pr <= 0.25 THEN sales END), 2)            AS p25,
    ROUND(MAX(CASE WHEN pr <= 0.75 THEN sales END), 2)            AS p75,
    ROUND(MAX(CASE WHEN pr <= 0.90 THEN sales END), 2)            AS p90
FROM (
    SELECT sales, PERCENT_RANK() OVER (ORDER BY sales) AS pr
    FROM blinkit_sales
) t;


/* ============================================================================
   SECTION 2 - DIMENSION INVENTORY
   ============================================================================
   Business purpose: know the shape of the data before slicing it. A category
   holding 2% of rows cannot support a confident recommendation, and knowing
   that up front prevents over-reading a small segment.
*/

-- 2.1 Product categories, ranked by revenue contribution
SELECT
    item_type                                                     AS category,
    COUNT(*)                                                      AS records,
    COUNT(DISTINCT item_identifier)                               AS products,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_type
ORDER BY revenue DESC;

-- 2.2 Outlet master - the store footprint in one view
-- Business purpose: the reference table for every store-level conversation.
SELECT
    outlet_identifier                                             AS outlet,
    outlet_type,
    outlet_size,
    outlet_location_type                                          AS tier,
    outlet_establishment_year                                     AS opened,
    outlet_age_years                                              AS age_years,
    COUNT(*)                                                      AS records,
    COUNT(DISTINCT item_type)                                     AS categories_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY outlet_identifier, outlet_type, outlet_size,
         outlet_location_type, outlet_establishment_year, outlet_age_years
ORDER BY revenue DESC;

-- 2.3 Store format performance
-- Business purpose: format strategy. Where should the next store be opened?
SELECT
    outlet_type,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY outlet_type
ORDER BY revenue DESC;
-- Note: revenue_per_store matters more than revenue here. A format with 4
-- stores will out-total a format with 1 while being the weaker format.

-- 2.4 Location tier
-- Business purpose: expansion strategy - metro vs smaller-city catchments.
SELECT
    outlet_location_type                                          AS tier,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store
FROM blinkit_sales
GROUP BY outlet_location_type
ORDER BY revenue DESC;

-- 2.5 Outlet size band
-- Business purpose: does floor space convert into sales? Drives the
-- store-format decision for new leases. 'Unknown' is retained deliberately -
-- hiding it would silently drop real revenue from the total.
SELECT
    outlet_size,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store
FROM blinkit_sales
GROUP BY outlet_size
ORDER BY revenue DESC;

-- 2.6 Fat content split
-- Business purpose: health-positioning of the assortment. Only trustworthy
-- because cleaning collapsed 7 raw spellings into 2 categories.
SELECT
    item_fat_content,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_fat_content
ORDER BY revenue DESC;


/* ============================================================================
   SECTION 3 - DISTRIBUTIONS
   ============================================================================
   Business purpose: averages hide the shape. These queries expose it.
*/

-- 3.1 Sales bands
-- Business purpose: pricing and assortment tiering. Shows how much of the
-- topline comes from premium baskets vs everyday value lines.
SELECT
    CASE
        WHEN sales <  500 THEN 'A. Under 500'
        WHEN sales < 1000 THEN 'B. 500 - 1K'
        WHEN sales < 2000 THEN 'C. 1K - 2K'
        WHEN sales < 3000 THEN 'D. 2K - 3K'
        WHEN sales < 5000 THEN 'E. 3K - 5K'
        WHEN sales < 8000 THEN 'F. 5K - 8K'
        ELSE                   'G. 8K+'
    END                                                           AS sales_band,
    COUNT(*)                                                      AS records,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)            AS pct_of_records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue
FROM blinkit_sales
GROUP BY sales_band
ORDER BY sales_band;

-- 3.2 Rating distribution
-- Business purpose: feeds the dashboard's rating histogram and flags the size
-- of the quality-risk tail (anything below 3.5 needs review).
SELECT
    CASE
        WHEN rating < 2.0 THEN '1.0 - 1.9  Critical'
        WHEN rating < 3.0 THEN '2.0 - 2.9  Poor'
        WHEN rating < 3.5 THEN '3.0 - 3.4  Below par'
        WHEN rating < 4.0 THEN '3.5 - 3.9  Acceptable'
        WHEN rating < 4.5 THEN '4.0 - 4.4  Good'
        ELSE                   '4.5 - 5.0  Excellent'
    END                                                           AS rating_band,
    COUNT(*)                                                      AS records,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)            AS pct_of_records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale
FROM blinkit_sales
GROUP BY rating_band
ORDER BY rating_band;

-- 3.3 Visibility deciles vs sales
-- Business purpose: THE merchandising question - does giving a product more
-- shelf share actually sell more? Deciles rather than a raw correlation so the
-- relationship can be read (and acted on) without statistical training.
SELECT
    visibility_decile,
    COUNT(*)                                                      AS records,
    ROUND(MIN(item_visibility), 4)                                AS min_visibility,
    ROUND(MAX(item_visibility), 4)                                AS max_visibility,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales), 2)                                          AS revenue
FROM (
    SELECT sales, item_visibility,
           NTILE(10) OVER (ORDER BY item_visibility) AS visibility_decile
    FROM blinkit_sales
) d
GROUP BY visibility_decile
ORDER BY visibility_decile;

-- 3.4 Data-quality footprint carried into analysis
-- Business purpose: state the assumptions on the record. Any figure derived
-- from an imputed column inherits its uncertainty, and the audience is
-- entitled to know how large that share is.
SELECT
    COUNT(*)                                                      AS total_rows,
    SUM(item_weight_imputed)                                      AS imputed_weights,
    ROUND(100.0 * SUM(item_weight_imputed) / COUNT(*), 2)         AS pct_imputed_weight,
    SUM(item_visibility_imputed)                                  AS imputed_visibility,
    ROUND(100.0 * SUM(item_visibility_imputed) / COUNT(*), 2)     AS pct_imputed_visibility,
    SUM(outlet_size = 'Unknown')                                  AS rows_unknown_size,
    ROUND(100.0 * SUM(outlet_size = 'Unknown') / COUNT(*), 2)     AS pct_unknown_size
FROM blinkit_sales;


/* ============================================================================
   SECTION 4 - TIME BASELINE
   ============================================================================
*/

-- 4.1 Monthly revenue
-- Business purpose: the trend line every review meeting opens with. Drives
-- inventory planning and staffing for the coming month.
SELECT
    order_year_month                                              AS year_month,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY order_year_month
ORDER BY order_year_month;

-- 4.2 Yearly summary
-- Business purpose: the growth headline for the annual review.
SELECT
    order_year                                                    AS year,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY order_year
ORDER BY order_year;

-- 4.3 Weekday vs weekend
-- Business purpose: rostering and delivery-fleet sizing. A weekend uplift
-- justifies shifting staff hours rather than adding headcount.
SELECT
    CASE WHEN is_weekend = 1 THEN 'Weekend' ELSE 'Weekday' END    AS day_type,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale
FROM blinkit_sales
GROUP BY day_type
ORDER BY revenue DESC;

/* Next step: SQL/Business Questions.sql */
