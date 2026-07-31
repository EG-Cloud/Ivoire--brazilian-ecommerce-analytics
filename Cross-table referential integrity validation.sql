-- ============================================================================
-- IVOIRE PROJECT - Cross-Table Referential Integrity Validation Pass
-- Run after all 9 tables have been individually cleaned (see
-- ivoire_data_cleaning.sql), and before feature engineering / star schema build.
-- ============================================================================
-- Method: LEFT JOIN + WHERE right_side IS NULL for every check.
-- A LEFT JOIN keeps every row from the left (child) table and attaches a match
-- from the right (parent) table when one exists. If no match exists, the
-- right-side columns come back NULL — that NULL is what WHERE ... IS NULL
-- isolates: it flags the orphaned rows with no valid parent.
-- Every check below is expected to return 0 rows on this dataset unless noted.
-- ============================================================================


-- ============================================================================
-- 1. ORDERS -> CUSTOMERS
-- ============================================================================
-- Every order must reference an existing customer.

SELECT o.order_id, o.customer_id
FROM clean_orders o
LEFT JOIN clean_customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;


-- ============================================================================
-- 2. ORDER_ITEMS -> ORDERS / PRODUCTS / SELLERS
-- ============================================================================
-- Every order item must reference an existing order, product, and seller.

SELECT oi.order_id
FROM clean_order_items oi
LEFT JOIN clean_orders o ON oi.order_id = o.order_id
WHERE o.order_id IS NULL;

SELECT oi.product_id
FROM clean_order_items oi
LEFT JOIN clean_products p ON oi.product_id = p.product_id
WHERE p.product_id IS NULL;

SELECT oi.seller_id
FROM clean_order_items oi
LEFT JOIN clean_sellers s ON oi.seller_id = s.seller_id
WHERE s.seller_id IS NULL;


-- ============================================================================
-- 3. ORDER_PAYMENTS -> ORDERS
-- ============================================================================
-- Every payment must reference an existing order.

SELECT op.order_id
FROM clean_order_payments op
LEFT JOIN clean_orders o ON op.order_id = o.order_id
WHERE o.order_id IS NULL;


-- ============================================================================
-- 4. ORDER_REVIEWS -> ORDERS
-- ============================================================================
-- Every review must reference an existing order.

SELECT r.order_id
FROM clean_order_reviews r
LEFT JOIN clean_orders o ON r.order_id = o.order_id
WHERE o.order_id IS NULL;


-- ============================================================================
-- 5. CUSTOMERS -> GEOLOCATION
-- ============================================================================
-- Every customer zip prefix should exist in the geolocation reference table.
-- Result: 278 zip prefixes have no match (already flagged on clean_customers
-- via zip_in_geolocation during table-level cleaning).

SELECT c.customer_id, c.customer_zip_code_prefix
FROM clean_customers c
LEFT JOIN clean_geolocation g ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL;


-- ============================================================================
-- 6. SELLERS -> GEOLOCATION
-- ============================================================================
-- Every seller zip prefix should exist in the geolocation reference table.
-- Result: 7 zip prefixes have no match

SELECT s.seller_id, s.seller_zip_code_prefix
FROM clean_sellers s
LEFT JOIN clean_geolocation g ON s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL;


-- ============================================================================
-- 7. PRODUCTS -> PRODUCT_CATEGORY_NAME_TRANSLATION
-- ============================================================================
-- Every non-null product category should have a matching English translation.
-- Rows with a NULL category are excluded here — they're already tracked
-- separately via is_missing_category / is_incomplete_product on clean_products.
-- Results 13 rows there is no matching English translation

SELECT p.product_id, p.product_category_name
FROM clean_products p
LEFT JOIN clean_product_category_name_translation t
    ON p.product_category_name = t.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL;


-- ============================================================================
-- 8. SUMMARY — row counts for every check above
-- ============================================================================
-- Run this block to get a single-glance pass/fail overview instead of scrolling
-- through each individual result set.

SELECT 'orders_missing_customer' AS check_name, COUNT(*) AS orphan_count
FROM clean_orders o
LEFT JOIN clean_customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL

UNION ALL

SELECT 'order_items_missing_order', COUNT(*)
FROM clean_order_items oi
LEFT JOIN clean_orders o ON oi.order_id = o.order_id
WHERE o.order_id IS NULL

UNION ALL

SELECT 'order_items_missing_product', COUNT(*)
FROM clean_order_items oi
LEFT JOIN clean_products p ON oi.product_id = p.product_id
WHERE p.product_id IS NULL

UNION ALL

SELECT 'order_items_missing_seller', COUNT(*)
FROM clean_order_items oi
LEFT JOIN clean_sellers s ON oi.seller_id = s.seller_id
WHERE s.seller_id IS NULL

UNION ALL

SELECT 'order_payments_missing_order', COUNT(*)
FROM clean_order_payments op
LEFT JOIN clean_orders o ON op.order_id = o.order_id
WHERE o.order_id IS NULL

UNION ALL

SELECT 'order_reviews_missing_order', COUNT(*)
FROM clean_order_reviews r
LEFT JOIN clean_orders o ON r.order_id = o.order_id
WHERE o.order_id IS NULL

UNION ALL

SELECT 'customers_missing_geolocation', COUNT(*)
FROM clean_customers c
LEFT JOIN clean_geolocation g ON c.customer_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL

UNION ALL

SELECT 'sellers_missing_geolocation', COUNT(*)
FROM clean_sellers s
LEFT JOIN clean_geolocation g ON s.seller_zip_code_prefix = g.geolocation_zip_code_prefix
WHERE g.geolocation_zip_code_prefix IS NULL

UNION ALL

SELECT 'products_missing_category_translation', COUNT(*)
FROM clean_products p
LEFT JOIN clean_product_category_name_translation t
    ON p.product_category_name = t.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL

ORDER BY check_name;


-- ============================================================================
-- END OF REFERENTIAL INTEGRITY PASS
-- Expected known gaps: customers_missing_geolocation (278), sellers_missing_geolocation
-- (volume to confirm on run). All order-chain checks (orders/order_items/order_payments/
-- order_reviews) are expected to return 0 on this dataset.
-- Next: feature engineering — delivery_time_days, delay_days, is_late, freight_ratio,
-- cost_per_unit — then the star schema build (fact_shipments + dimensions).
-- ============================================================================