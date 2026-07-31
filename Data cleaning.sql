-- ============================================================================
-- IVOIRE PROJECT - Supply Chain & Seller Intelligence System
-- Data Cleaning Pipeline | Olist Brazilian E-Commerce Dataset
-- ============================================================================
-- Cleaning order follows table dependencies to allow cross-table validation:
--   Level 0 (reference)  : product_category_name_translation, geolocation
--   Level 1 (dimensions) : customers, sellers, products
--   Level 2 (pivot)      : orders
--   Level 3 (fact)       : order_items, order_payments, order_reviews
-- ============================================================================

-- ============================================================================
-- 1. INITIAL EXPLORATION
-- ============================================================================

SELECT COUNT(*) FROM raw_customers;                              -- 99441
SELECT COUNT(*) FROM raw_geolocation;                             -- 1000163
SELECT COUNT(*) FROM raw_order_items;                             -- 112650
SELECT COUNT(*) FROM raw_order_payments;                          -- 103886
SELECT COUNT(*) FROM raw_order_reviews;                           -- 99224
SELECT COUNT(*) FROM raw_orders;                                  -- 99441
SELECT COUNT(*) FROM raw_product_category_name_translation;       -- 71
SELECT COUNT(*) FROM raw_products;                                -- 32951
SELECT COUNT(*) FROM raw_sellers;                                 -- 3095

SELECT table_name, COUNT(*) AS column_count
FROM information_schema.columns
WHERE table_name IN (
    'raw_customers', 'raw_geolocation', 'raw_order_items',
    'raw_order_payments', 'raw_order_reviews', 'raw_orders',
    'raw_product_category_name_translation', 'raw_products', 'raw_sellers'
)
GROUP BY table_name
ORDER BY table_name;

SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name IN (
    'raw_customers', 'raw_geolocation', 'raw_order_items',
    'raw_order_payments', 'raw_order_reviews', 'raw_orders',
    'raw_product_category_name_translation', 'raw_products', 'raw_sellers'
)
ORDER BY table_name;


-- ============================================================================
-- 2. DATA CLEANING SETUP
-- ============================================================================
-- Working copies preserve the raw tables untouched for auditability.

CREATE TABLE clean_customers AS SELECT * FROM raw_customers;
CREATE TABLE clean_geolocation AS SELECT * FROM raw_geolocation;
CREATE TABLE clean_order_items AS SELECT * FROM raw_order_items;
CREATE TABLE clean_order_payments AS SELECT * FROM raw_order_payments;
CREATE TABLE clean_order_reviews AS SELECT * FROM raw_order_reviews;
CREATE TABLE clean_orders AS SELECT * FROM raw_orders;
CREATE TABLE clean_product_category_name_translation AS SELECT * FROM raw_product_category_name_translation;
CREATE TABLE clean_products AS SELECT * FROM raw_products;
CREATE TABLE clean_sellers AS SELECT * FROM raw_sellers;


-- ============================================================================
-- 2.1 PRODUCT_CATEGORY_NAME_TRANSLATION
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE product_category_name IS NULL) AS null_name_pt,
    COUNT(*) FILTER (WHERE product_category_name_english IS NULL) AS null_name_en
FROM clean_product_category_name_translation;

-- Uniqueness on the join key used by clean_products
SELECT product_category_name, COUNT(*)
FROM clean_product_category_name_translation
GROUP BY product_category_name
HAVING COUNT(*) > 1;

-- Whitespace check
SELECT product_category_name
FROM clean_product_category_name_translation
WHERE product_category_name != TRIM(product_category_name);

-- Naming convention check (snake_case expected)
SELECT product_category_name, product_category_name_english
FROM clean_product_category_name_translation
ORDER BY product_category_name;


-- ============================================================================
-- 2.2 GEOLOCATION
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE geolocation_zip_code_prefix IS NULL) AS null_zip,
    COUNT(*) FILTER (WHERE geolocation_lat IS NULL) AS null_lat,
    COUNT(*) FILTER (WHERE geolocation_lng IS NULL) AS null_lng,
    COUNT(*) FILTER (WHERE geolocation_city IS NULL) AS null_city,
    COUNT(*) FILTER (WHERE geolocation_state IS NULL) AS null_state
FROM clean_geolocation;

-- Exact duplicates on (zip, lat, lng) — flagged rather than deleted to preserve raw signal
ALTER TABLE clean_geolocation ADD COLUMN is_not_duplicate BOOLEAN;
UPDATE clean_geolocation SET is_not_duplicate = false;

WITH ranked_rows AS (
    SELECT
        ctid,
        ROW_NUMBER() OVER (
            PARTITION BY geolocation_zip_code_prefix, geolocation_lat, geolocation_lng
            ORDER BY ctid
        ) AS rn
    FROM clean_geolocation
)
UPDATE clean_geolocation
SET is_not_duplicate = (ranked_rows.rn = 1)
FROM ranked_rows
WHERE clean_geolocation.ctid = ranked_rows.ctid;

-- Whitespace normalization
UPDATE clean_geolocation SET geolocation_city = TRIM(geolocation_city);
-- state column confirmed clean on trim, no update required

-- Text casing normalization
UPDATE clean_geolocation SET geolocation_city = INITCAP(geolocation_city);
UPDATE clean_geolocation SET geolocation_state = UPPER(geolocation_state);

-- State code validation against the 27 official Brazilian codes
SELECT *
FROM clean_geolocation
WHERE geolocation_state NOT IN (
    'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA',
    'MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN',
    'RS','RO','RR','SC','SP','SE','TO'
);

-- City name consistency per zip prefix — majority-vote reference (frequency-based, no external lookup)
ALTER TABLE clean_geolocation ADD COLUMN is_city_valid BOOLEAN;
UPDATE clean_geolocation SET is_city_valid = true;

WITH majority_city AS (
    SELECT geolocation_zip_code_prefix, geolocation_city
    FROM (
        SELECT
            geolocation_zip_code_prefix,
            geolocation_city,
            ROW_NUMBER() OVER (
                PARTITION BY geolocation_zip_code_prefix
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM clean_geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_city
    ) ranked
    WHERE rn = 1
)
UPDATE clean_geolocation
SET is_city_valid = false
FROM majority_city
WHERE clean_geolocation.geolocation_zip_code_prefix = majority_city.geolocation_zip_code_prefix
  AND clean_geolocation.geolocation_city != majority_city.geolocation_city;
-- Decision: ~25k flagged rows are majority accent-only variants of "Sao Paulo" — kept
-- flagged, not corrected, given the volume (>1M rows) makes manual mapping unreliable.

-- Coordinate sanity check — bounding box wider than Brazil's actual borders to catch
-- only unambiguous outliers (confirmed: max longitude ~121 falls in Asia)
SELECT *
FROM clean_geolocation
WHERE geolocation_lat < -35 OR geolocation_lat > 6
   OR geolocation_lng < -75 OR geolocation_lng > -35;

ALTER TABLE clean_geolocation ADD COLUMN valid_coordinates BOOLEAN;
UPDATE clean_geolocation SET valid_coordinates = true;
UPDATE clean_geolocation
SET valid_coordinates = false
WHERE geolocation_lat < -35 OR geolocation_lat > 6
   OR geolocation_lng < -75 OR geolocation_lng > -35;

-- Zip prefix associated with multiple distinct cities (expected pre-cleaning signal)
SELECT geolocation_zip_code_prefix, COUNT(DISTINCT geolocation_city)
FROM clean_geolocation
GROUP BY geolocation_zip_code_prefix
HAVING COUNT(DISTINCT geolocation_city) > 1;


-- ============================================================================
-- 2.3 CUSTOMERS (Level 1)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS null_customer_id,
    COUNT(*) FILTER (WHERE customer_unique_id IS NULL) AS null_unique_id,
    COUNT(*) FILTER (WHERE customer_zip_code_prefix IS NULL) AS null_zip,
    COUNT(*) FILTER (WHERE customer_city IS NULL) AS null_city,
    COUNT(*) FILTER (WHERE customer_state IS NULL) AS null_state
FROM clean_customers;
-- Result: no nulls

-- customer_id is order-scoped, customer_unique_id is person-scoped — confirmed via
-- duplicate check (customer_id unique, customer_unique_id repeats across orders)
SELECT customer_id, COUNT(*)
FROM clean_customers
GROUP BY customer_id
HAVING COUNT(*) > 1;

SELECT customer_unique_id, COUNT(*)
FROM clean_customers
GROUP BY customer_unique_id
HAVING COUNT(*) > 1;

-- Identifier length checks
SELECT customer_id FROM clean_customers WHERE LENGTH(customer_id) != 32;
SELECT customer_unique_id FROM clean_customers WHERE LENGTH(customer_unique_id) != 32;
SELECT customer_zip_code_prefix FROM clean_customers WHERE LENGTH(customer_zip_code_prefix) != 5;

-- Whitespace normalization
UPDATE clean_customers SET customer_city = TRIM(customer_city);
-- state column confirmed clean on trim, no update required

-- Text casing normalization
UPDATE clean_customers SET customer_city = INITCAP(customer_city);
UPDATE clean_customers SET customer_state = UPPER(customer_state);

-- State code validation
SELECT *
FROM clean_customers
WHERE customer_state NOT IN (
    'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA',
    'MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN',
    'RS','RO','RR','SC','SP','SE','TO'
);

-- Referential coverage vs geolocation — flags customer zips absent from the geo reference
ALTER TABLE clean_customers ADD COLUMN zip_in_geolocation BOOLEAN;
UPDATE clean_customers SET zip_in_geolocation = true;

UPDATE clean_customers c
SET zip_in_geolocation = false
FROM (
    SELECT c2.customer_id
    FROM clean_customers c2
    LEFT JOIN clean_geolocation g ON c2.customer_zip_code_prefix = g.geolocation_zip_code_prefix
    WHERE g.geolocation_zip_code_prefix IS NULL
) missing_zips
WHERE c.customer_id = missing_zips.customer_id;
-- Result: 278 zips have no match in geolocation

-- City consistency vs geolocation majority-vote reference (same method as geolocation step)
ALTER TABLE clean_customers ADD COLUMN is_city_valid BOOLEAN;
UPDATE clean_customers SET is_city_valid = true;

WITH majority_city AS (
    SELECT geolocation_zip_code_prefix, geolocation_city
    FROM (
        SELECT
            geolocation_zip_code_prefix,
            geolocation_city,
            ROW_NUMBER() OVER (
                PARTITION BY geolocation_zip_code_prefix
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM clean_geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_city
    ) ranked
    WHERE rn = 1
)
UPDATE clean_customers
SET is_city_valid = false
FROM majority_city
WHERE clean_customers.customer_zip_code_prefix = majority_city.geolocation_zip_code_prefix
  AND clean_customers.customer_city != majority_city.geolocation_city;
-- Result: 251 rows flagged (0.25% of table), mostly accent variants on small municipalities.
-- Decision: kept flagged, not corrected — consistent with the geolocation decision, and safer
-- than guessing exact accentuation on ~80 low-volume Brazilian towns without a verified source.

SELECT COUNT(*) FROM clean_customers WHERE is_city_valid = false;

SELECT customer_city, COUNT(*)
FROM clean_customers
WHERE is_city_valid = false
GROUP BY customer_city
ORDER BY COUNT(*) DESC;


-- ============================================================================
-- 2.4 SELLERS (Level 1)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE seller_id IS NULL) AS null_seller_id,
    COUNT(*) FILTER (WHERE seller_zip_code_prefix IS NULL) AS null_zip,
    COUNT(*) FILTER (WHERE seller_city IS NULL) AS null_city,
    COUNT(*) FILTER (WHERE seller_state IS NULL) AS null_state
FROM clean_sellers;
-- Result: no nulls

-- Primary key uniqueness
SELECT seller_id, COUNT(*)
FROM clean_sellers
GROUP BY seller_id
HAVING COUNT(*) > 1;
-- Result: no duplicates

-- Identifier length checks
SELECT seller_id FROM clean_sellers WHERE LENGTH(seller_id) != 32;
SELECT seller_zip_code_prefix FROM clean_sellers WHERE LENGTH(seller_zip_code_prefix) != 5;

-- Whitespace normalization
UPDATE clean_sellers SET seller_city = TRIM(seller_city);
-- state column confirmed clean on trim, no update required

-- Text casing normalization
UPDATE clean_sellers SET seller_city = INITCAP(seller_city);
UPDATE clean_sellers SET seller_state = UPPER(seller_state);

-- State code validation
SELECT *
FROM clean_sellers
WHERE seller_state NOT IN (
    'AC','AL','AP','AM','BA','CE','DF','ES','GO','MA',
    'MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN',
    'RS','RO','RR','SC','SP','SE','TO'
);

-- City consistency vs geolocation majority-vote reference
ALTER TABLE clean_sellers ADD COLUMN is_city_valid BOOLEAN;
UPDATE clean_sellers SET is_city_valid = true;

WITH majority_city AS (
    SELECT geolocation_zip_code_prefix, geolocation_city
    FROM (
        SELECT
            geolocation_zip_code_prefix,
            geolocation_city,
            ROW_NUMBER() OVER (
                PARTITION BY geolocation_zip_code_prefix
                ORDER BY COUNT(*) DESC
            ) AS rn
        FROM clean_geolocation
        GROUP BY geolocation_zip_code_prefix, geolocation_city
    ) ranked
    WHERE rn = 1
)
UPDATE clean_sellers
SET is_city_valid = false
FROM majority_city
WHERE clean_sellers.seller_zip_code_prefix = majority_city.geolocation_zip_code_prefix
  AND clean_sellers.seller_city != majority_city.geolocation_city;

SELECT seller_city, COUNT(*)
FROM clean_sellers
WHERE is_city_valid = false
GROUP BY seller_city
ORDER BY COUNT(*) DESC;

-- Manual correction mapping — volume here (3095 rows) is low enough to inspect and
-- correct confidently, unlike geolocation/customers. Only unambiguous typos/variants
-- are mapped; two-city-in-one-field and unidentifiable entries are left flagged.
CREATE TEMP TABLE city_corrections (
    wrong_value   VARCHAR(60),
    correct_value VARCHAR(60)
);

INSERT INTO city_corrections VALUES
    -- Sao Paulo (city) - spelling/formatting variants
    ('Sao Paulo Sp', 'Sao Paulo'),
    ('Sao Pauo', 'Sao Paulo'),
    ('Sp / Sp', 'Sao Paulo'),
    ('Sao Paulo / Sao Paulo', 'Sao Paulo'),
    ('Sao Paulop', 'Sao Paulo'),
    ('Sao Paulo - Sp', 'Sao Paulo'),
    ('SãO Paulo', 'Sao Paulo'),
    ('Sao  Paulo', 'Sao Paulo'),
    ('Sao Paluo', 'Sao Paulo'),
    ('Pirituba', 'Sao Paulo'),                          -- district within Sao Paulo city
    -- Guarulhos
    ('Garulhos', 'Guarulhos'),
    -- Ferraz de Vasconcelos
    ('Ferraz De  Vasconcelos', 'Ferraz De Vasconcelos'),
    -- Mogi Das Cruzes
    ('Mogi Das Cruses', 'Mogi Das Cruzes'),
    ('Mogi Das Cruzes / Sp', 'Mogi Das Cruzes'),
    -- Santo Andre
    ('Sando Andre', 'Santo Andre'),
    -- Sao Bernardo Do Campo
    ('Ao Bernardo Do Campo', 'Sao Bernardo Do Campo'),
    ('Sao Bernardo Do Capo', 'Sao Bernardo Do Campo'),
    ('Sbc/Sp', 'Sao Bernardo Do Campo'),
    ('Sbc', 'Sao Bernardo Do Campo'),
    -- Santa Barbara D'Oeste
    ('Santa Barbara D´Oeste', 'Santa Barbara D''Oeste'),
    ('Santa Barbara D Oeste', 'Santa Barbara D''Oeste'),
    -- Porto Ferreira
    ('Portoferreira', 'Porto Ferreira'),
    -- Sao Jose Do Rio Pardo
    ('Scao Jose Do Rio Pardo', 'Sao Jose Do Rio Pardo'),
    -- Sao Sebastiao Da Grama
    ('Sao Sebastiao Da Grama/Sp', 'Sao Sebastiao Da Grama'),
    -- Ribeirao Preto
    ('Ribeirao Pretp', 'Ribeirao Preto'),
    ('Robeirao Preto', 'Ribeirao Preto'),
    ('Ribeirao Preto / Sao Paulo', 'Ribeirao Preto'),
    ('Riberao Preto', 'Ribeirao Preto'),
    -- Sao Jose Do Rio Preto
    ('S Jose Do Rio Preto', 'Sao Jose Do Rio Preto'),
    ('Sao Jose Do Rio Pret', 'Sao Jose Do Rio Preto'),
    -- Auriflama
    ('Auriflama/Sp', 'Auriflama'),
    -- Rio de Janeiro
    ('Rio De Janeiro / Rio De Janeiro', 'Rio De Janeiro'),
    ('Rio De Janeiro \Rio De Janeiro', 'Rio De Janeiro'),
    ('Rio De Janeiro, Rio De Janeiro, Brasil', 'Rio De Janeiro'),
    -- Angra Dos Reis
    ('Angra Dos Reis Rj', 'Angra Dos Reis'),
    -- Cariacica
    ('Cariacica / Es', 'Cariacica'),
    -- Belo Horizonte
    ('Belo Horizont', 'Belo Horizonte'),
    -- Barbacena
    ('Barbacena/ Minas Gerais', 'Barbacena'),
    -- Juazeiro Do Norte
    ('Juzeiro Do Norte', 'Juazeiro Do Norte'),
    -- Aguas Claras / Brasilia
    ('Aguas Claras Df', 'Aguas Claras'),
    ('Brasilia Df', 'Brasilia'),
    -- Sao Jose Dos Pinhais
    ('Sao Jose Dos Pinhas', 'Sao Jose Dos Pinhais'),
    ('Sao  Jose Dos Pinhais', 'Sao Jose Dos Pinhais'),
    -- Pinhais
    ('Pinhais/Pr', 'Pinhais'),
    -- Cascavel
    ('Cascavael', 'Cascavel'),
    -- Andira
    ('Andira-Pr', 'Andira'),
    -- Paicandu
    ('Paincandu', 'Paicandu'),
    -- Florianopolis
    ('Floranopolis', 'Florianopolis'),
    -- Balneario Camboriu
    ('Balenario Camboriu', 'Balneario Camboriu'),
    -- Lages
    ('Lages - Sc', 'Lages'),
    -- Novo Hamburgo
    ('Novo Hamburgo, Rio Grande Do Sul, Brasil', 'Novo Hamburgo');

UPDATE clean_sellers
SET seller_city = city_corrections.correct_value
FROM city_corrections
WHERE clean_sellers.seller_city = city_corrections.wrong_value;

-- Remaining flagged rows (two-city-in-one-field cases, unidentified entries, corrupted
-- values such as an email address or a raw zip code in the city field) require manual
-- verification against seller/account records — left flagged for follow-up.


-- ============================================================================
-- 2.5 PRODUCTS (Level 1)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE product_id IS NULL) AS null_id,
    COUNT(*) FILTER (WHERE product_category_name IS NULL) AS null_category,
    COUNT(*) FILTER (WHERE product_name_lenght IS NULL) AS null_name_len,
    COUNT(*) FILTER (WHERE product_description_lenght IS NULL) AS null_desc_len,
    COUNT(*) FILTER (WHERE product_photos_qty IS NULL) AS null_photos,
    COUNT(*) FILTER (WHERE product_weight_g IS NULL) AS null_weight,
    COUNT(*) FILTER (WHERE product_length_cm IS NULL) AS null_length,
    COUNT(*) FILTER (WHERE product_height_cm IS NULL) AS null_height,
    COUNT(*) FILTER (WHERE product_width_cm IS NULL) AS null_width
FROM clean_products;
-- Note: product_name_lenght / product_description_lenght are misspelled in the
-- source schema itself ("lenght") — kept as-is to match the raw column names.

-- Primary key uniqueness
SELECT product_id, COUNT(*)
FROM clean_products
GROUP BY product_id
HAVING COUNT(*) > 1;

-- Identifier length check
SELECT product_id FROM clean_products WHERE LENGTH(product_id) != 32;

-- Whitespace normalization
UPDATE clean_products SET product_category_name = TRIM(product_category_name);

-- Flag: fully incomplete products — category AND all four dimensions missing together.
-- This is a distinct, non-recoverable data gap (~610 rows) with no lookup source
-- available; documented for the data team rather than corrected.
ALTER TABLE clean_products ADD COLUMN is_incomplete_product BOOLEAN;
UPDATE clean_products SET is_incomplete_product = false;

UPDATE clean_products
SET is_incomplete_product = true
WHERE product_category_name IS NULL
  AND product_weight_g IS NULL
  AND product_length_cm IS NULL
  AND product_height_cm IS NULL
  AND product_width_cm IS NULL;

-- Flag: category missing but dimensions present — a different gap than the above,
-- blocks category translation and category-level imputation specifically.
ALTER TABLE clean_products ADD COLUMN is_missing_category BOOLEAN;
UPDATE clean_products SET is_missing_category = false;

UPDATE clean_products
SET is_missing_category = true
WHERE product_category_name IS NULL
  AND product_weight_g IS NOT NULL;

-- Zero/negative values on physical dimensions (should never occur)
SELECT *
FROM clean_products
WHERE product_weight_g <= 0
   OR product_length_cm <= 0
   OR product_height_cm <= 0
   OR product_width_cm <= 0;

-- Referential check: product categories with no match in the translation table
ALTER TABLE clean_products ADD COLUMN is_category_valid BOOLEAN;
UPDATE clean_products SET is_category_valid = true;

UPDATE clean_products
SET is_category_valid = false
WHERE product_category_name IS NOT NULL
  AND product_category_name NOT IN (
      SELECT product_category_name FROM clean_product_category_name_translation
  );

SELECT * FROM clean_products WHERE is_category_valid = false;

-- Outlier detection on weight — IQR method (Tukey's fences, 1.5x coefficient)
ALTER TABLE clean_products ADD COLUMN is_weight_outlier BOOLEAN;
UPDATE clean_products SET is_weight_outlier = false;

WITH stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY product_weight_g) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY product_weight_g) AS q3
    FROM clean_products
    WHERE product_weight_g IS NOT NULL
)
UPDATE clean_products
SET is_weight_outlier = true
FROM stats
WHERE clean_products.product_weight_g > stats.q3 + 1.5 * (stats.q3 - stats.q1)
   OR clean_products.product_weight_g < stats.q1 - 1.5 * (stats.q3 - stats.q1);


-- ============================================================================
-- 2.6 ORDERS (Level 2 - pivot table)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE order_id IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS null_customer_id,
    COUNT(*) FILTER (WHERE order_status IS NULL) AS null_status,
    COUNT(*) FILTER (WHERE order_purchase_timestamp IS NULL) AS null_purchase,
    COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS null_approved,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) AS null_carrier,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS null_delivered,
    COUNT(*) FILTER (WHERE order_estimated_delivery_date IS NULL) AS null_estimated
FROM clean_orders;
-- Result: null_approved=160, null_carrier=1783, null_delivered=2965 — expected,
-- driven by order_status (canceled/unavailable orders never reach these stages)

-- Primary key uniqueness
SELECT order_id, COUNT(*)
FROM clean_orders
GROUP BY order_id
HAVING COUNT(*) > 1;

-- Identifier length checks
SELECT order_id FROM clean_orders WHERE LENGTH(order_id) != 32;
SELECT customer_id FROM clean_orders WHERE LENGTH(customer_id) != 32;

-- Status value audit
SELECT order_status, COUNT(*)
FROM clean_orders
GROUP BY order_status
ORDER BY COUNT(*) DESC;

-- Nulls on key dates cross-checked against status — confirms nulls are status-driven,
-- not random data loss
SELECT
    order_status,
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NULL) AS null_delivered,
    COUNT(*) FILTER (WHERE order_approved_at IS NULL) AS null_approved,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NULL) AS null_carrier
FROM clean_orders
GROUP BY order_status
ORDER BY total DESC;

-- Flag: status says "delivered" but a required date is still missing — direct contradiction
ALTER TABLE clean_orders ADD COLUMN is_status_date_coherent BOOLEAN;
UPDATE clean_orders SET is_status_date_coherent = true;

UPDATE clean_orders
SET is_status_date_coherent = false
WHERE order_status = 'delivered'
  AND (order_approved_at IS NULL
       OR order_delivered_customer_date IS NULL
       OR order_delivered_carrier_date IS NULL);

-- Referential integrity vs customers
SELECT o.order_id
FROM clean_orders o
LEFT JOIN clean_customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- Chronological coherence across the order lifecycle timestamps
ALTER TABLE clean_orders ADD COLUMN is_date_coherent BOOLEAN;
UPDATE clean_orders SET is_date_coherent = true;

UPDATE clean_orders
SET is_date_coherent = false
WHERE (order_approved_at IS NOT NULL
       AND order_approved_at < order_purchase_timestamp)
   OR (order_delivered_carrier_date IS NOT NULL AND order_approved_at IS NOT NULL
       AND order_delivered_carrier_date < order_approved_at)
   OR (order_delivered_customer_date IS NOT NULL AND order_delivered_carrier_date IS NOT NULL
       AND order_delivered_customer_date < order_delivered_carrier_date)
   OR (order_delivered_customer_date IS NOT NULL
       AND order_delivered_customer_date < order_purchase_timestamp);

SELECT COUNT(*) FROM clean_orders WHERE is_date_coherent = false;
-- Result: 1382 rows

-- Breakdown by inconsistency type — isolates which pattern drives the total
SELECT
    COUNT(*) FILTER (WHERE order_approved_at IS NOT NULL
        AND order_approved_at < order_purchase_timestamp) AS approved_before_purchase,
    COUNT(*) FILTER (WHERE order_delivered_carrier_date IS NOT NULL AND order_approved_at IS NOT NULL
        AND order_delivered_carrier_date < order_approved_at) AS carrier_before_approved,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL AND order_delivered_carrier_date IS NOT NULL
        AND order_delivered_customer_date < order_delivered_carrier_date) AS delivered_before_carrier,
    COUNT(*) FILTER (WHERE order_delivered_customer_date IS NOT NULL
        AND order_delivered_customer_date < order_purchase_timestamp) AS delivered_before_purchase
FROM clean_orders;
-- Result: carrier_before_approved accounts for 1359 of the 1382 flagged rows —
-- investigated separately below rather than treated as a uniform error category.

SELECT
    MIN(order_approved_at - order_delivered_carrier_date) AS gap_min,
    MAX(order_approved_at - order_delivered_carrier_date) AS gap_max,
    AVG(order_approved_at - order_delivered_carrier_date) AS gap_avg
FROM clean_orders
WHERE order_delivered_carrier_date IS NOT NULL
  AND order_approved_at IS NOT NULL
  AND order_delivered_carrier_date < order_approved_at;

-- Flag: carrier pickup logged before formal approval — likely an administrative/system
-- delay in Olist's approval timestamp rather than a genuine data error
ALTER TABLE clean_orders ADD COLUMN carrier_before_approved BOOLEAN;
UPDATE clean_orders SET carrier_before_approved = false;

UPDATE clean_orders
SET carrier_before_approved = true
WHERE order_delivered_carrier_date IS NOT NULL
  AND order_approved_at IS NOT NULL
  AND order_delivered_carrier_date < order_approved_at;

-- Flag: customer delivery logged before carrier pickup — genuine logical inconsistency,
-- no plausible administrative explanation
ALTER TABLE clean_orders ADD COLUMN delivered_before_carrier BOOLEAN;
UPDATE clean_orders SET delivered_before_carrier = false;

UPDATE clean_orders
SET delivered_before_carrier = true
WHERE order_delivered_customer_date IS NOT NULL
  AND order_delivered_carrier_date IS NOT NULL
  AND order_delivered_customer_date < order_delivered_carrier_date;


-- ============================================================================
-- 2.7 ORDER_ITEMS (Level 3 - fact table)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE order_id IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE order_item_id IS NULL) AS null_item_id,
    COUNT(*) FILTER (WHERE product_id IS NULL) AS null_product_id,
    COUNT(*) FILTER (WHERE seller_id IS NULL) AS null_seller_id,
    COUNT(*) FILTER (WHERE shipping_limit_date IS NULL) AS null_shipping_limit,
    COUNT(*) FILTER (WHERE price IS NULL) AS null_price,
    COUNT(*) FILTER (WHERE freight_value IS NULL) AS null_freight
FROM clean_order_items;
-- Result: no nulls

-- Composite key uniqueness — order_id alone is not unique (multiple items per order)
SELECT order_id, order_item_id, COUNT(*)
FROM clean_order_items
GROUP BY order_id, order_item_id
HAVING COUNT(*) > 1;

-- Identifier length checks
SELECT order_id FROM clean_order_items WHERE LENGTH(order_id) != 32;
SELECT product_id FROM clean_order_items WHERE LENGTH(product_id) != 32;
SELECT seller_id FROM clean_order_items WHERE LENGTH(seller_id) != 32;

-- Referential integrity — three foreign keys to validate
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

-- Zero/negative values on price and freight
SELECT * FROM clean_order_items WHERE price <= 0 OR freight_value < 0;

-- Flag: shipping deadline set before the order was even placed
ALTER TABLE clean_order_items ADD COLUMN is_shipping_date_coherent BOOLEAN;
UPDATE clean_order_items SET is_shipping_date_coherent = true;

UPDATE clean_order_items oi
SET is_shipping_date_coherent = false
FROM clean_orders o
WHERE oi.order_id = o.order_id
  AND oi.shipping_limit_date < o.order_purchase_timestamp;

-- Outlier detection on price (IQR method)
ALTER TABLE clean_order_items ADD COLUMN is_price_outlier BOOLEAN;
UPDATE clean_order_items SET is_price_outlier = false;

WITH stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM clean_order_items
)
UPDATE clean_order_items
SET is_price_outlier = true
FROM stats
WHERE clean_order_items.price > stats.q3 + 1.5 * (stats.q3 - stats.q1)
   OR clean_order_items.price < stats.q1 - 1.5 * (stats.q3 - stats.q1);

-- Outlier detection on freight_value (same method)
ALTER TABLE clean_order_items ADD COLUMN is_freight_outlier BOOLEAN;
UPDATE clean_order_items SET is_freight_outlier = false;

WITH stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY freight_value) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY freight_value) AS q3
    FROM clean_order_items
)
UPDATE clean_order_items
SET is_freight_outlier = true
FROM stats
WHERE clean_order_items.freight_value > stats.q3 + 1.5 * (stats.q3 - stats.q1)
   OR clean_order_items.freight_value < stats.q1 - 1.5 * (stats.q3 - stats.q1);

-- Spot-check on the highest flagged prices to rule out obvious data-entry errors
SELECT price, freight_value, product_id
FROM clean_order_items
WHERE is_price_outlier = true
ORDER BY price DESC
LIMIT 20;


-- ============================================================================
-- 2.8 ORDER_PAYMENTS (Level 3 - fact table)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE order_id IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE payment_sequential IS NULL) AS null_sequential,
    COUNT(*) FILTER (WHERE payment_type IS NULL) AS null_type,
    COUNT(*) FILTER (WHERE payment_installments IS NULL) AS null_installments,
    COUNT(*) FILTER (WHERE payment_value IS NULL) AS null_value
FROM clean_order_payments;

-- Composite key uniqueness — order_id alone is not unique (multiple payments per order)
SELECT order_id, payment_sequential, COUNT(*)
FROM clean_order_payments
GROUP BY order_id, payment_sequential
HAVING COUNT(*) > 1;

-- Identifier length check
SELECT order_id FROM clean_order_payments WHERE LENGTH(order_id) != 32;

-- Referential integrity vs orders
SELECT op.order_id
FROM clean_order_payments op
LEFT JOIN clean_orders o ON op.order_id = o.order_id
WHERE o.order_id IS NULL;

-- Payment type audit
SELECT payment_type, COUNT(*)
FROM clean_order_payments
GROUP BY payment_type
ORDER BY COUNT(*) DESC;

-- Zero/negative values on payment amount and installment count
SELECT * FROM clean_order_payments WHERE payment_value <= 0 OR payment_installments <= 0;
-- Result: 11 rows — negligible volume, flagged without further investigation

ALTER TABLE clean_order_payments ADD COLUMN is_payment_valid BOOLEAN;
UPDATE clean_order_payments SET is_payment_valid = true;

UPDATE clean_order_payments
SET is_payment_valid = false
WHERE payment_value <= 0 OR payment_installments <= 0;

-- Outlier detection on payment_value (IQR method)
ALTER TABLE clean_order_payments ADD COLUMN is_payment_value_outlier BOOLEAN;
UPDATE clean_order_payments SET is_payment_value_outlier = false;

WITH stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY payment_value) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY payment_value) AS q3
    FROM clean_order_payments
)
UPDATE clean_order_payments
SET is_payment_value_outlier = true
FROM stats
WHERE clean_order_payments.payment_value > stats.q3 + 1.5 * (stats.q3 - stats.q1)
   OR clean_order_payments.payment_value < stats.q1 - 1.5 * (stats.q3 - stats.q1);

-- Cross-check: total paid per order vs total order value (price + freight from order_items).
-- Each side is pre-aggregated to order-level BEFORE joining, to avoid a fan-out
-- (an order with multiple items AND multiple payments would otherwise inflate both
-- sums via the row-multiplication of a direct join).
WITH payments_total AS (
    SELECT order_id, SUM(payment_value) AS total_paid
    FROM clean_order_payments
    GROUP BY order_id
),
items_total AS (
    SELECT order_id, SUM(price + freight_value) AS total_order_value
    FROM clean_order_items
    GROUP BY order_id
)
SELECT
    pt.order_id,
    pt.total_paid,
    it.total_order_value,
    ROUND(pt.total_paid - it.total_order_value, 2) AS gap
FROM payments_total pt
JOIN items_total it ON pt.order_id = it.order_id
WHERE ROUND(pt.total_paid, 2) != ROUND(it.total_order_value, 2)
ORDER BY ABS(pt.total_paid - it.total_order_value) DESC;
-- Result: 576 rows (0.6% of orders) — over half differ by 1-2 cents, consistent with
-- rounding on installment splits rather than a genuine payment discrepancy.

ALTER TABLE clean_order_payments ADD COLUMN is_amount_coherent BOOLEAN;
UPDATE clean_order_payments SET is_amount_coherent = true;

WITH payments_total AS (
    SELECT order_id, SUM(payment_value) AS total_paid
    FROM clean_order_payments
    GROUP BY order_id
),
items_total AS (
    SELECT order_id, SUM(price + freight_value) AS total_order_value
    FROM clean_order_items
    GROUP BY order_id
),
mismatched AS (
    SELECT pt.order_id
    FROM payments_total pt
    JOIN items_total it ON pt.order_id = it.order_id
    WHERE ROUND(pt.total_paid, 2) != ROUND(it.total_order_value, 2)
)
UPDATE clean_order_payments op
SET is_amount_coherent = false
FROM mismatched m
WHERE op.order_id = m.order_id;


-- ============================================================================
-- 2.9 ORDER_REVIEWS (Level 3 - fact table)
-- ============================================================================

-- Null audit
SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE review_id IS NULL) AS null_review_id,
    COUNT(*) FILTER (WHERE order_id IS NULL) AS null_order_id,
    COUNT(*) FILTER (WHERE review_score IS NULL) AS null_score,
    COUNT(*) FILTER (WHERE review_comment_title IS NULL) AS null_title,
    COUNT(*) FILTER (WHERE review_comment_message IS NULL) AS null_message,
    COUNT(*) FILTER (WHERE review_creation_date IS NULL) AS null_creation,
    COUNT(*) FILTER (WHERE review_answer_timestamp IS NULL) AS null_answer
FROM clean_order_reviews;
-- Note: high null counts on title/message are expected — most customers rate without commenting.

-- review_id uniqueness check — result: 789 review_id values are duplicated
SELECT review_id, COUNT(*)
FROM clean_order_reviews
GROUP BY review_id
HAVING COUNT(*) > 1;

-- Root-cause check: same review_id linked to different order_id values (not exact
-- duplicate rows) — confirms review_id cannot serve as a reliable primary key
SELECT review_id, order_id, COUNT(*)
FROM clean_order_reviews
GROUP BY review_id, order_id
HAVING COUNT(*) > 1;
-- Result: 0 rows — (review_id, order_id) is a valid composite key

ALTER TABLE clean_order_reviews ADD COLUMN has_shared_review_id BOOLEAN;
UPDATE clean_order_reviews SET has_shared_review_id = false;

UPDATE clean_order_reviews
SET has_shared_review_id = true
WHERE review_id IN (
    SELECT review_id
    FROM clean_order_reviews
    GROUP BY review_id
    HAVING COUNT(DISTINCT order_id) > 1
);
-- Downstream impact: use (review_id, order_id) as the join key for this table,
-- never review_id alone.

-- order_id duplication check — a customer can submit more than one review per order
-- (e.g. an update after seller response); distinct creation dates confirm legitimate repeats
SELECT order_id, COUNT(*)
FROM clean_order_reviews
GROUP BY order_id
HAVING COUNT(*) > 1;
-- Result: 547 orders with multiple reviews

ALTER TABLE clean_order_reviews ADD COLUMN has_multiple_reviews BOOLEAN;
UPDATE clean_order_reviews SET has_multiple_reviews = false;

UPDATE clean_order_reviews
SET has_multiple_reviews = true
WHERE order_id IN (
    SELECT order_id
    FROM clean_order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
);

-- Identifier length checks
SELECT review_id FROM clean_order_reviews WHERE LENGTH(review_id) != 32;
SELECT order_id FROM clean_order_reviews WHERE LENGTH(order_id) != 32;

-- Referential integrity vs orders
SELECT r.order_id
FROM clean_order_reviews r
LEFT JOIN clean_orders o ON r.order_id = o.order_id
WHERE o.order_id IS NULL;

-- Review score range check (expected 1-5)
SELECT review_score, COUNT(*)
FROM clean_order_reviews
GROUP BY review_score
ORDER BY review_score;

-- Chronological coherence: answer timestamp must follow the review creation date
ALTER TABLE clean_order_reviews ADD COLUMN is_review_date_coherent BOOLEAN;
UPDATE clean_order_reviews SET is_review_date_coherent = true;

UPDATE clean_order_reviews
SET is_review_date_coherent = false
WHERE review_answer_timestamp < review_creation_date;

-- Whitespace normalization on free-text fields (null-safe)
UPDATE clean_order_reviews
SET review_comment_title = TRIM(review_comment_title)
WHERE review_comment_title IS NOT NULL;

UPDATE clean_order_reviews
SET review_comment_message = TRIM(review_comment_message)
WHERE review_comment_message IS NOT NULL;


-- ============================================================================
-- END OF DATA CLEANING PASS
-- Next: cross-table join validation pass (e.g. orphaned product categories),
-- then feature engineering (delivery_time_days, delay_days, is_late, freight_ratio).
-- ============================================================================