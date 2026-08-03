/* ============================================================================
   BLINKIT SALES ANALYTICS  |  04 - BUSINESS QUESTIONS  (Q1 - Q40)
   ----------------------------------------------------------------------------
   Purpose : Answer the questions a category / operations / expansion manager
             actually asks, in the language they ask them in.
   Engine  : MySQL 8.0+
   Run     : mysql -u root -p blinkit_analytics < "SQL/Business Questions.sql"

   STRUCTURE
     A. Product performance        Q1  - Q8
     B. Category strategy          Q9  - Q14
     C. Store & network            Q15 - Q22
     D. Merchandising & quality    Q23 - Q29
     E. Time, trend & growth       Q30 - Q36
     F. Strategic / cross-cutting  Q37 - Q40

   EVERY QUESTION CARRIES:
     Q  - the question in business language
     >  - who asks it and what they do with the answer

   A NOTE ON RIGOUR
     Several queries below apply a minimum-volume filter before ranking. This
     is deliberate. Ranking on a single record produces a "top product" that is
     really one lucky basket, and acting on it wastes real inventory budget.
============================================================================ */

USE blinkit_analytics;


/* ############################################################################
   SECTION A - PRODUCT PERFORMANCE
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q1. Which 10 products generate the most revenue?
   > Category manager. These SKUs get guaranteed stock, prime shelf space and
     never go out of stock during a festive peak.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    COUNT(*)                                                      AS outlets_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale_per_outlet,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_identifier, item_type
ORDER BY revenue DESC
LIMIT 10;


/* ---------------------------------------------------------------------------
   Q2. Which 10 products generate the least revenue?
   > Category manager. Candidates for delisting - shelf space is the scarcest
     resource in a dark store, and a slow SKU is blocking a fast one.
     Filtered to products stocked in >= 3 outlets so a genuinely
     narrow-distribution product is not mistaken for a weak one.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    COUNT(*)                                                      AS outlets_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale_per_outlet,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_identifier, item_type
HAVING outlets_stocked >= 3
ORDER BY revenue ASC
LIMIT 10;


/* ---------------------------------------------------------------------------
   Q3. What are the top 5 products WITHIN each category?
   > Category manager. A global top-10 is dominated by the biggest categories;
     this guarantees every category has a defined hero set.
   > Technique: ROW_NUMBER() partitioned by category.
--------------------------------------------------------------------------- */
WITH product_revenue AS (
    SELECT
        item_type,
        item_identifier,
        SUM(sales)  AS revenue,
        AVG(rating) AS avg_rating,
        COUNT(*)    AS outlets_stocked
    FROM blinkit_sales
    GROUP BY item_type, item_identifier
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY item_type ORDER BY revenue DESC) AS rn
    FROM product_revenue
)
SELECT
    item_type                                                     AS category,
    rn                                                            AS rank_in_category,
    item_identifier                                               AS product,
    ROUND(revenue, 2)                                             AS revenue,
    outlets_stocked,
    ROUND(avg_rating, 2)                                          AS avg_rating
FROM ranked
WHERE rn <= 5
ORDER BY category, rank_in_category;


/* ---------------------------------------------------------------------------
   Q4. Rank every product three ways - what is the difference?
   > Analyst. ROW_NUMBER, RANK and DENSE_RANK disagree whenever there are ties,
     and quietly using the wrong one corrupts any "top N" cut-off.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROW_NUMBER() OVER (ORDER BY SUM(sales) DESC)                  AS row_number_rank,
    RANK()       OVER (ORDER BY SUM(sales) DESC)                  AS rank_with_gaps,
    DENSE_RANK() OVER (ORDER BY SUM(sales) DESC)                  AS dense_rank_no_gaps,
    NTILE(4)     OVER (ORDER BY SUM(sales) DESC)                  AS revenue_quartile
FROM blinkit_sales
GROUP BY item_identifier
ORDER BY revenue DESC
LIMIT 20;


/* ---------------------------------------------------------------------------
   Q5. Which products sell well but are rated badly?
   > Quality / merchandising. The most dangerous quadrant in retail: high
     volume amplifies a quality problem, so every unit sold damages the brand.
     Fixing these protects revenue already being earned.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    COUNT(*)                                                      AS outlets_stocked
FROM blinkit_sales
GROUP BY item_identifier, item_type
HAVING avg_rating < 3.5
   AND revenue > (SELECT AVG(product_rev)
                  FROM (SELECT SUM(sales) AS product_rev
                        FROM blinkit_sales
                        GROUP BY item_identifier) x)
ORDER BY revenue DESC
LIMIT 15;


/* ---------------------------------------------------------------------------
   Q6. Which products are the highest rated?
   > Marketing. The "customer favourite" badge set, and the shortlist for
     promotion. Minimum 4 outlets so a single glowing rating cannot win.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    COUNT(*)                                                      AS outlets_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue
FROM blinkit_sales
GROUP BY item_identifier, item_type
HAVING outlets_stocked >= 4
ORDER BY avg_rating DESC, revenue DESC
LIMIT 10;


/* ---------------------------------------------------------------------------
   Q7. Which products are the lowest rated?
   > Quality. Trigger a supplier review or delist. Every one of these is
     actively spending brand equity.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    COUNT(*)                                                      AS outlets_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue_at_risk
FROM blinkit_sales
GROUP BY item_identifier, item_type
HAVING outlets_stocked >= 4
ORDER BY avg_rating ASC
LIMIT 10;


/* ---------------------------------------------------------------------------
   Q8. How concentrated is revenue? (Pareto / ABC analysis)
   > Supply chain. If ~20% of SKUs drive ~80% of revenue, service levels and
     safety stock should be tiered rather than uniform - protecting A-items
     first is far cheaper than protecting everything.
   > Technique: running total via SUM() OVER (ORDER BY ...).
--------------------------------------------------------------------------- */
WITH product_revenue AS (
    SELECT item_identifier, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY item_identifier
),
cumulative AS (
    SELECT
        item_identifier,
        revenue,
        ROW_NUMBER() OVER (ORDER BY revenue DESC)                        AS product_rank,
        SUM(revenue) OVER (ORDER BY revenue DESC
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_revenue,
        SUM(revenue) OVER ()                                             AS total_revenue,
        COUNT(*)     OVER ()                                             AS total_products
    FROM product_revenue
)
SELECT
    abc_class,
    COUNT(*)                                                      AS products,
    ROUND(100.0 * COUNT(*) / MAX(total_products), 2)              AS pct_of_products,
    ROUND(SUM(revenue), 2)                                        AS revenue,
    ROUND(100.0 * SUM(revenue) / MAX(total_revenue), 2)           AS pct_of_revenue
FROM (
    SELECT *,
           CASE
               WHEN running_revenue / total_revenue <= 0.80 THEN 'A (top 80% of revenue)'
               WHEN running_revenue / total_revenue <= 0.95 THEN 'B (next 15%)'
               ELSE                                              'C (final 5%)'
           END AS abc_class
    FROM cumulative
) c
GROUP BY abc_class
ORDER BY abc_class;


/* ############################################################################
   SECTION B - CATEGORY STRATEGY
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q9. Which categories earn the most revenue, and what share does each hold?
   > Head of category. The master allocation table: shelf space, marketing
     budget and buying attention are all split roughly along these lines.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(SUM(SUM(sales)) OVER (ORDER BY SUM(sales) DESC)
          * 100.0 / SUM(SUM(sales)) OVER (), 2)                   AS cumulative_pct,
    COUNT(*)                                                      AS records,
    COUNT(DISTINCT item_identifier)                               AS products,
    ROUND(AVG(sales), 2)                                          AS avg_sale
FROM blinkit_sales
GROUP BY item_type
ORDER BY revenue DESC;


/* ---------------------------------------------------------------------------
   Q10. Which categories are the weakest?
   > Head of category. Candidates for range reduction. Read alongside Q11 -
     a low-revenue category with a high average sale may be a premium niche
     worth keeping rather than a failure.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    COUNT(DISTINCT item_identifier)                               AS products,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_type
ORDER BY revenue ASC
LIMIT 5;


/* ---------------------------------------------------------------------------
   Q11. Which categories command the highest average sale value?
   > Pricing. Separates premium categories (high value, low volume) from
     traffic-drivers (low value, high volume). The two need opposite tactics:
     premium wants bundling, traffic wants availability.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales) - (SELECT AVG(sales) FROM blinkit_sales), 2) AS vs_overall_avg,
    CASE
        WHEN AVG(sales) > (SELECT AVG(sales) FROM blinkit_sales)
         AND COUNT(*)   < (SELECT COUNT(*) / COUNT(DISTINCT item_type) FROM blinkit_sales)
             THEN 'Premium niche - high value, low volume'
        WHEN AVG(sales) > (SELECT AVG(sales) FROM blinkit_sales)
             THEN 'Star - high value, high volume'
        WHEN COUNT(*)   > (SELECT COUNT(*) / COUNT(DISTINCT item_type) FROM blinkit_sales)
             THEN 'Traffic driver - low value, high volume'
        ELSE 'Review - low value, low volume'
    END                                                           AS strategic_role
FROM blinkit_sales
GROUP BY item_type
ORDER BY avg_sale DESC;


/* ---------------------------------------------------------------------------
   Q12. Which categories are the most popular by transaction count?
   > Operations. Volume drives picking effort and dark-store layout. The
     highest-volume category belongs nearest the packing station.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    COUNT(*)                                                      AS records,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)            AS pct_of_records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER ()
        - 100.0 * COUNT(*)   / SUM(COUNT(*))   OVER (), 2)        AS revenue_vs_volume_gap
FROM blinkit_sales
GROUP BY item_type
ORDER BY records DESC;
-- revenue_vs_volume_gap > 0 means the category earns more than its share of
-- effort; < 0 means it consumes picking capacity out of proportion to value.


/* ---------------------------------------------------------------------------
   Q13. How is each category rated?
   > Quality. A large category with a weak rating is the highest-priority fix
     because the poor experience is reaching the most customers.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    ROUND(MIN(rating), 1)                                         AS worst_rating,
    ROUND(MAX(rating), 1)                                         AS best_rating,
    ROUND(STDDEV_SAMP(rating), 2)                                 AS rating_consistency,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue
FROM blinkit_sales
GROUP BY item_type
ORDER BY avg_rating DESC;
-- A high rating_consistency (std dev) means the category is inconsistent:
-- some SKUs delight, others disappoint. That is a supplier problem, not a
-- category problem, and it needs a SKU-level fix.


/* ---------------------------------------------------------------------------
   Q14. How does each category perform in each store format?
   > Category + operations jointly. Reveals that assortment should not be
     identical across formats - what sells in a Supermarket Type3 is not what
     sells in a Grocery Store.
   > Technique: conditional aggregation (pivot with CASE WHEN).
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(SUM(CASE WHEN outlet_type = 'Grocery Store'     THEN sales ELSE 0 END), 0) AS grocery_store,
    ROUND(SUM(CASE WHEN outlet_type = 'Supermarket Type1' THEN sales ELSE 0 END), 0) AS supermarket_t1,
    ROUND(SUM(CASE WHEN outlet_type = 'Supermarket Type2' THEN sales ELSE 0 END), 0) AS supermarket_t2,
    ROUND(SUM(CASE WHEN outlet_type = 'Supermarket Type3' THEN sales ELSE 0 END), 0) AS supermarket_t3,
    ROUND(SUM(sales), 0)                                                             AS total
FROM blinkit_sales
GROUP BY item_type
ORDER BY total DESC;


/* ############################################################################
   SECTION C - STORE & NETWORK
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q15. Which stores perform best?
   > Regional manager. The top stores are the benchmark - their layout,
     staffing and range become the template for the rest of the estate.
--------------------------------------------------------------------------- */
SELECT
    outlet_identifier                                             AS outlet,
    outlet_type,
    outlet_size,
    outlet_location_type                                          AS tier,
    outlet_establishment_year                                     AS opened,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    RANK() OVER (ORDER BY SUM(sales) DESC)                        AS revenue_rank
FROM blinkit_sales
GROUP BY outlet_identifier, outlet_type, outlet_size,
         outlet_location_type, outlet_establishment_year
ORDER BY revenue DESC
LIMIT 5;


/* ---------------------------------------------------------------------------
   Q16. Which stores perform worst?
   > Regional manager. Turnaround or closure list. Check avg_sale before
     judging: low total + healthy average means a small store doing fine, and
     closing it would be a mistake.
--------------------------------------------------------------------------- */
SELECT
    outlet_identifier                                             AS outlet,
    outlet_type,
    outlet_size,
    outlet_location_type                                          AS tier,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    COUNT(*)                                                      AS records,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    ROUND(AVG(sales) - (SELECT AVG(sales) FROM blinkit_sales), 2) AS avg_sale_vs_network
FROM blinkit_sales
GROUP BY outlet_identifier, outlet_type, outlet_size, outlet_location_type
ORDER BY revenue ASC
LIMIT 5;


/* ---------------------------------------------------------------------------
   Q17. What is the average revenue per outlet, by format?
   > Expansion. The single most important number for the next store decision:
     which format returns most per store opened.
--------------------------------------------------------------------------- */
SELECT
    outlet_type,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS total_revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY outlet_type
ORDER BY revenue_per_store DESC;


/* ---------------------------------------------------------------------------
   Q18. How does each location tier perform?
   > Expansion. Tests the assumption that metros are the best bet. In Indian
     q-commerce, lower competition in smaller cities often produces a higher
     average basket, and the data should decide, not the assumption.
--------------------------------------------------------------------------- */
SELECT
    outlet_location_type                                          AS tier,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY outlet_location_type
ORDER BY revenue_per_store DESC;


/* ---------------------------------------------------------------------------
   Q19. Does outlet size translate into sales?
   > Property / expansion. Determines whether to lease bigger space. If a
     Medium store earns as much as a High one, the extra rent is wasted.
--------------------------------------------------------------------------- */
SELECT
    outlet_size,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(sales), 2)                                          AS avg_sale
FROM blinkit_sales
GROUP BY outlet_size
ORDER BY revenue_per_store DESC;


/* ---------------------------------------------------------------------------
   Q20. Do older stores outperform newer ones?
   > Expansion. Quantifies the maturity ramp - how long a new store takes to
     reach steady state, which sets the payback period in the business case.
--------------------------------------------------------------------------- */
SELECT
    outlet_establishment_year                                     AS opened,
    outlet_age_years                                              AS age_years,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(sales), 2)                                          AS avg_sale
FROM blinkit_sales
GROUP BY outlet_establishment_year, outlet_age_years
ORDER BY opened;


/* ---------------------------------------------------------------------------
   Q21. Which store-format x tier combination is strongest?
   > Expansion. The actual decision is never "which format" or "which city"
     alone - it is the pair. This is the query that answers it.
--------------------------------------------------------------------------- */
SELECT
    outlet_type,
    outlet_location_type                                          AS tier,
    COUNT(DISTINCT outlet_identifier)                             AS stores,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT outlet_identifier), 2)      AS revenue_per_store,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    RANK() OVER (ORDER BY SUM(sales) / COUNT(DISTINCT outlet_identifier) DESC) AS opportunity_rank
FROM blinkit_sales
GROUP BY outlet_type, outlet_location_type
ORDER BY revenue_per_store DESC;


/* ---------------------------------------------------------------------------
   Q22. How wide is the assortment in each store, and does breadth pay?
   > Merchandising. Tests whether stocking more categories raises revenue, or
     whether a focused range performs just as well on less working capital.
--------------------------------------------------------------------------- */
SELECT
    outlet_identifier                                             AS outlet,
    outlet_type,
    COUNT(DISTINCT item_type)                                     AS categories_stocked,
    COUNT(DISTINCT item_identifier)                               AS products_stocked,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(SUM(sales) / COUNT(DISTINCT item_identifier), 2)        AS revenue_per_product
FROM blinkit_sales
GROUP BY outlet_identifier, outlet_type
ORDER BY revenue_per_product DESC;


/* ############################################################################
   SECTION D - MERCHANDISING & QUALITY
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q23. Does shelf visibility drive sales?
   > Merchandising. The most actionable relationship in the dataset: shelf
     placement is free to change, unlike price or product. Quintiles make the
     answer readable to a non-technical audience.
--------------------------------------------------------------------------- */
WITH banded AS (
    SELECT sales, item_visibility, rating,
           NTILE(5) OVER (ORDER BY item_visibility) AS visibility_quintile
    FROM blinkit_sales
)
SELECT
    CASE visibility_quintile
        WHEN 1 THEN '1 - Lowest visibility'
        WHEN 2 THEN '2'
        WHEN 3 THEN '3 - Middle'
        WHEN 4 THEN '4'
        WHEN 5 THEN '5 - Highest visibility'
    END                                                           AS visibility_band,
    COUNT(*)                                                      AS records,
    ROUND(AVG(item_visibility), 4)                                AS avg_visibility,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM banded
GROUP BY visibility_quintile
ORDER BY visibility_quintile;


/* ---------------------------------------------------------------------------
   Q24. Quantify it: how much more does the top visibility quintile sell?
   > Merchandising. Converts Q23 into a single number a manager can put in a
     business case for a shelf-reset programme.
--------------------------------------------------------------------------- */
WITH banded AS (
    SELECT sales, NTILE(5) OVER (ORDER BY item_visibility) AS q
    FROM blinkit_sales
),
by_band AS (
    SELECT q, AVG(sales) AS avg_sale FROM banded GROUP BY q
)
SELECT
    ROUND((SELECT avg_sale FROM by_band WHERE q = 1), 2)          AS lowest_quintile_avg,
    ROUND((SELECT avg_sale FROM by_band WHERE q = 5), 2)          AS highest_quintile_avg,
    ROUND((SELECT avg_sale FROM by_band WHERE q = 5)
        - (SELECT avg_sale FROM by_band WHERE q = 1), 2)          AS absolute_uplift,
    ROUND(100.0 * ((SELECT avg_sale FROM by_band WHERE q = 5)
                 - (SELECT avg_sale FROM by_band WHERE q = 1))
        / (SELECT avg_sale FROM by_band WHERE q = 1), 1)          AS pct_uplift;


/* ---------------------------------------------------------------------------
   Q25. Low Fat vs Regular - which sells better?
   > Assortment / marketing. Informs the health-positioning of the range and
     whether to expand the Low Fat line.
--------------------------------------------------------------------------- */
SELECT
    item_fat_content,
    COUNT(*)                                                      AS records,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)            AS pct_of_records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(AVG(rating), 2)                                         AS avg_rating
FROM blinkit_sales
GROUP BY item_fat_content
ORDER BY revenue DESC;


/* ---------------------------------------------------------------------------
   Q26. Fat content split within each category
   > Assortment. Shows where a Low Fat alternative is missing from the range -
     a concrete gap-filling list rather than a general aspiration.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(SUM(CASE WHEN item_fat_content = 'Low Fat' THEN sales ELSE 0 END), 0) AS low_fat_revenue,
    ROUND(SUM(CASE WHEN item_fat_content = 'Regular' THEN sales ELSE 0 END), 0) AS regular_revenue,
    ROUND(100.0 * SUM(CASE WHEN item_fat_content = 'Low Fat' THEN sales ELSE 0 END)
          / NULLIF(SUM(sales), 0), 1)                                           AS low_fat_share_pct,
    ROUND(AVG(CASE WHEN item_fat_content = 'Low Fat' THEN rating END), 2)       AS low_fat_rating,
    ROUND(AVG(CASE WHEN item_fat_content = 'Regular' THEN rating END), 2)       AS regular_rating
FROM blinkit_sales
GROUP BY item_type
ORDER BY low_fat_share_pct DESC;


/* ---------------------------------------------------------------------------
   Q27. Does a higher rating come with higher sales?
   > Leadership. Tests whether investing in quality pays commercially. If it
     does, the quality budget defends itself.
--------------------------------------------------------------------------- */
SELECT
    CASE
        WHEN rating < 3.0 THEN 'Under 3.0'
        WHEN rating < 3.5 THEN '3.0 - 3.4'
        WHEN rating < 4.0 THEN '3.5 - 3.9'
        WHEN rating < 4.5 THEN '4.0 - 4.4'
        ELSE                   '4.5 - 5.0'
    END                                                           AS rating_band,
    COUNT(*)                                                      AS records,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_revenue
FROM blinkit_sales
GROUP BY rating_band
ORDER BY rating_band;


/* ---------------------------------------------------------------------------
   Q28. Which products are under-exposed relative to how well they sell?
   > Merchandising. The concrete action list from Q23/Q24: strong sellers
     sitting on below-average shelf share. Moving these is the cheapest
     revenue available.
--------------------------------------------------------------------------- */
SELECT
    item_identifier                                               AS product,
    item_type                                                     AS category,
    ROUND(AVG(item_visibility), 4)                                AS avg_visibility,
    ROUND((SELECT AVG(item_visibility) FROM blinkit_sales), 4)    AS network_avg_visibility,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(rating), 2)                                         AS avg_rating,
    COUNT(*)                                                      AS outlets_stocked
FROM blinkit_sales
GROUP BY item_identifier, item_type
HAVING avg_visibility < (SELECT AVG(item_visibility) FROM blinkit_sales)
   AND revenue        > (SELECT AVG(product_rev)
                         FROM (SELECT SUM(sales) AS product_rev
                               FROM blinkit_sales GROUP BY item_identifier) x)
ORDER BY revenue DESC
LIMIT 15;


/* ---------------------------------------------------------------------------
   Q29. Inventory profile - what weight of goods does each category move?
   > Supply chain / last mile. Heavy categories cost more to store and deliver,
     which changes their true margin even when revenue looks identical.
--------------------------------------------------------------------------- */
SELECT
    item_type                                                     AS category,
    ROUND(AVG(item_weight), 2)                                    AS avg_weight_kg,
    ROUND(SUM(item_weight), 0)                                    AS total_weight_kg,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(SUM(sales) / NULLIF(SUM(item_weight), 0), 2)            AS revenue_per_kg,
    SUM(item_weight_imputed)                                      AS rows_with_imputed_weight
FROM blinkit_sales
GROUP BY item_type
ORDER BY revenue_per_kg DESC;
-- revenue_per_kg is the logistics efficiency metric: high = light and
-- valuable (cheap to move), low = heavy and cheap (erodes delivery margin).
-- rows_with_imputed_weight is shown so the reader knows how much of this
-- figure rests on imputation.


/* ############################################################################
   SECTION E - TIME, TREND & GROWTH
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q30. What does the monthly revenue trend look like?
   > Everyone. The opening slide of the monthly business review.
   > Technique: LAG() for month-on-month movement.
--------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT order_year_month AS ym, SUM(sales) AS revenue, COUNT(*) AS records
    FROM blinkit_sales
    GROUP BY order_year_month
)
SELECT
    ym                                                            AS year_month,
    records,
    ROUND(revenue, 2)                                             AS revenue,
    ROUND(LAG(revenue) OVER (ORDER BY ym), 2)                     AS prev_month_revenue,
    ROUND(revenue - LAG(revenue) OVER (ORDER BY ym), 2)           AS mom_change,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY ym))
          / NULLIF(LAG(revenue) OVER (ORDER BY ym), 0), 2)        AS mom_pct_change
FROM monthly
ORDER BY ym;


/* ---------------------------------------------------------------------------
   Q31. Running total of revenue - are we on track?
   > Finance. Cumulative actuals are what a target is tracked against; a
     monthly bar chart alone cannot answer "will we land the year?".
--------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT order_year AS yr, order_year_month AS ym, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY order_year, order_year_month
)
SELECT
    ym                                                            AS year_month,
    ROUND(revenue, 2)                                             AS monthly_revenue,
    ROUND(SUM(revenue) OVER (ORDER BY ym
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)   AS running_total_all_time,
    ROUND(SUM(revenue) OVER (PARTITION BY yr ORDER BY ym
          ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2)   AS running_total_ytd
FROM monthly
ORDER BY ym;


/* ---------------------------------------------------------------------------
   Q32. 3-month moving average - what is the trend under the noise?
   > Planning. Smooths festive spikes so an underlying decline is not mistaken
     for normal seasonal variation.
--------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT order_year_month AS ym, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY order_year_month
)
SELECT
    ym                                                            AS year_month,
    ROUND(revenue, 2)                                             AS revenue,
    ROUND(AVG(revenue) OVER (ORDER BY ym
          ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)           AS moving_avg_3m,
    ROUND(revenue - AVG(revenue) OVER (ORDER BY ym
          ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)           AS deviation_from_trend
FROM monthly
ORDER BY ym;


/* ---------------------------------------------------------------------------
   Q33. Year-on-year growth by month
   > Leadership. The only fair month comparison, because it holds seasonality
     constant. October vs September is noise; October vs last October is signal.
   > Technique: LAG(..., 12) reaches back exactly one year.
--------------------------------------------------------------------------- */
WITH monthly AS (
    SELECT order_year AS yr, order_month AS mth, order_year_month AS ym,
           SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY order_year, order_month, order_year_month
)
SELECT
    ym                                                            AS year_month,
    ROUND(revenue, 2)                                             AS revenue,
    ROUND(LAG(revenue, 12) OVER (ORDER BY ym), 2)                 AS same_month_last_year,
    ROUND(revenue - LAG(revenue, 12) OVER (ORDER BY ym), 2)       AS yoy_change,
    ROUND(100.0 * (revenue - LAG(revenue, 12) OVER (ORDER BY ym))
          / NULLIF(LAG(revenue, 12) OVER (ORDER BY ym), 0), 2)    AS yoy_pct_growth
FROM monthly
ORDER BY ym;


/* ---------------------------------------------------------------------------
   Q34. Full-year comparison
   > Leadership. The headline growth number for the annual review.
--------------------------------------------------------------------------- */
WITH yearly AS (
    SELECT order_year AS yr, SUM(sales) AS revenue, COUNT(*) AS records,
           AVG(sales) AS avg_sale, AVG(rating) AS avg_rating
    FROM blinkit_sales
    GROUP BY order_year
)
SELECT
    yr                                                            AS year,
    records,
    ROUND(revenue, 2)                                             AS revenue,
    ROUND(avg_sale, 2)                                            AS avg_sale,
    ROUND(avg_rating, 2)                                          AS avg_rating,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY yr))
          / NULLIF(LAG(revenue) OVER (ORDER BY yr), 0), 2)        AS yoy_growth_pct,
    ROUND(100.0 * (avg_sale - LAG(avg_sale) OVER (ORDER BY yr))
          / NULLIF(LAG(avg_sale) OVER (ORDER BY yr), 0), 2)       AS basket_growth_pct
FROM yearly
ORDER BY yr;
-- Reading it: if revenue growth far exceeds basket growth, growth came from
-- volume (more transactions). If they move together, growth came from
-- customers spending more per order - a healthier, cheaper kind of growth.


/* ---------------------------------------------------------------------------
   Q35. Which months are peak and which are troughs?
   > Supply chain + marketing. Sets the inventory build-up calendar and the
     promotional calendar for the year ahead.
--------------------------------------------------------------------------- */
SELECT
    order_month                                                   AS month_no,
    MAX(order_month_name)                                         AS month_name,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(100.0 * SUM(sales) / SUM(SUM(sales)) OVER (), 2)        AS pct_of_annual_revenue,
    RANK() OVER (ORDER BY SUM(sales) DESC)                        AS month_rank,
    ROUND(SUM(sales) / (SUM(SUM(sales)) OVER () / 12), 2)         AS seasonality_index
FROM blinkit_sales
GROUP BY order_month
ORDER BY month_no;
-- seasonality_index: 1.00 = an average month. 1.15 = 15% above average, so
-- stock and staffing should be raised by roughly that much.


/* ---------------------------------------------------------------------------
   Q36. Quarterly performance
   > Finance. The reporting rhythm the business is actually managed on.
--------------------------------------------------------------------------- */
SELECT
    order_year                                                    AS year,
    order_quarter                                                 AS quarter,
    CONCAT(order_year, '-Q', order_quarter)                       AS period,
    COUNT(*)                                                      AS records,
    ROUND(SUM(sales), 2)                                          AS revenue,
    ROUND(AVG(sales), 2)                                          AS avg_sale,
    ROUND(100.0 * (SUM(sales) - LAG(SUM(sales)) OVER (ORDER BY order_year, order_quarter))
          / NULLIF(LAG(SUM(sales)) OVER (ORDER BY order_year, order_quarter), 0), 2)
                                                                  AS qoq_growth_pct
FROM blinkit_sales
GROUP BY order_year, order_quarter
ORDER BY year, quarter;


/* ############################################################################
   SECTION F - STRATEGIC / CROSS-CUTTING
   ######################################################################### */

/* ---------------------------------------------------------------------------
   Q37. Which categories are growing and which are declining?
   > Head of category. The forward-looking view. A large category in decline is
     a bigger problem than a small one that never grew, and this separates them.
--------------------------------------------------------------------------- */
WITH cat_year AS (
    SELECT item_type, order_year, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY item_type, order_year
),
growth AS (
    SELECT
        item_type,
        MAX(CASE WHEN order_year = 2022 THEN revenue END) AS rev_2022,
        MAX(CASE WHEN order_year = 2023 THEN revenue END) AS rev_2023
    FROM cat_year
    GROUP BY item_type
)
SELECT
    item_type                                                     AS category,
    ROUND(rev_2022, 2)                                            AS revenue_2022,
    ROUND(rev_2023, 2)                                            AS revenue_2023,
    ROUND(rev_2023 - rev_2022, 2)                                 AS absolute_growth,
    ROUND(100.0 * (rev_2023 - rev_2022) / NULLIF(rev_2022, 0), 2) AS growth_pct,
    CASE
        WHEN 100.0 * (rev_2023 - rev_2022) / NULLIF(rev_2022, 0) >= 25 THEN 'Accelerating - invest'
        WHEN 100.0 * (rev_2023 - rev_2022) / NULLIF(rev_2022, 0) >= 10 THEN 'Growing - maintain'
        WHEN 100.0 * (rev_2023 - rev_2022) / NULLIF(rev_2022, 0) >=  0 THEN 'Flat - review'
        ELSE                                                            'Declining - act now'
    END                                                           AS verdict
FROM growth
ORDER BY growth_pct DESC;


/* ---------------------------------------------------------------------------
   Q38. Which stores are growing and which are declining?
   > Regional manager. Identifies stores losing ground even while the network
     grows - invisible in a total-revenue league table.
--------------------------------------------------------------------------- */
WITH outlet_year AS (
    SELECT outlet_identifier, outlet_type, order_year, SUM(sales) AS revenue
    FROM blinkit_sales
    GROUP BY outlet_identifier, outlet_type, order_year
),
growth AS (
    SELECT
        outlet_identifier, outlet_type,
        MAX(CASE WHEN order_year = 2022 THEN revenue END) AS rev_2022,
        MAX(CASE WHEN order_year = 2023 THEN revenue END) AS rev_2023
    FROM outlet_year
    GROUP BY outlet_identifier, outlet_type
)
SELECT
    outlet_identifier                                             AS outlet,
    outlet_type,
    ROUND(rev_2022, 2)                                            AS revenue_2022,
    ROUND(rev_2023, 2)                                            AS revenue_2023,
    ROUND(100.0 * (rev_2023 - rev_2022) / NULLIF(rev_2022, 0), 2) AS growth_pct,
    RANK() OVER (ORDER BY 100.0 * (rev_2023 - rev_2022)
                 / NULLIF(rev_2022, 0) DESC)                      AS growth_rank
FROM growth
ORDER BY growth_pct DESC;


/* ---------------------------------------------------------------------------
   Q39. Category performance INSIDE each store vs the network benchmark
   > Regional manager. The most operationally useful query here: it finds a
     category underperforming in one specific store while doing fine
     everywhere else - almost always a local execution problem (placement,
     stock-outs, staff) and therefore fixable this week.
   > Technique: correlated comparison against a window-computed benchmark.
--------------------------------------------------------------------------- */
WITH store_cat AS (
    SELECT outlet_identifier, item_type,
           SUM(sales) AS revenue, AVG(sales) AS avg_sale, COUNT(*) AS records
    FROM blinkit_sales
    GROUP BY outlet_identifier, item_type
),
benchmarked AS (
    SELECT *,
           AVG(avg_sale) OVER (PARTITION BY item_type) AS category_network_avg
    FROM store_cat
)
SELECT
    outlet_identifier                                             AS outlet,
    item_type                                                     AS category,
    records,
    ROUND(revenue, 2)                                             AS revenue,
    ROUND(avg_sale, 2)                                            AS store_avg_sale,
    ROUND(category_network_avg, 2)                                AS network_avg_sale,
    ROUND(100.0 * (avg_sale - category_network_avg)
          / NULLIF(category_network_avg, 0), 1)                   AS pct_vs_network,
    CASE
        WHEN avg_sale < category_network_avg * 0.80 THEN 'Underperforming - investigate'
        WHEN avg_sale > category_network_avg * 1.20 THEN 'Outperforming - learn from it'
        ELSE                                             'In line'
    END                                                           AS flag
FROM benchmarked
WHERE records >= 15
ORDER BY pct_vs_network ASC
LIMIT 20;


/* ---------------------------------------------------------------------------
   Q40. The one-page executive summary
   > CEO / leadership. Everything above compressed into a single result set.
     If only one query survived from this file, it would be this one.
--------------------------------------------------------------------------- */
SELECT 'Total Revenue (INR)'      AS metric,
       FORMAT(SUM(sales), 2)      AS value,
       'Headline topline'         AS why_it_matters
FROM blinkit_sales
UNION ALL
SELECT 'Sales Records', FORMAT(COUNT(*), 0), 'Volume of product-outlet sales'
FROM blinkit_sales
UNION ALL
SELECT 'Average Sale (INR)', FORMAT(AVG(sales), 2), 'Basket value - the growth-quality lever'
FROM blinkit_sales
UNION ALL
SELECT 'Average Rating', FORMAT(AVG(rating), 2), 'Customer satisfaction guardrail'
FROM blinkit_sales
UNION ALL
SELECT 'Products / Categories',
       CONCAT(COUNT(DISTINCT item_identifier), ' / ', COUNT(DISTINCT item_type)),
       'Assortment breadth'
FROM blinkit_sales
UNION ALL
SELECT 'Outlets', CAST(COUNT(DISTINCT outlet_identifier) AS CHAR), 'Network footprint'
FROM blinkit_sales
UNION ALL
SELECT 'Top Category',
       (SELECT item_type FROM blinkit_sales
        GROUP BY item_type ORDER BY SUM(sales) DESC LIMIT 1),
       'Largest revenue pool - protect first'
FROM DUAL
UNION ALL
SELECT 'Top Outlet',
       (SELECT outlet_identifier FROM blinkit_sales
        GROUP BY outlet_identifier ORDER BY SUM(sales) DESC LIMIT 1),
       'Benchmark store - copy its playbook'
FROM DUAL
UNION ALL
SELECT 'Best Format by Revenue/Store',
       (SELECT outlet_type FROM blinkit_sales GROUP BY outlet_type
        ORDER BY SUM(sales) / COUNT(DISTINCT outlet_identifier) DESC LIMIT 1),
       'Where the next store should be opened'
FROM DUAL
UNION ALL
SELECT 'Peak Month',
       (SELECT order_month_name FROM blinkit_sales
        GROUP BY order_month, order_month_name ORDER BY SUM(sales) DESC LIMIT 1),
       'Build inventory ahead of this month'
FROM DUAL;

/* Next step: SQL/Advanced Analysis.sql */
