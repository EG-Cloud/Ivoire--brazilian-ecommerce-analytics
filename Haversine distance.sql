--------------------
---------- Seller-to-Customer Distance (Haversine)
--------------------
-- Tests whether geographic distance explains delivery delay. Coordinates
-- aren't stored directly on dim_customers/dim_sellers, so they're pulled
-- via a zip-prefix join to geolocation. Only rows with validated coordinates
-- (valid_coordinates = true) are used as the reference, consistent with the
-- flagging decision made during geolocation cleaning.
 
--------------------
---------- Step 1 — one lat/lng reference per zip prefix
--------------------
-- geolocation has multiple rows per zip prefix; averaging collapses each
-- prefix to a single coordinate pair.
 
CREATE TEMP TABLE temp_zipcodes AS
    SELECT
        geolocation_zip_code_prefix,
        AVG(geolocation_lat) AS lat,
        AVG(geolocation_lng) AS lng
    FROM clean_geolocation
    WHERE valid_coordinates = true
    GROUP BY 1;
 
--------------------
---------- Step 2 — attach coordinates to customers and sellers
--------------------
 
CREATE TEMP TABLE customer_coordinates AS
SELECT
    customer_id,
    customer_zip_code_prefix,
    tz.lat,
    tz.lng
FROM dim_customers dc
INNER JOIN temp_zipcodes tz
    ON dc.customer_zip_code_prefix = tz.geolocation_zip_code_prefix;
 
CREATE TEMP TABLE seller_coordinates AS
SELECT
    seller_id,
    seller_zip_code_prefix,
    tz.lat,
    tz.lng
FROM dim_sellers ds
INNER JOIN temp_zipcodes tz
    ON ds.seller_zip_code_prefix = tz.geolocation_zip_code_prefix;
 
--------------------
---------- Step 3 — Haversine distance per shipment
--------------------
-- Great-circle distance in km between seller and customer, using Earth's
-- mean radius (6371 km). Angles converted to radians as required by the
-- trig functions. Rows without a validated zip match on either side (see
-- zip_in_geolocation flags on dim_customers/dim_sellers) are silently
-- excluded by the INNER JOINs below.
 
CREATE TEMP TABLE temp_fact_table AS
SELECT
    f.order_id,
    f.customer_id,
    c.customer_zip_code_prefix,
    c.lat AS customer_lat,
    c.lng AS customer_lng,
    f.seller_id,
    s.seller_zip_code_prefix,
    s.lat AS seller_lat,
    s.lng AS seller_lng,
    f.delay_days,
    2 * 6371 * ASIN(
        SQRT(
            POWER(SIN(RADIANS(s.lat - c.lat) / 2), 2) +
            COS(RADIANS(c.lat)) * COS(RADIANS(s.lat)) *
            POWER(SIN(RADIANS(s.lng - c.lng) / 2), 2)
        )
    ) AS distance_km
FROM fact_shipments f
INNER JOIN customer_coordinates c ON f.customer_id = c.customer_id
INNER JOIN seller_coordinates s ON f.seller_id = s.seller_id;
 
--------------------
---------- Step 4 — correlation test: distance vs delay
--------------------
-- Result: -0.08 (negligible). Distance does not meaningfully explain
-- delivery delay on this dataset — kept for descriptive/mapping purposes
-- only, not pursued as a causal factor.
 
SELECT
    CORR(distance_km, EXTRACT(EPOCH FROM delay_days) / 86400)
FROM temp_fact_table
WHERE distance_km IS NOT NULL
  AND delay_days IS NOT NULL;