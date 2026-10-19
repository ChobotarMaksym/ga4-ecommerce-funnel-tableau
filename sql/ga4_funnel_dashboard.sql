-- GA4 e-commerce funnel: weekly, sequential, by device / country / acquisition source and medium.
-- Grain: one row per week x device x country x source x medium x funnel stage.
-- Counts are additive; rates (step CVR, cumulative CVR) are computed downstream (e.g. in Tableau).
-- To materialize this as a table, uncomment the line below and set your project/dataset.
-- CREATE OR REPLACE TABLE `your_project.your_dataset.ga4_funnel_dashboard` AS

WITH raw_events AS (
  SELECT
    -- event_date is stored as a STRING in YYYYMMDD format.
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    event_name,
    event_timestamp,
    user_pseudo_id,
    -- ga_session_id lives inside the event_params array.
    (
      SELECT MAX(event_param.value.int_value)
      FROM UNNEST(event_params) AS event_param
      WHERE event_param.key = 'ga_session_id'
    ) AS ga_session_id,
    COALESCE(NULLIF(TRIM(device.category), ''), '(not set)') AS device_category,
    COALESCE(NULLIF(TRIM(geo.country), ''), '(not set)') AS country,
    -- traffic_source describes the user's first acquisition touch in this dataset.
    -- Map the obfuscated placeholder values to readable labels.
    CASE
      WHEN traffic_source.source IS NULL OR TRIM(traffic_source.source) = '' THEN '(not set)'
      WHEN LOWER(TRIM(traffic_source.source)) = '<other>' THEN 'Other'
      WHEN LOWER(TRIM(traffic_source.source)) = '(data deleted)' THEN 'Unknown'
      ELSE TRIM(traffic_source.source)
    END AS acquisition_source,
    CASE
      WHEN traffic_source.medium IS NULL OR TRIM(traffic_source.medium) = '' THEN '(not set)'
      WHEN LOWER(TRIM(traffic_source.medium)) = '<other>' THEN 'Other'
      WHEN LOWER(TRIM(traffic_source.medium)) = '(data deleted)' THEN 'Unknown'
      ELSE TRIM(traffic_source.medium)
    END AS acquisition_medium,
    -- transaction_id only makes sense for purchase events; treat blanks/placeholders as missing.
    CASE
      WHEN event_name <> 'purchase' THEN NULL
      WHEN ecommerce.transaction_id IS NULL THEN NULL
      WHEN LOWER(TRIM(ecommerce.transaction_id)) IN ('', '(not set)', 'not set') THEN NULL
      ELSE TRIM(ecommerce.transaction_id)
    END AS transaction_id,
    CASE WHEN event_name = 'purchase' THEN ecommerce.purchase_revenue_in_usd END AS purchase_revenue_usd
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  -- 13 full Monday-to-Sunday weeks.
  WHERE _TABLE_SUFFIX BETWEEN '20201102' AND '20210131'
    AND event_name IN ('session_start', 'view_item', 'add_to_cart', 'begin_checkout', 'add_payment_info', 'purchase')
),

event_data AS (
  SELECT
    -- ga_session_id can repeat across users, so the session key combines both.
    CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING)) AS session_id,
    event_date, event_name, event_timestamp, device_category, country,
    acquisition_source, acquisition_medium, transaction_id, purchase_revenue_usd
  FROM raw_events
  WHERE user_pseudo_id IS NOT NULL AND ga_session_id IS NOT NULL
),

-- One row per session, dimensions taken at the session_start event.
session_base AS (
  SELECT
    session_id,
    MIN(event_timestamp) AS session_start_at,
    ARRAY_AGG(event_date ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS session_date,
    ARRAY_AGG(device_category ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS device_category,
    ARRAY_AGG(country ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS country,
    ARRAY_AGG(acquisition_source ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS acquisition_source,
    ARRAY_AGG(acquisition_medium ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS acquisition_medium
  FROM event_data
  WHERE event_name = 'session_start'
  GROUP BY session_id
),

-- A transaction can be logged more than once; rank by time and keep the first.
purchase_candidates AS (
  SELECT
    session_id, transaction_id, event_timestamp AS purchase_at, purchase_revenue_usd,
    ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY event_timestamp, session_id) AS transaction_rank
  FROM event_data
  WHERE event_name = 'purchase' AND transaction_id IS NOT NULL AND purchase_revenue_usd IS NOT NULL
),

deduplicated_transactions AS (
  SELECT session_id, transaction_id, purchase_at, purchase_revenue_usd
  FROM purchase_candidates
  WHERE transaction_rank = 1
),

-- A session can contain more than one order.
session_commerce AS (
  SELECT session_id, COUNT(*) AS order_count, SUM(purchase_revenue_usd) AS purchase_revenue_usd
  FROM deduplicated_transactions
  GROUP BY session_id
),

-- Each stage below only counts an event if it happened at or after the previous stage,
-- so the funnel is sequential rather than "any event present".
view_stage AS (
  SELECT session_base.session_id, session_base.session_start_at,
    MIN(event_data.event_timestamp) AS view_item_at
  FROM session_base
  LEFT JOIN event_data
    ON session_base.session_id = event_data.session_id
    AND event_data.event_name = 'view_item'
    AND event_data.event_timestamp >= session_base.session_start_at
  GROUP BY session_base.session_id, session_base.session_start_at
),

cart_stage AS (
  SELECT view_stage.session_id, view_stage.session_start_at, view_stage.view_item_at,
    MIN(event_data.event_timestamp) AS add_to_cart_at
  FROM view_stage
  LEFT JOIN event_data
    ON view_stage.session_id = event_data.session_id
    AND event_data.event_name = 'add_to_cart'
    AND event_data.event_timestamp >= view_stage.view_item_at
  GROUP BY view_stage.session_id, view_stage.session_start_at, view_stage.view_item_at
),

checkout_stage AS (
  SELECT cart_stage.session_id, cart_stage.session_start_at, cart_stage.view_item_at, cart_stage.add_to_cart_at,
    MIN(event_data.event_timestamp) AS begin_checkout_at
  FROM cart_stage
  LEFT JOIN event_data
    ON cart_stage.session_id = event_data.session_id
    AND event_data.event_name = 'begin_checkout'
    AND event_data.event_timestamp >= cart_stage.add_to_cart_at
  GROUP BY cart_stage.session_id, cart_stage.session_start_at, cart_stage.view_item_at, cart_stage.add_to_cart_at
),

payment_stage AS (
  SELECT checkout_stage.session_id, checkout_stage.session_start_at, checkout_stage.view_item_at,
    checkout_stage.add_to_cart_at, checkout_stage.begin_checkout_at,
    MIN(event_data.event_timestamp) AS add_payment_info_at
  FROM checkout_stage
  LEFT JOIN event_data
    ON checkout_stage.session_id = event_data.session_id
    AND event_data.event_name = 'add_payment_info'
    AND event_data.event_timestamp >= checkout_stage.begin_checkout_at
  GROUP BY checkout_stage.session_id, checkout_stage.session_start_at, checkout_stage.view_item_at,
    checkout_stage.add_to_cart_at, checkout_stage.begin_checkout_at
),

-- Purchase uses the deduplicated transactions, not the raw purchase events.
purchase_stage AS (
  SELECT payment_stage.session_id, payment_stage.session_start_at, payment_stage.view_item_at,
    payment_stage.add_to_cart_at, payment_stage.begin_checkout_at, payment_stage.add_payment_info_at,
    MIN(deduplicated_transactions.purchase_at) AS purchase_at
  FROM payment_stage
  LEFT JOIN deduplicated_transactions
    ON payment_stage.session_id = deduplicated_transactions.session_id
    AND deduplicated_transactions.purchase_at >= payment_stage.add_payment_info_at
  GROUP BY payment_stage.session_id, payment_stage.session_start_at, payment_stage.view_item_at,
    payment_stage.add_to_cart_at, payment_stage.begin_checkout_at, payment_stage.add_payment_info_at
),

-- One row per session: session attributes, the sequential funnel flags, and order/revenue.
session_fact AS (
  SELECT
    session_base.session_id,
    -- Attribute the session to the week it started in.
    DATE_TRUNC(session_base.session_date, WEEK(MONDAY)) AS week_start,
    session_base.device_category, session_base.country,
    session_base.acquisition_source, session_base.acquisition_medium,
    1 AS session_start_flag,
    IF(purchase_stage.view_item_at IS NOT NULL, 1, 0) AS product_view_flag,
    IF(purchase_stage.add_to_cart_at IS NOT NULL, 1, 0) AS add_to_cart_flag,
    IF(purchase_stage.begin_checkout_at IS NOT NULL, 1, 0) AS begin_checkout_flag,
    IF(purchase_stage.add_payment_info_at IS NOT NULL, 1, 0) AS add_payment_info_flag,
    IF(purchase_stage.purchase_at IS NOT NULL, 1, 0) AS purchase_stage_flag,
    -- purchase_session_flag counts any valid order even with an incomplete tracking path,
    -- so it can be >= the strict sequential Purchase flag above.
    IF(COALESCE(session_commerce.order_count, 0) > 0, 1, 0) AS purchase_session_flag,
    COALESCE(session_commerce.order_count, 0) AS order_count,
    COALESCE(session_commerce.purchase_revenue_usd, 0) AS purchase_revenue_usd
  FROM session_base
  INNER JOIN purchase_stage ON session_base.session_id = purchase_stage.session_id
  LEFT JOIN session_commerce ON session_base.session_id = session_commerce.session_id
),

-- Unpivot each session into one row per funnel stage (long format), which is easier
-- to filter and chart in Tableau than six separate flag columns.
stage_rows AS (
  SELECT
    session_fact.week_start, session_fact.device_category, session_fact.country,
    session_fact.acquisition_source, session_fact.acquisition_medium,
    funnel_stage.stage_order, funnel_stage.stage_name,
    funnel_stage.reached_stage_flag, funnel_stage.previous_stage_reached_flag,
    -- Drop-off: the previous stage was reached but this one was not.
    CASE
      WHEN funnel_stage.stage_order = 1 THEN 0
      WHEN funnel_stage.previous_stage_reached_flag = 1 AND funnel_stage.reached_stage_flag = 0 THEN 1
      ELSE 0
    END AS drop_off_flag,
    -- KPI fields are only populated on the first stage row of each session,
    -- otherwise session/order/revenue totals would be counted six times.
    CASE WHEN funnel_stage.stage_order = 1 THEN 1 ELSE 0 END AS session_count,
    CASE WHEN funnel_stage.stage_order = 1 THEN session_fact.purchase_session_flag ELSE 0 END AS purchase_session_count,
    CASE WHEN funnel_stage.stage_order = 1 THEN session_fact.order_count ELSE 0 END AS order_count,
    CASE WHEN funnel_stage.stage_order = 1 THEN session_fact.purchase_revenue_usd ELSE 0 END AS purchase_revenue_usd
  FROM session_fact
  CROSS JOIN UNNEST([
    STRUCT(1 AS stage_order, 'Session Start' AS stage_name,
      session_fact.session_start_flag AS reached_stage_flag, session_fact.session_start_flag AS previous_stage_reached_flag),
    STRUCT(2, 'Product View', session_fact.product_view_flag, session_fact.session_start_flag),
    STRUCT(3, 'Add to Cart', session_fact.add_to_cart_flag, session_fact.product_view_flag),
    STRUCT(4, 'Begin Checkout', session_fact.begin_checkout_flag, session_fact.add_to_cart_flag),
    STRUCT(5, 'Add Payment Info', session_fact.add_payment_info_flag, session_fact.begin_checkout_flag),
    STRUCT(6, 'Purchase', session_fact.purchase_stage_flag, session_fact.add_payment_info_flag)
  ]) AS funnel_stage
)

-- Final aggregation to the table grain: dimensions plus additive counts only.
SELECT
  week_start, device_category, country, acquisition_source, acquisition_medium,
  stage_order, stage_name,
  SUM(reached_stage_flag) AS stage_session_count,
  SUM(previous_stage_reached_flag) AS previous_stage_session_count,
  SUM(drop_off_flag) AS drop_off_session_count,
  SUM(session_count) AS session_count,
  SUM(purchase_session_count) AS purchase_session_count,
  SUM(order_count) AS order_count,
  ROUND(SUM(purchase_revenue_usd), 2) AS purchase_revenue_usd
FROM stage_rows
GROUP BY week_start, device_category, country, acquisition_source, acquisition_medium, stage_order, stage_name;
