--------------------
---------- KPI Engineering
--------------------
 
SELECT * FROM dim_customers;
SELECT * FROM dim_sellers;
SELECT * FROM dim_products;
SELECT * FROM dim_dates;
SELECT * FROM fact_shipments;
SELECT * FROM fact_payments;
SELECT * FROM fact_reviews;
 
--------------------
---------- fct_logistics_kpis_monthly
--------------------
-- Monthly logistics KPIs, sourced from fact_shipments (grain: order item).
-- Feeds the Logistics Overview dashboard's trend visuals.
 
CREATE TABLE fct_logistics_kpis_monthly AS (
SELECT
    d.year AS year,
    d.month AS month,
    AVG(f.price) AS avg_price,
    COUNT(*) AS quantity,
    SUM(f.total_line_cost) AS revenue,
    AVG(f.delivery_time_days) AS avg_delivery_time_days,   -- actual delivery time
    AVG(f.delay_days) AS avg_delay_days,                   -- delay vs estimated delivery date
    -- cast to NUMERIC before dividing: integer division would silently
    -- truncate the result to 0 (see cleaning notes on this same bug)
    (COUNT(*) FILTER(WHERE f.is_late = true)::NUMERIC / COUNT(*)) * 100.00 AS pct_late_deliveries,
    AVG(f.freight_ratio) AS avg_freight_ratio
FROM fact_shipments f
INNER JOIN dim_dates d
    ON f.purchase_date_key = d.date_key
GROUP BY 1, 2
ORDER BY 1, 2 ASC
);
 
--------------------
---------- fct_logistics_kpis_state
--------------------
-- Same KPI set as above, grouped by customer state instead of month.
-- Feeds the Logistics Overview map/state visuals.
 
CREATE TABLE fct_logistics_kpis_state AS (
SELECT
    c.customer_state AS state,
    AVG(f.price) AS avg_price,
    COUNT(*) AS quantity,
    SUM(f.total_line_cost) AS revenue,
    AVG(f.delivery_time_days) AS avg_delivery_time_days,
    AVG(f.delay_days) AS avg_delay_days,
    (COUNT(*) FILTER(WHERE f.is_late = true)::NUMERIC / COUNT(*)) * 100.00 AS pct_late_deliveries,
    AVG(f.freight_ratio) AS avg_freight_ratio
FROM fact_shipments f
INNER JOIN dim_customers c
    ON f.customer_id = c.customer_id
GROUP BY 1
ORDER BY 1 ASC
);
 
--------------------
---------- seller_metrics
--------------------
-- One row per seller. Shared base table for the Python vendor scoring
-- (fct_vendor_score) and KMeans clustering (seller_clusters) — both read
-- from this table rather than recomputing aggregates independently.
--
-- Each source is pre-aggregated to seller_id BEFORE joining, to avoid a
-- fan-out (same pattern as the order_payments vs order_items reconciliation).
--
-- Review attribution: fact_reviews is order-scoped, not seller-scoped, so
-- reviews are joined back to sellers via fact_shipments (order_id -> seller_id).
-- On multi-seller orders, the same review score is counted once per seller
-- involved.
 
CREATE TABLE seller_metrics AS
WITH shipments_agg AS (
    SELECT
        seller_id,
        COUNT(*) AS total_items,
        COUNT(DISTINCT order_id) AS total_orders,
        SUM(total_line_cost) AS total_revenue,
        AVG(price) AS avg_price,
        AVG(delivery_time_days) AS avg_delivery_time_days,
        AVG(delay_days) AS avg_delay_days,
        (COUNT(*) FILTER (WHERE is_late = true)::NUMERIC
            / COUNT(*)) * 100.00 AS pct_late_deliveries,
        AVG(freight_ratio) AS avg_freight_ratio
    FROM fact_shipments
    GROUP BY seller_id
),
 
reviews_agg AS (
    SELECT
        fs.seller_id,
        AVG(fr.review_score) AS avg_review_score,
        COUNT(DISTINCT fr.review_id) AS total_reviews
    FROM fact_reviews fr
    JOIN fact_shipments fs ON fr.order_id = fs.order_id
    GROUP BY fs.seller_id
)
 
SELECT
    s.seller_id,
    sh.total_items,
    sh.total_orders,
    sh.total_revenue,
    sh.avg_price,
    sh.avg_delivery_time_days,
    sh.avg_delay_days,
    sh.pct_late_deliveries,
    sh.avg_freight_ratio,
    r.avg_review_score,
    r.total_reviews
FROM dim_sellers s
JOIN shipments_agg sh ON s.seller_id = sh.seller_id
-- LEFT JOIN: a seller can have zero reviews; inner join would drop them
LEFT JOIN reviews_agg r ON s.seller_id = r.seller_id;
 
ALTER TABLE seller_metrics ADD PRIMARY KEY (seller_id);
 
-- Sanity check: row count should match dim_sellers with at least one sale
-- (sellers with zero fact_shipments rows are excluded by the inner join above)
SELECT COUNT(*) FROM seller_metrics;
SELECT COUNT(*) FROM dim_sellers;