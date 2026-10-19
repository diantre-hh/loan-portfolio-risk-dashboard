-- Выгрузка вьюх reporting в JSON для статичного дашборда.
-- Дашборд ничего не считает сам: он только рисует то, что посчитано во вьюхах.
\pset format unaligned
\pset tuples_only on
\pset pager off

\o dashboard/data/kpi.json
SELECT coalesce(json_agg(t ORDER BY report_date, sort_order), '[]') FROM reporting.v_kpi t;

\o dashboard/data/portfolio_metrics.json
SELECT coalesce(json_agg(t ORDER BY report_date), '[]') FROM reporting.v_portfolio_metrics t;

\o dashboard/data/metrics_by_dim.json
SELECT coalesce(json_agg(t ORDER BY dimension, dim_value, report_date), '[]') FROM reporting.v_metrics_by_dim t;

\o dashboard/data/buckets_by_dim.json
SELECT coalesce(json_agg(t ORDER BY dimension, dim_value, report_date, dpd_bucket), '[]') FROM reporting.v_buckets_by_dim t;

\o dashboard/data/top_groups.json
SELECT coalesce(json_agg(t ORDER BY report_date, rank), '[]') FROM reporting.v_top_groups t;

\o dashboard/data/dq_sensitivity.json
SELECT coalesce(json_agg(t ORDER BY report_date), '[]')
FROM (
    SELECT s.report_date, s.flagged_loans,
           m.par90_share, s.par90_share_adj,
           m.npl_share, s.npl_share_adj
    FROM reporting.v_dq_sensitivity s
    JOIN reporting.v_portfolio_metrics m USING (report_date)
) t;

\o
