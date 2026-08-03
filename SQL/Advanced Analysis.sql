/* ============================================================================
   BLINKIT SALES ANALYTICS  |  05 - ADVANCED ANALYSIS
   ----------------------------------------------------------------------------
   Purpose : Advanced SQL patterns applied to real decisions, plus the reusable
             views that feed the Excel dashboard.
   Engine  : MySQL 8.0+
   Run     : mysql -u root -p blinkit_analytics < "SQL/Advanced Analysis.sql"

   TECHNIQUES DEMONSTRATED
     CASE WHEN ................ A1, A2, A9
     CTE (single + multiple) .. A1, A3, A4, A6, A8
     Recursive CTE ............ A11 (gap-free month spine)
     ROW_NUMBER() ............. A3, A5
     RANK() / DENSE_RANK() .... A3
     LAG() / LEAD() ........... A6
     Running total ............ A4
     Moving average ........... A6
     NTILE() quartiles ........ A2
     FIRST_VALUE / LAST_VALUE . A5
     PERCENT_RANK / CUME_DIST . A2
     Subquery in SELECT/FROM .. A7
     Correlated subquery ...... A8
     EXISTS / NOT EXISTS ...... A10
     Self-join ................ A9
     Views .................... A12
     Stored procedure ......... A13
     Query tuning / EXPLAIN ... A14

   These are not technique demos for their own sake. Each one is here because
   it is the clearest way to answer the business question above it.
============================================================================ */

USE blinkit_analytics;


/* ============================================================================
   A1. CUSTOMER-VALUE SEGMENTATION OF THE ASSORTMENT
   ----------------------------------------------------------------------------
   Business question: which products deserve investment, which deserve
   attention, and which should be dropped?
   Why it matters: a category manager cannot act on a flat list of 1,500 SKUs.
   Segmenting into named groups turns data into an owner and a deadline.
   Technique: multi-CTE + CASE WHEN on two dimensions at once.
============================================================================ */
WITH product_stats AS (
    SELECT
        item_identifier,
        item_type,
        SUM(sales)          AS revenue,
        AVG(sales)          AS avg_sale,
        AVG(rating)         AS avg_rating,
        AVG(item_visibility) AS avg_visibility,
        COUNT(*)            AS outlets_stocked
    FROM blinkit_sales
    GROUP BY item_identifier, item_type
),
benchmarks AS (
    SELECT
        AVG(revenue)    AS avg_revenue,
        AVG(avg_rating) AS avg_rating_all
    FROM product_stats
)
SELECT
    segment,
    COUNT(*)                                                  AS products,
    ROUND(SUM(revenue), 2)                                    AS revenue,
    ROUND(100.0 * SUM(revenue) / SUM(SUM(revenue)) OVER (), 2) AS pct_of_revenue,
    ROUND(AVG(avg_rating), 2)                                 AS avg_rating,
    recommended_action
FROM (
    SELECT
        p.*,
        CASE
            WHEN p.revenue >= b.avg_revenue AND p.avg_rating >= b.avg_rating_all
                 THEN '1. Star (high revenue, high rating)'
            WHEN p.revenue >= b.avg_revenue AND p.avg_rating <  b.avg_rating_all
                 THEN '2. Fix quality (high revenue, low rating)'
            WHEN p.revenue <  b.avg_revenue AND p.avg_rating >= b.avg_rating_all
                 THEN '3. Promote (low revenue, high rating)'
            ELSE      '4. Delist candidate (low revenue, low rating)'
        END AS segment,
        CASE
            WHEN p.revenue >= b.avg_revenue AND p.avg_rating >= b.avg_rating_all
                 THEN 'Protect stock. Never allow a stock-out.'
            WHEN p.revenue >= b.avg_revenue AND p.avg_rating <  b.avg_rating_all
                 THEN 'Supplier review. Volume is amplifying a quality problem.'
            WHEN p.revenue <  b.avg_revenue AND p.avg_rating >= b.avg_rating_all
                 THEN 'Raise visibility. Customers like it but cannot find it.'
            ELSE      'Free the shelf space for an A-item.'
        END AS recommended_action
    FROM product_stats p
    CROSS JOIN benchmarks b
) seg
GROUP BY segment, recommended_action
ORDER BY segment;


/* ============================================================================
   A2. OUTLET SCORECARD WITH QUARTILES AND PERCENTILES
   ----------------------------------------------------------------------------
   Business question: how does each store rank on revenue, basket and rating
   simultaneously?
   Why it matters: a store can lead on revenue while trailing on satisfaction.
   A single ranking hides that; a composite scorecard exposes it and stops the
   biggest store from being assumed to be the best-run store.
   Technique: NTILE(4), PERCENT_RANK(), CUME_DIST(), CASE WHEN.
============================================================================ */
WITH outlet_metrics AS (
    SELECT
        outlet_identifier,
        outlet_type,
        outlet_size,
        outlet_location_type,
        SUM(sales)  AS revenue,
        AVG(sales)  AS avg_sale,
        AVG(rating) AS avg_rating,
        COUNT(*)    AS records
    FROM blinkit_sales
    GROUP BY outlet_identifier, outlet_type, outlet_size, outlet_location_type
)
SELECT
    outlet_identifier                                         AS outlet,
    outlet_type,
    outlet_location_type                                      AS tier,
    ROUND(revenue, 2)                                         AS revenue,
    NTILE(4)       OVER (ORDER BY revenue DESC)               AS revenue_quartile,
    ROUND(100.0 * PERCENT_RANK() OVER (ORDER BY revenue), 1)  AS revenue_percentile,
    ROUND(100.0 * CUME_DIST()    OVER (ORDER BY revenue), 1)  AS cumulative_dist,
    ROUND(avg_sale, 2)                                        AS avg_sale,
    RANK()         OVER (ORDER BY avg_sale DESC)              AS basket_rank,
    ROUND(avg_rating, 2)                                      AS avg_rating,
    RANK()         OVER (ORDER BY avg_rating DESC)            AS rating_rank,
    -- Composite verdict: strong stores lead on more than one axis.
    CASE
        WHEN RANK() OVER (ORDER BY revenue   DESC) <= 3
         AND RANK() OVER (ORDER BY avg_rating DESC) <= 5
             THEN 'Benchmark store - replicate'
        WHEN RANK() OVER (ORDER BY revenue   DESC) <= 3
             THEN 'High revenue, weak satisfaction - audit service'
        WHEN RANK() OVER (ORDER BY avg_rating DESC) <= 3
             THEN 'Loved but small - growth headroom'
        ELSE 'Standard performer'
    END                                                       AS verdict
FROM outlet_metrics
ORDER BY revenue DESC;


/* ============================================================================
   A3. THREE RANKING FUNCTIONS SIDE BY SIDE
   ----------------------------------------------------------------------------
   Business question: what is the definitive top-3 per category?
   Why it matters: with ties, ROW_NUMBER picks an arbitrary winner, RANK skips
   numbers and DENSE_RANK does not. Using the wrong one silently changes a
   "top 3" list - and that list drives real promotion budget.
============================================================================ */
WITH category_products AS (
    SELECT item_type, item_identifier, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY item_type, item_identifier
),
ranked AS (
    SELECT
        item_type,
        item_identifier,
        revenue,
        ROW_NUMBER() OVER (PARTITION BY item_type ORDER BY revenue DESC) AS rn,
        RANK()       OVER (PARTITION BY item_type ORDER BY revenue DESC) AS rnk,
        DENSE_RANK() OVER (PARTITION BY item_type ORDER BY revenue DESC) AS dr,
        ROUND(100.0 * revenue
              / SUM(revenue) OVER (PARTITION BY item_type), 2)           AS pct_of_category
    FROM category_products
)
SELECT
    item_type        AS category,
    item_identifier  AS product,
    ROUND(revenue, 2) AS revenue,
    pct_of_category,
    rn               AS row_number,
    rnk              AS rank_with_gaps,
    dr               AS dense_rank
FROM ranked
WHERE rn <= 3
ORDER BY category, rn;


/* ============================================================================
   A4. RUNNING TOTALS AND CONTRIBUTION CURVES
   ----------------------------------------------------------------------------
   Business question: how many categories must we protect to cover 80% of
   revenue?
   Why it matters: it converts a vague "focus on the big ones" into a specific
   protected list with a number attached.
   Technique: SUM() OVER with an explicit window frame.
============================================================================ */
WITH category_revenue AS (
    SELECT item_type, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY item_type
),
cumulative AS (
    SELECT
        item_type,
        revenue,
        ROW_NUMBER() OVER (ORDER BY revenue DESC)                            AS rank_no,
        SUM(revenue) OVER (ORDER BY revenue DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total,
        SUM(revenue) OVER ()                                                 AS grand_total
    FROM category_revenue
)
SELECT
    rank_no,
    item_type                                                 AS category,
    ROUND(revenue, 2)                                         AS revenue,
    ROUND(100.0 * revenue / grand_total, 2)                   AS pct_of_total,
    ROUND(running_total, 2)                                   AS running_total,
    ROUND(100.0 * running_total / grand_total, 2)             AS cumulative_pct,
    CASE
        WHEN 100.0 * running_total / grand_total <= 80 THEN 'Core - protect'
        WHEN 100.0 * running_total / grand_total <= 95 THEN 'Secondary - maintain'
        ELSE                                               'Tail - review'
    END                                                       AS tier
FROM cumulative
ORDER BY rank_no;


/* ============================================================================
   A5. FIRST_VALUE / LAST_VALUE - BEST AND WORST WITHIN EACH GROUP
   ----------------------------------------------------------------------------
   Business question: in each store, what is the strongest and weakest
   category, and how wide is the spread?
   Why it matters: a wide internal spread means the store is over-reliant on
   one category - a concentration risk if that supplier fails.
============================================================================ */
WITH store_category AS (
    SELECT outlet_identifier, item_type, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY outlet_identifier, item_type
),
extremes AS (
    SELECT DISTINCT
        outlet_identifier,
        FIRST_VALUE(item_type) OVER w                        AS top_category,
        FIRST_VALUE(revenue)   OVER w                        AS top_revenue,
        LAST_VALUE(item_type)  OVER w                        AS bottom_category,
        LAST_VALUE(revenue)    OVER w                        AS bottom_revenue,
        SUM(revenue)           OVER (PARTITION BY outlet_identifier) AS store_revenue
    FROM store_category
    WINDOW w AS (PARTITION BY outlet_identifier ORDER BY revenue DESC
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
    -- The explicit frame is essential. LAST_VALUE with the default frame
    -- (UNBOUNDED PRECEDING TO CURRENT ROW) returns the current row, not the
    -- group's last row - one of the most common window-function bugs.
)
SELECT
    outlet_identifier                                         AS outlet,
    top_category,
    ROUND(top_revenue, 2)                                     AS top_revenue,
    ROUND(100.0 * top_revenue / store_revenue, 1)             AS top_pct_of_store,
    bottom_category,
    ROUND(bottom_revenue, 2)                                  AS bottom_revenue,
    ROUND(top_revenue / NULLIF(bottom_revenue, 0), 1)         AS spread_ratio,
    CASE
        WHEN 100.0 * top_revenue / store_revenue > 15
             THEN 'Concentration risk - one category carries the store'
        ELSE 'Balanced mix'
    END                                                       AS risk_flag
FROM extremes
ORDER BY top_pct_of_store DESC;


/* ============================================================================
   A6. LAG, LEAD AND MOVING AVERAGE ON ONE TIMELINE
   ----------------------------------------------------------------------------
   Business question: what happened last month, what is coming next, and what
   is the underlying trend?
   Why it matters: LAG explains the past, LEAD validates a forecast against
   what actually followed, and the moving average strips out festive noise.
============================================================================ */
WITH monthly AS (
    SELECT order_year_month AS ym, SUM(sales) AS revenue, COUNT(*) AS records
    FROM blinkit_sales
    GROUP BY order_year_month
)
SELECT
    ym                                                        AS year_month,
    ROUND(revenue, 2)                                         AS revenue,

    -- Backward look
    ROUND(LAG(revenue, 1) OVER o, 2)                          AS prev_month,
    ROUND(100.0 * (revenue - LAG(revenue, 1) OVER o)
          / NULLIF(LAG(revenue, 1) OVER o, 0), 1)             AS mom_pct,

    -- Forward look
    ROUND(LEAD(revenue, 1) OVER o, 2)                         AS next_month,
    ROUND(100.0 * (LEAD(revenue, 1) OVER o - revenue)
          / NULLIF(revenue, 0), 1)                            AS next_month_pct,

    -- Trend, noise removed
    ROUND(AVG(revenue) OVER (ORDER BY ym ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                              AS moving_avg_3m,
    ROUND(AVG(revenue) OVER (ORDER BY ym ROWS BETWEEN 5 PRECEDING AND CURRENT ROW), 2)
                                                              AS moving_avg_6m,

    -- Centred average - smoother, but only valid for closed periods since it
    -- borrows from the future.
    ROUND(AVG(revenue) OVER (ORDER BY ym ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING), 2)
                                                              AS centred_avg_3m,

    CASE
        WHEN revenue > AVG(revenue) OVER (ORDER BY ym ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
             THEN 'Above trend'
        ELSE 'Below trend'
    END                                                       AS trend_position
FROM monthly
WINDOW o AS (ORDER BY ym)
ORDER BY ym;


/* ============================================================================
   A7. SUBQUERIES IN SELECT AND FROM
   ----------------------------------------------------------------------------
   Business question: how does every category compare with the network average
   on revenue, basket and rating at once?
   Why it matters: "Dairy averages 2,230" means nothing alone. "Dairy is 8%
   above the network average" is a decision.
============================================================================ */
SELECT
    c.item_type                                               AS category,
    ROUND(c.revenue, 2)                                       AS revenue,
    ROUND(c.avg_sale, 2)                                      AS avg_sale,

    -- Scalar subquery in SELECT: the benchmark, repeated per row.
    (SELECT ROUND(AVG(sales), 2) FROM blinkit_sales)          AS network_avg_sale,
    ROUND(c.avg_sale - (SELECT AVG(sales) FROM blinkit_sales), 2) AS vs_network,
    ROUND(100.0 * (c.avg_sale - (SELECT AVG(sales) FROM blinkit_sales))
          / (SELECT AVG(sales) FROM blinkit_sales), 1)        AS pct_vs_network,

    ROUND(c.avg_rating, 2)                                    AS avg_rating,
    (SELECT ROUND(AVG(rating), 2) FROM blinkit_sales)         AS network_avg_rating,

    CASE
        WHEN c.avg_sale   > (SELECT AVG(sales)  FROM blinkit_sales)
         AND c.avg_rating > (SELECT AVG(rating) FROM blinkit_sales)
             THEN 'Outperforms on both'
        WHEN c.avg_sale   > (SELECT AVG(sales)  FROM blinkit_sales)
             THEN 'Commercially strong, satisfaction lags'
        WHEN c.avg_rating > (SELECT AVG(rating) FROM blinkit_sales)
             THEN 'Well liked, commercially weak'
        ELSE 'Underperforms on both'
    END                                                       AS assessment
FROM (
    -- Derived table (subquery in FROM)
    SELECT item_type, SUM(sales) AS revenue, AVG(sales) AS avg_sale,
           AVG(rating) AS avg_rating
    FROM blinkit_sales
    GROUP BY item_type
) c
ORDER BY c.revenue DESC;


/* ============================================================================
   A8. CORRELATED SUBQUERY - PRODUCTS BEATING THEIR OWN CATEGORY
   ----------------------------------------------------------------------------
   Business question: which products outperform their peer group?
   Why it matters: comparing Seafood to Snack Foods is unfair - different price
   points entirely. The honest benchmark is the product's own category, and a
   correlated subquery recomputes that benchmark per row.
   Performance note: correlated subqueries re-execute per outer row. Fine at
   this scale; at millions of rows the window-function version in A5 is the
   right pattern.
============================================================================ */
SELECT
    p.item_identifier                                         AS product,
    p.item_type                                               AS category,
    ROUND(p.revenue, 2)                                       AS product_revenue,

    -- Correlated: references p.item_type from the outer query.
    ROUND((SELECT AVG(inner_p.revenue)
           FROM (SELECT item_identifier, item_type, SUM(sales) AS revenue
                 FROM blinkit_sales GROUP BY item_identifier, item_type) inner_p
           WHERE inner_p.item_type = p.item_type), 2)         AS category_avg_revenue,

    ROUND(100.0 * (p.revenue -
          (SELECT AVG(inner_p.revenue)
           FROM (SELECT item_identifier, item_type, SUM(sales) AS revenue
                 FROM blinkit_sales GROUP BY item_identifier, item_type) inner_p
           WHERE inner_p.item_type = p.item_type))
          / NULLIF((SELECT AVG(inner_p.revenue)
                    FROM (SELECT item_identifier, item_type, SUM(sales) AS revenue
                          FROM blinkit_sales GROUP BY item_identifier, item_type) inner_p
                    WHERE inner_p.item_type = p.item_type), 0), 1) AS pct_above_category,

    p.outlets_stocked,
    ROUND(p.avg_rating, 2)                                    AS avg_rating
FROM (
    SELECT item_identifier, item_type, SUM(sales) AS revenue,
           COUNT(*) AS outlets_stocked, AVG(rating) AS avg_rating
    FROM blinkit_sales
    GROUP BY item_identifier, item_type
) p
ORDER BY pct_above_category DESC
LIMIT 15;


/* ============================================================================
   A9. SELF-JOIN - STORE VS STORE ON THE SAME PRODUCT
   ----------------------------------------------------------------------------
   Business question: the same product sells far better in store A than store B
   - why?
   Why it matters: this is the cleanest natural experiment available. Same
   product, different store, different result: the cause is local execution -
   shelf position, stock availability or staff - and it can be fixed without
   changing price or supplier.
============================================================================ */
SELECT
    a.item_identifier                                         AS product,
    a.item_type                                               AS category,
    a.outlet_identifier                                       AS strong_outlet,
    ROUND(a.sales, 2)                                         AS strong_sales,
    ROUND(a.item_visibility, 4)                               AS strong_visibility,
    b.outlet_identifier                                       AS weak_outlet,
    ROUND(b.sales, 2)                                         AS weak_sales,
    ROUND(b.item_visibility, 4)                               AS weak_visibility,
    ROUND(a.sales - b.sales, 2)                               AS sales_gap,
    ROUND(a.sales / NULLIF(b.sales, 0), 1)                    AS sales_multiple,
    CASE
        WHEN a.item_visibility > b.item_visibility * 1.5
             THEN 'Likely shelf placement - weak store gives it far less space'
        WHEN a.outlet_type <> b.outlet_type
             THEN 'Store format difference - may be structural'
        ELSE 'Same format, similar visibility - investigate execution locally'
    END                                                       AS probable_cause
FROM blinkit_sales a
JOIN blinkit_sales b
  ON a.item_identifier = b.item_identifier      -- same product
 AND a.outlet_identifier <> b.outlet_identifier -- different store
 AND a.sales > b.sales * 3                      -- a materially large gap
ORDER BY sales_gap DESC
LIMIT 15;


/* ============================================================================
   A10. EXISTS / NOT EXISTS - DISTRIBUTION GAPS
   ----------------------------------------------------------------------------
   Business question: which strong products are missing from which stores?
   Why it matters: the fastest revenue win in retail is not a new product, it
   is an existing proven product placed in a store that does not yet stock it.
   No new supplier, no new listing - just distribution.
============================================================================ */
WITH top_products AS (
    -- Proven performers: top 20 by revenue.
    SELECT item_identifier, item_type, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY item_identifier, item_type
    ORDER BY revenue DESC
    LIMIT 20
),
all_outlets AS (
    SELECT DISTINCT outlet_identifier, outlet_type, outlet_location_type
    FROM blinkit_sales
)
SELECT
    t.item_identifier                                         AS proven_product,
    t.item_type                                               AS category,
    ROUND(t.revenue, 2)                                       AS product_revenue,
    o.outlet_identifier                                       AS missing_from_outlet,
    o.outlet_type,
    o.outlet_location_type                                    AS tier,
    'Distribution gap - list this product here'                AS action
FROM top_products t
CROSS JOIN all_outlets o
WHERE NOT EXISTS (
    SELECT 1
    FROM blinkit_sales s
    WHERE s.item_identifier   = t.item_identifier
      AND s.outlet_identifier = o.outlet_identifier
)
ORDER BY t.revenue DESC, o.outlet_identifier
LIMIT 25;


/* ============================================================================
   A11. RECURSIVE CTE - A GAP-FREE MONTH SPINE
   ----------------------------------------------------------------------------
   Business question: were there months with no sales at all?
   Why it matters: GROUP BY only returns months that exist in the data. If a
   month is entirely missing, it silently vanishes from the chart and the
   trend line lies. Generating the calendar first and LEFT JOINing to it is the
   only way to see a true zero.
============================================================================ */
WITH RECURSIVE month_spine AS (
    SELECT DATE_FORMAT((SELECT MIN(order_date) FROM blinkit_sales), '%Y-%m-01') AS month_start
    UNION ALL
    SELECT DATE_ADD(month_start, INTERVAL 1 MONTH)
    FROM month_spine
    WHERE month_start < (SELECT DATE_FORMAT(MAX(order_date), '%Y-%m-01') FROM blinkit_sales)
)
SELECT
    DATE_FORMAT(m.month_start, '%Y-%m')                       AS year_month,
    COALESCE(COUNT(s.sale_id), 0)                             AS records,
    ROUND(COALESCE(SUM(s.sales), 0), 2)                       AS revenue,
    CASE WHEN COUNT(s.sale_id) = 0 THEN 'NO DATA - investigate' ELSE 'OK' END AS data_check
FROM month_spine m
LEFT JOIN blinkit_sales s
       ON DATE_FORMAT(s.order_date, '%Y-%m') = DATE_FORMAT(m.month_start, '%Y-%m')
GROUP BY m.month_start
ORDER BY m.month_start;


/* ============================================================================
   A12. VIEWS - THE REUSABLE REPORTING LAYER
   ----------------------------------------------------------------------------
   Why views: the Excel dashboard, and any future BI tool, must not embed
   business logic. Defining "revenue contribution" once in a view means every
   consumer gets the same number. Without this, two reports drift apart and
   the first question in the meeting becomes "whose number is right?".
============================================================================ */

-- V1: Category performance - powers the dashboard's category chart.
CREATE OR REPLACE VIEW vw_category_performance AS
SELECT
    item_type                                                 AS category,
    COUNT(*)                                                  AS records,
    COUNT(DISTINCT item_identifier)                           AS products,
    ROUND(SUM(sales), 2)                                      AS revenue,
    ROUND(100.0 * SUM(sales) / (SELECT SUM(sales) FROM blinkit_sales), 2) AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                      AS avg_sale,
    ROUND(AVG(rating), 2)                                     AS avg_rating,
    ROUND(AVG(item_visibility), 4)                            AS avg_visibility,
    ROUND(AVG(item_weight), 2)                                AS avg_weight_kg
FROM blinkit_sales
GROUP BY item_type;

-- V2: Outlet scorecard - powers the store league table.
CREATE OR REPLACE VIEW vw_outlet_scorecard AS
SELECT
    outlet_identifier                                         AS outlet,
    outlet_type,
    outlet_size,
    outlet_location_type                                      AS tier,
    outlet_establishment_year                                 AS opened,
    outlet_age_years                                          AS age_years,
    COUNT(*)                                                  AS records,
    COUNT(DISTINCT item_type)                                 AS categories_stocked,
    COUNT(DISTINCT item_identifier)                           AS products_stocked,
    ROUND(SUM(sales), 2)                                      AS revenue,
    ROUND(100.0 * SUM(sales) / (SELECT SUM(sales) FROM blinkit_sales), 2) AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                      AS avg_sale,
    ROUND(AVG(rating), 2)                                     AS avg_rating
FROM blinkit_sales
GROUP BY outlet_identifier, outlet_type, outlet_size, outlet_location_type,
         outlet_establishment_year, outlet_age_years;

-- V3: Monthly trend with growth already computed - powers the trend line.
CREATE OR REPLACE VIEW vw_monthly_trend AS
WITH monthly AS (
    SELECT order_year AS yr, order_month AS mth, order_year_month AS ym,
           SUM(sales) AS revenue, COUNT(*) AS records, AVG(rating) AS avg_rating
    FROM blinkit_sales
    GROUP BY order_year, order_month, order_year_month
)
SELECT
    ym                                                        AS year_month,
    yr                                                        AS year,
    mth                                                       AS month_no,
    records,
    ROUND(revenue, 2)                                         AS revenue,
    ROUND(avg_rating, 2)                                      AS avg_rating,
    ROUND(LAG(revenue) OVER (ORDER BY ym), 2)                 AS prev_month_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY ym))
          / NULLIF(LAG(revenue) OVER (ORDER BY ym), 0), 2)    AS mom_pct_change,
    ROUND(AVG(revenue) OVER (ORDER BY ym ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)
                                                              AS moving_avg_3m,
    ROUND(SUM(revenue) OVER (ORDER BY ym
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_total
FROM monthly;

-- V4: Product master with segment + rank - powers top/bottom product charts.
CREATE OR REPLACE VIEW vw_product_master AS
WITH stats AS (
    SELECT
        item_identifier, item_type, item_fat_content,
        SUM(sales) AS revenue, AVG(sales) AS avg_sale, AVG(rating) AS avg_rating,
        AVG(item_visibility) AS avg_visibility, COUNT(*) AS outlets_stocked
    FROM blinkit_sales
    GROUP BY item_identifier, item_type, item_fat_content
),
bench AS (SELECT AVG(revenue) AS r, AVG(avg_rating) AS g FROM stats)
SELECT
    s.item_identifier                                         AS product,
    s.item_type                                               AS category,
    s.item_fat_content                                        AS fat_content,
    s.outlets_stocked,
    ROUND(s.revenue, 2)                                       AS revenue,
    ROUND(s.avg_sale, 2)                                      AS avg_sale,
    ROUND(s.avg_rating, 2)                                    AS avg_rating,
    ROUND(s.avg_visibility, 4)                                AS avg_visibility,
    RANK() OVER (ORDER BY s.revenue DESC)                     AS revenue_rank_overall,
    RANK() OVER (PARTITION BY s.item_type ORDER BY s.revenue DESC) AS revenue_rank_in_category,
    NTILE(4) OVER (ORDER BY s.revenue DESC)                   AS revenue_quartile,
    CASE
        WHEN s.revenue >= b.r AND s.avg_rating >= b.g THEN 'Star'
        WHEN s.revenue >= b.r AND s.avg_rating <  b.g THEN 'Fix quality'
        WHEN s.revenue <  b.r AND s.avg_rating >= b.g THEN 'Promote'
        ELSE 'Delist candidate'
    END                                                       AS segment
FROM stats s
CROSS JOIN bench b;

-- V5: Executive KPI strip - single row, powers the dashboard KPI cards.
CREATE OR REPLACE VIEW vw_executive_kpis AS
SELECT
    ROUND(SUM(sales), 2)                                      AS total_revenue,
    COUNT(*)                                                  AS total_records,
    COUNT(DISTINCT item_identifier)                           AS total_products,
    COUNT(DISTINCT item_type)                                 AS total_categories,
    COUNT(DISTINCT outlet_identifier)                         AS total_outlets,
    ROUND(AVG(sales), 2)                                      AS avg_sale,
    ROUND(AVG(rating), 2)                                     AS avg_rating,
    ROUND(AVG(item_visibility), 4)                            AS avg_visibility,
    MIN(order_date)                                           AS period_start,
    MAX(order_date)                                           AS period_end
FROM blinkit_sales;

-- Verify all five views resolve and return data.
SELECT * FROM vw_executive_kpis;
SELECT * FROM vw_category_performance ORDER BY revenue DESC LIMIT 5;
SELECT * FROM vw_outlet_scorecard     ORDER BY revenue DESC LIMIT 5;
SELECT * FROM vw_monthly_trend        ORDER BY year_month  LIMIT 6;
SELECT * FROM vw_product_master       ORDER BY revenue DESC LIMIT 5;


/* ============================================================================
   A13. STORED PROCEDURE - PARAMETERISED CATEGORY DEEP-DIVE
   ----------------------------------------------------------------------------
   Why: managers ask the same question about different categories every week.
   A procedure lets a non-SQL user run the analysis by name, and guarantees
   everyone runs the identical logic.
============================================================================ */
DROP PROCEDURE IF EXISTS sp_category_deep_dive;

DELIMITER $$
CREATE PROCEDURE sp_category_deep_dive(IN p_category VARCHAR(40))
BEGIN
    -- Guard clause: fail clearly on a typo rather than returning empty results,
    -- which a user would misread as "this category has no sales".
    IF NOT EXISTS (SELECT 1 FROM blinkit_sales WHERE item_type = p_category) THEN
        SELECT CONCAT('Category not found: ', p_category) AS error_message,
               (SELECT GROUP_CONCAT(DISTINCT item_type ORDER BY item_type SEPARATOR ', ')
                FROM blinkit_sales)                      AS valid_categories;
    ELSE
        -- 1. Headline
        SELECT
            p_category                                        AS category,
            ROUND(SUM(sales), 2)                              AS revenue,
            ROUND(100.0 * SUM(sales) / (SELECT SUM(sales) FROM blinkit_sales), 2) AS pct_of_business,
            COUNT(*)                                          AS records,
            COUNT(DISTINCT item_identifier)                   AS products,
            ROUND(AVG(sales), 2)                              AS avg_sale,
            ROUND(AVG(rating), 2)                             AS avg_rating
        FROM blinkit_sales
        WHERE item_type = p_category;

        -- 2. Top 10 products in the category
        SELECT
            item_identifier                                   AS product,
            ROUND(SUM(sales), 2)                              AS revenue,
            COUNT(*)                                          AS outlets_stocked,
            ROUND(AVG(rating), 2)                             AS avg_rating
        FROM blinkit_sales
        WHERE item_type = p_category
        GROUP BY item_identifier
        ORDER BY revenue DESC
        LIMIT 10;

        -- 3. Which stores sell it best
        SELECT
            outlet_identifier                                 AS outlet,
            outlet_type,
            ROUND(SUM(sales), 2)                              AS revenue,
            ROUND(AVG(sales), 2)                              AS avg_sale
        FROM blinkit_sales
        WHERE item_type = p_category
        GROUP BY outlet_identifier, outlet_type
        ORDER BY revenue DESC;

        -- 4. Monthly trend for the category
        SELECT
            order_year_month                                  AS year_month,
            ROUND(SUM(sales), 2)                              AS revenue,
            COUNT(*)                                          AS records
        FROM blinkit_sales
        WHERE item_type = p_category
        GROUP BY order_year_month
        ORDER BY year_month;
    END IF;
END$$
DELIMITER ;

-- Example calls
CALL sp_category_deep_dive('Fruits and Vegetables');
CALL sp_category_deep_dive('Not A Real Category');   -- demonstrates the guard


/* ============================================================================
   A14. QUERY TUNING
   ----------------------------------------------------------------------------
   Why this section exists: a query that is correct but slow will not survive
   contact with production. Being able to read a plan is what separates someone
   who writes SQL from someone who owns a pipeline.
============================================================================ */

-- Does the category roll-up use the covering index from Database.sql?
EXPLAIN
SELECT item_type, SUM(sales)
FROM blinkit_sales
GROUP BY item_type;
-- Expect: key = idx_item_type_sales, Extra = "Using index". "Using index"
-- means the answer came from the index alone without reading table rows.

-- Anti-pattern vs sargable equivalent -------------------------------------
EXPLAIN
SELECT COUNT(*) FROM blinkit_sales
WHERE YEAR(order_date) = 2023;
-- SLOW: wrapping an indexed column in a function makes it non-sargable, so
-- MySQL must evaluate YEAR() on every row - a full scan.

EXPLAIN
SELECT COUNT(*) FROM blinkit_sales
WHERE order_date >= '2023-01-01' AND order_date < '2024-01-01';
-- FAST: a plain range predicate on the bare column, so idx_order_date is
-- usable. Same answer, better plan. This is exactly why the DDL
-- pre-computes order_year and order_year_month.

-- Index usage across the schema
SELECT
    INDEX_NAME,
    GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns,
    INDEX_TYPE,
    NON_UNIQUE
FROM information_schema.STATISTICS
WHERE TABLE_SCHEMA = 'blinkit_analytics'
  AND TABLE_NAME   = 'blinkit_sales'
GROUP BY INDEX_NAME, INDEX_TYPE, NON_UNIQUE
ORDER BY INDEX_NAME;

-- Table size - is an index worth its storage?
SELECT
    TABLE_NAME,
    TABLE_ROWS,
    ROUND(DATA_LENGTH  / 1024, 1)                     AS data_kb,
    ROUND(INDEX_LENGTH / 1024, 1)                     AS index_kb,
    ROUND(100.0 * INDEX_LENGTH / NULLIF(DATA_LENGTH, 0), 1) AS index_overhead_pct
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'blinkit_analytics';

/* ============================================================================
   END OF SQL PIPELINE
   Next: Excel Dashboard/Blinkit Dashboard.xlsx
============================================================================ */
