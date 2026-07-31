-- ============================================================================
-- IVOIRE PROJECT - Star Schema Build
-- Sourced from the clean_* tables (see ivoire_data_cleaning.sql).
-- Naming convention: every table here is prefixed dim_ or fact_.
-- Grain of fact_shipments = one row per order item (order_id + order_item_id).
-- fact_payments and fact_reviews are kept separate to avoid a fan-out join,
-- since payments and reviews sit at a different grain than order_items.
-- ============================================================================


-- ============================================================================
-- DIM_CUSTOMERS
-- ============================================================================

CREATE TABLE dim_customers AS
SELECT
    customer_id,
    customer_unique_id,
    customer_zip_code_prefix,
    customer_city,
    customer_state,
    is_city_valid,
    zip_in_geolocation
FROM clean_customers;

ALTER TABLE dim_customers ADD PRIMARY KEY (customer_id);


-- ============================================================================
-- DIM_SELLERS
-- ============================================================================

CREATE TABLE dim_sellers AS
SELECT
    seller_id,
    seller_zip_code_prefix,
    seller_city,
    seller_state,
    is_city_valid
FROM clean_sellers;

ALTER TABLE dim_sellers ADD PRIMARY KEY (seller_id);


-- ============================================================================
-- DIM_PRODUCTS
-- ============================================================================
-- Joined against the translation table to carry the English category name
-- directly on the dimension, so downstream reports don't need a second join.

CREATE TABLE dim_products AS
SELECT
    p.product_id,
    p.product_category_name,
    t.product_category_name_english,
    p.product_name_lenght,
    p.product_description_lenght,
    p.product_photos_qty,
    p.product_weight_g,
    p.product_length_cm,
    p.product_height_cm,
    p.product_width_cm,
    p.is_incomplete_product,
    p.is_missing_category,
    p.is_category_valid,
    p.is_weight_outlier
FROM clean_products p
LEFT JOIN clean_product_category_name_translation t
    ON p.product_category_name = t.product_category_name;

ALTER TABLE dim_products ADD PRIMARY KEY (product_id);


-- ============================================================================
-- DIM_DATES
-- ============================================================================
-- Calendar table generated independently, spanning the full range of order
-- purchase dates with a small buffer on each side to safely cover every
-- date column used across the fact tables (approval, delivery, review, etc.).

CREATE TABLE dim_dates AS
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INT   AS date_key,
    d::DATE                        AS full_date,
    EXTRACT(YEAR FROM d)::INT      AS year,
    EXTRACT(QUARTER FROM d)::INT   AS quarter,
    EXTRACT(MONTH FROM d)::INT     AS month,
    TO_CHAR(d, 'Month')            AS month_name,
    EXTRACT(DAY FROM d)::INT       AS day,
    EXTRACT(ISODOW FROM d)::INT    AS day_of_week,     -- 1=Monday ... 7=Sunday
    TO_CHAR(d, 'Day')              AS day_name,
    EXTRACT(ISODOW FROM d) IN (6, 7) AS is_weekend
FROM GENERATE_SERIES(
    (SELECT MIN(order_purchase_timestamp)::DATE - INTERVAL '7 day' FROM clean_orders),
    (SELECT MAX(order_estimated_delivery_date)::DATE + INTERVAL '7 day' FROM clean_orders),
    INTERVAL '1 day'
) AS d;

ALTER TABLE dim_dates ADD PRIMARY KEY (date_key);


-- ============================================================================
-- FACT_SHIPMENTS
-- ============================================================================
-- Grain: one row per order item. Order-level measures (delivery_time_days,
-- is_late, etc.) repeat across every item of the same order — expected at
-- this grain, not a duplication error.

CREATE TABLE fact_shipments AS
SELECT
    -- degenerate keys (identify the line item itself, no dedicated dimension)
    oi.order_id,
    oi.order_item_id,

    -- foreign keys to dimensions
    o.customer_id,
    oi.seller_id,
    oi.product_id,
    TO_CHAR(o.order_purchase_timestamp::DATE, 'YYYYMMDD')::INT AS purchase_date_key,

    -- order-level attributes and measures
    o.order_status,
    o.order_purchase_timestamp,
    o.order_approved_at,
    o.order_delivered_carrier_date,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    o.delivery_time_days,
    o.delay_days,
    o.is_late,
    o.approval_time_hours,
    o.carrier_transit_days,
    o.is_status_date_coherent,
    o.is_date_coherent,
    o.carrier_before_approved,
    o.delivered_before_carrier,

    -- item-level measures
    oi.shipping_limit_date,
    oi.price,
    oi.freight_value,
    oi.total_line_cost,
    oi.freight_ratio,
    oi.is_shipping_date_coherent,
    oi.is_price_outlier,
    oi.is_freight_outlier

FROM clean_order_items oi
JOIN clean_orders o ON oi.order_id = o.order_id;

ALTER TABLE fact_shipments ADD PRIMARY KEY (order_id, order_item_id);
ALTER TABLE fact_shipments ADD FOREIGN KEY (customer_id) REFERENCES dim_customers (customer_id);
ALTER TABLE fact_shipments ADD FOREIGN KEY (seller_id) REFERENCES dim_sellers (seller_id);
ALTER TABLE fact_shipments ADD FOREIGN KEY (product_id) REFERENCES dim_products (product_id);
ALTER TABLE fact_shipments ADD FOREIGN KEY (purchase_date_key) REFERENCES dim_dates (date_key);


-- ============================================================================
-- FACT_PAYMENTS
-- ============================================================================
-- Grain: one row per payment (order_id + payment_sequential). Kept separate
-- from fact_shipments — an order's payments don't map 1-to-1 to its items,
-- joining them directly would fan-out the row count (see cleaning notes).

CREATE TABLE fact_payments AS
SELECT
    op.order_id,
    op.payment_sequential,

    o.customer_id,
    TO_CHAR(o.order_purchase_timestamp::DATE, 'YYYYMMDD')::INT AS purchase_date_key,

    op.payment_type,
    op.payment_installments,
    op.payment_value,
    op.is_payment_valid,
    op.is_payment_value_outlier,
    op.is_amount_coherent

FROM clean_order_payments op
JOIN clean_orders o ON op.order_id = o.order_id;

ALTER TABLE fact_payments ADD PRIMARY KEY (order_id, payment_sequential);
ALTER TABLE fact_payments ADD FOREIGN KEY (customer_id) REFERENCES dim_customers (customer_id);
ALTER TABLE fact_payments ADD FOREIGN KEY (purchase_date_key) REFERENCES dim_dates (date_key);


-- ============================================================================
-- FACT_REVIEWS
-- ============================================================================
-- Grain: one row per review (review_id + order_id — review_id alone is not
-- reliable as a key, see cleaning notes on has_shared_review_id).

CREATE TABLE fact_reviews AS
SELECT
    r.review_id,
    r.order_id,

    o.customer_id,
    TO_CHAR(o.order_purchase_timestamp::DATE, 'YYYYMMDD')::INT AS purchase_date_key,
    TO_CHAR(r.review_creation_date::DATE, 'YYYYMMDD')::INT     AS review_date_key,

    r.review_score,
    r.review_comment_title,
    r.review_comment_message,
    r.review_creation_date,
    r.review_answer_timestamp,
    r.review_response_time_hours,
    r.has_shared_review_id,
    r.has_multiple_reviews,
    r.is_review_date_coherent

FROM clean_order_reviews r
JOIN clean_orders o ON r.order_id = o.order_id;

ALTER TABLE fact_reviews ADD PRIMARY KEY (review_id, order_id);
ALTER TABLE fact_reviews ADD FOREIGN KEY (customer_id) REFERENCES dim_customers (customer_id);
ALTER TABLE fact_reviews ADD FOREIGN KEY (purchase_date_key) REFERENCES dim_dates (date_key);
ALTER TABLE fact_reviews ADD FOREIGN KEY (review_date_key) REFERENCES dim_dates (date_key);


-- ============================================================================
-- QUICK SANITY CHECKS
-- ============================================================================

SELECT COUNT(*) FROM dim_customers;
SELECT COUNT(*) FROM dim_sellers;
SELECT COUNT(*) FROM dim_products;
SELECT COUNT(*) FROM dim_dates;
SELECT COUNT(*) FROM fact_shipments;   -- expected to match clean_order_items row count
SELECT COUNT(*) FROM fact_payments;    -- expected to match clean_order_payments row count
SELECT COUNT(*) FROM fact_reviews;     -- expected to match clean_order_reviews row count


-- ============================================================================
-- END OF STAR SCHEMA BUILD
-- Next: KPI engineering — fct_logistics_kpis and fct_vendor_score, built on
-- top of fact_shipments / fact_payments / fact_reviews.
-- ============================================================================

SELECT COUNT(*) FROM dim_customers;
SELECT COUNT(*) FROM dim_sellers;
SELECT COUNT(*) FROM dim_products;
SELECT COUNT(*) FROM dim_dates;
SELECT COUNT(*) FROM fact_shipments;   -- expected to match clean_order_items row count
SELECT COUNT(*) FROM fact_payments;    -- expected to match clean_order_payments row count
SELECT COUNT(*) FROM fact_reviews; 