--------------
-- Feature engineering
--------------

-- Adding columns to the orders table

SELECT * FROM clean_orders;

ALTER TABLE clean_orders
ADD COLUMN delivery_time_days INTERVAL; -- entre l'achat et la livraison client

UPDATE clean_orders
SET delivery_time_days = order_delivered_customer_date - order_purchase_timestamp;

ALTER TABLE clean_orders
ADD COLUMN delay_days  INTERVAL; -- entre livraison réelle et estimée

UPDATE clean_orders
SET delay_days = order_delivered_customer_date - order_estimated_delivery_date;

ALTER TABLE clean_orders
ADD COLUMN delay_days  INTERVAL; -- entre livraison réelle et estimée

UPDATE clean_orders
SET delay_days = order_delivered_customer_date - order_estimated_delivery_date;

ALTER TABLE clean_orders
ADD COLUMN is_late  BOOLEAN;

UPDATE clean_orders
SET is_late = true
WHERE delay_days > INTERVAL '0 day'
	AND order_delivered_customer_date IS NOT NULL;

ALTER TABLE clean_orders
ADD COLUMN approval)  INTERVAL; -- entre livraison réelle et estimée

UPDATE clean_orders
SET delay_days = order_delivered_customer_date - order_estimated_delivery_date;

-- Adding columns to the order_items table

SELECT * FROM clean_order_items;

ALTER TABLE clean_order_items
ADD COLUMN total_line_cost NUMERIC(10,2);

UPDATE clean_order_items
SET total_line_cost = price + freight_value;

ALTER TABLE clean_order_items
ADD COLUMN freight_ratio NUMERIC(10,2);

UPDATE clean_order_items
SET freight_ratio = freight_value / price;