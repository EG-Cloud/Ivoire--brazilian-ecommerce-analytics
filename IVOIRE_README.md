# IVOIRE — Supply Chain & Seller Intelligence System
### Brazilian E-Commerce Analytics Portfolio Project (Olist Dataset)

## Overview

IVOIRE is an end-to-end data analytics project built on the Olist Brazilian
E-Commerce public dataset (~99K orders, Sept 2016 – Sept 2018). It covers
the full pipeline from raw data cleaning to executive-level dashboards,
with a focus on **logistics performance**, **seller quality scoring**, and
**customer sentiment** across the marketplace.

**Stack**: PostgreSQL (cleaning, star schema, KPI engineering) → Python
(pandas, scikit-learn, Prophet, Hugging Face Transformers) → Power BI
Desktop (5 dashboards).

## Dataset

| Table | Rows |
|---|---|
| Customers | 99,441 |
| Sellers | 3,095 |
| Products | 32,951 |
| Orders | 99,441 |
| Order items | 112,650 |
| Order payments | 103,886 |
| Order reviews | 99,224 |
| Geolocation | 1,000,163 |

## Pipeline Summary

1. **Data cleaning (PostgreSQL)** — null audits, duplicate detection,
   referential integrity checks (`LEFT JOIN` pattern throughout), and a
   flag-rather-than-correct approach for ambiguous data (city/accent
   mismatches, outliers) to preserve raw signal for downstream decisions.
2. **Star schema** — `fact_shipments` (grain: order item), `fact_payments`,
   `fact_reviews` kept as separate fact tables to avoid fan-out joins;
   `dim_customers`, `dim_sellers`, `dim_products`, `dim_dates`.
3. **KPI engineering** — monthly and by-state logistics KPIs; `seller_metrics`
   as a shared aggregation base for scoring and clustering.
4. **Python — Vendor Scoring & Clustering** — a weighted composite score
   (/100, 40% logistics / 40% satisfaction / 20% volume) and a 4-cluster
   KMeans segmentation of sellers.
5. **Python — Forecasting** — Prophet, weekly granularity, order revenue by
   state (top 15 states), with train/test validation (MAE) per state before
   trusting the forward-looking forecast.
6. **Python — Sentiment Analysis** — multilingual BERT model
   (`nlptown/bert-base-multilingual-uncased-sentiment`) scoring Portuguese
   review comments directly (no translation step), compared against the
   existing star rating.
7. **Power BI — 5 dashboards** — Logistics Overview, Vendor Scorecard,
   Forecasting, Sentiment/Reviews, Executive Summary.

## Business Hypotheses & Findings

| # | Hypothesis | Result | Finding |
|---|---|---|---|
| H1 | Q4 is the most profitable quarter, with a November peak (Brazilian Black Friday) | ✅ Confirmed | For the one complete year available (2017), Q4 revenue (R$2.81M) clearly exceeds Q1–Q3, with November alone (R$1.18M) far outpacing October (R$769K) and December (R$864K). 2018's Q4 is incomplete in the dataset and 2016 is too early-stage (launch period) to be meaningful. |
| H2 | Order volume grew significantly between 2016 and 2018 | ✅ Strongly confirmed | Monthly average order volume rose from ~92 orders/month (2016, partial) to ~4,239/month (2017) to ~7,649/month (2018, partial) — an ~80% month-over-month growth rate between 2017 and 2018 alone. |
| H3 | Forecasting indicates continued revenue growth ahead | ⚠️ Partially confirmed | The model forecasts a rise toward November–December 2018 (R$109K → R$149K/week), consistent with H1's seasonality — but the near-term forecast (Sept–Oct) is closer to a plateau with a mid-October dip, not a smooth continuous increase. |
| H4 | Most orders are delivered ahead of the estimated date, by less than 5 days on average | ⚠️ Partially confirmed | Direction confirmed — orders are delivered early on average — but the magnitude is far larger than hypothesized: **11.59 days early on average**, more than double the assumed 5-day buffer. Suggests Olist's estimated delivery dates are conservatively padded. |
| H5 | Late orders have a significantly lower review score than on-time orders | ✅ Strongly confirmed | Late orders average **2.55/5**, on-time orders average **4.21/5** — a 1.66-point gap. |
| H6 | Inter-state deliveries are slower than intra-state deliveries | ✅ Confirmed | Intra-state delivery time averages ~7.9 days vs ~14.05 days inter-state (nearly double). Interestingly, the *delay relative to estimate* is not worse for inter-state (in fact slightly more early on average), suggesting Olist's estimation model already accounts for the added distance. |
| H7 | 90%+ of sellers score above 80/100 on the Vendor Score | ❌ Strongly refuted | Only **7 of 3,095 sellers (0.23%)** exceed 80/100. The scoring methodology's revenue sub-score is heavily right-skewed by a small number of high-revenue sellers (min-max normalization compresses most sellers near 0 on this dimension) — a known limitation of the composite score, not evidence that sellers are broadly underperforming on logistics or satisfaction alone. |
| H8 | The top 20% of sellers generate ~80% of total revenue (Pareto principle) | ✅ Confirmed | Top 20% of sellers by revenue account for **82.06%** of total revenue — closely matching the classic 80/20 split. |
| H9 | A minority of underperforming sellers concentrates the majority of late deliveries | ⚠️ Nuanced — refuted in absolute terms, confirmed in rate terms | In absolute counts, **Cluster 3 (High-Volume Core, 1,371 sellers)** accounts for 85.3% of all late orders platform-wide — simply because of its sheer size, not poor individual performance (its per-seller late rate is a moderate 8.65%). The true rate-based underperformer is **Cluster 1 (Chronic Underperformers, only 100 sellers)**, with a 74.96% late rate — but because this cluster is small, it contributes comparatively few late orders in absolute terms (2.4% of the platform total). |
| H10 | Freight cost is proportional to product weight/dimensions | ✅ Confirmed | Correlation between freight value and product weight: **0.61** — a moderate-to-strong positive relationship. |
| H11 | Some product categories have a disproportionately high freight ratio relative to price | ✅ Strongly confirmed | Standout categories: `home_comfort_2` (93.4% of price spent on freight), `dvds_blu_ray` (83.3%), `electronics` (68.4%), `christmas_supplies` (67.5%) — 2–3x the platform average (~33.6%). |
| H12 | São Paulo concentrates the majority of sellers and customers | ⚠️ Partially confirmed | True for sellers (**59.7%**, a clear majority) but not strictly for customers (**41.98%**, a strong plurality, not a majority). |
| H13 | Logistics routes to major cities are more efficient than to smaller cities | ❔ Not tested | Olist provides no city population/size data, and no reliable proxy was computed for this analysis. Flagged as a possible future analysis (e.g., using order volume per city as a size proxy) rather than answered speculatively. |
| H14 | 80%+ of customers are satisfied (review score ≥ 4) | ⚠️ Just below threshold | Combined 4★ and 5★ share: **77.07%** (57.78% + 19.29%) — close to, but just under, the 80% threshold as stated. |
| H15 | Text sentiment generally confirms the star rating given | ✅ Directionally confirmed | Average gap between predicted text sentiment and star rating is **-0.41** (on a 5-point scale) — modest in size, indicating general alignment, with detected sentiment reading slightly more critical than the star score on average. (A precise "% of reviews within X points" statistic was not computed — this is a directional read from the average gap only.) |

## Dashboards

1. **Logistics Overview** — monthly delay/delivery trends, on-time
   performance by state (Bullet Chart), late-delivery choropleth (Shape Map),
   freight ratio by state.
2. **Vendor Scorecard** — score distribution, seller delay vs satisfaction
   scatter (colored by cluster, sized by revenue), cluster profile Radar
   Chart, seller detail table with conditional formatting.
3. **Forecasting** — actual vs forecast with confidence band (Prophet,
   weekly model, monthly display axis), Ribbon Chart for state ranking over
   time, Decomposition Tree for interactive exploration by state/month.
4. **Sentiment/Reviews** — review score vs predicted sentiment distribution,
   sentiment trend, Word Cloud (positive vs negative comments, Portuguese
   stop words applied), product category Treemap colored by sentiment.
5. **Executive Summary** — headline KPIs across all four pillars, cluster
   and sentiment breakdowns, a 4-pillar summary table (value + trend), and
   a national forecast closer.

## Key Methodological Notes & Limitations

- **Flag-over-correction philosophy**: ambiguous data (city name variants,
  statistical outliers) is flagged with boolean columns rather than
  auto-corrected, preserving the option to filter at analysis time rather
  than making an irreversible cleaning decision upfront.
- **Multi-seller/multi-payment orders**: reviews and revenue are
  pre-aggregated at the correct grain before joining across fact tables to
  avoid row-count fan-out (a bug caught and fixed during the payments
  reconciliation step).
- **Vendor Score skew**: the `total_revenue` sub-score is heavily right-skewed
  due to a handful of very high-revenue sellers under min-max normalization —
  worth revisiting with a log-transform in a future iteration (see H7).
- **Forecast reliability**: MAE was computed via a held-out validation model
  (last 8 weeks excluded from training) — the *final* forecasting model was
  retrained on the full series, so no reliability metric is recomputed
  against it directly in Power BI (doing so would measure in-sample fit,
  not real predictive accuracy).
- **Haversine distance test**: seller-to-customer geographic distance was
  tested against delivery delay and found to have negligible correlation
  (-0.08) — kept in the model for descriptive/mapping purposes only, not
  pursued as an explanatory factor.

## Tech Stack

- **Database**: PostgreSQL
- **Languages**: SQL, Python (pandas, scikit-learn, Prophet, Transformers)
- **BI**: Power BI Desktop (native visuals + AppSource: Bullet Chart, Radar
  Chart, Ribbon Chart, Word Cloud)
