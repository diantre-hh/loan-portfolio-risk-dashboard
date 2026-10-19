-- Сверки. Каждая строка — одна проверка, ok = true.
-- Запуск: psql -f sql/20_checks.sql. Если где-то false — дашборд не обновляем.

CREATE OR REPLACE VIEW reporting.v_checks AS
WITH raw_cnt AS (
    SELECT report_date::date AS report_date, count(*) AS raw_rows,
           count(DISTINCT loan_id) AS raw_loans
    FROM raw.portfolio GROUP BY 1
),
snap AS (
    SELECT report_date, count(*) AS snap_rows,
           count(*) FILTER (WHERE is_written_off) AS written_off_rows,
           count(*) FILTER (WHERE fx_rate IS NULL) AS no_fx_rows,
           count(*) FILTER (WHERE currency <> 'KZT' AND fx_rate_date <> report_date) AS stale_fx_rows
    FROM reporting.v_loan_snapshot GROUP BY 1
),
-- независимый пересчёт портфеля прямо из raw, без витрины
raw_portfolio AS (
    SELECT d.report_date, sum(d.amt * CASE WHEN d.currency = 'KZT' THEN 1 ELSE f.rate_kzt::numeric END) AS portfolio_kzt
    FROM (SELECT DISTINCT report_date::date AS report_date, loan_id, currency,
                 principal_outstanding::numeric AS amt
          FROM raw.portfolio WHERE written_off <> '1') d
    LEFT JOIN raw.fx f ON f.date::date = d.report_date AND f.currency = d.currency
    GROUP BY d.report_date
),
dim_tot AS (
    SELECT report_date, dimension, sum(portfolio_kzt) AS s
    FROM reporting.v_metrics_by_dim GROUP BY 1, 2
),
bucket_tot AS (
    SELECT report_date, dimension, sum(portfolio_kzt) AS s
    FROM reporting.v_buckets_by_dim GROUP BY 1, 2
)
SELECT r.report_date, 'один кредит — одна строка после дедупликации' AS check_name,
       s.snap_rows = r.raw_loans AS ok,
       format('raw %s строк, уникальных кредитов %s, в витрине %s', r.raw_rows, r.raw_loans, s.snap_rows) AS details
FROM raw_cnt r JOIN snap s USING (report_date)
UNION ALL
SELECT report_date, 'у всех валютных кредитов есть курс на дату среза',
       no_fx_rows = 0 AND stale_fx_rows = 0,
       format('без курса %s, курс не на дату среза %s', no_fx_rows, stale_fx_rows)
FROM snap
UNION ALL
SELECT m.report_date, 'портфель витрины = пересчёт из raw',
       abs(m.portfolio_kzt - rp.portfolio_kzt) < 1,
       format('витрина %s, raw %s', round(m.portfolio_kzt, 2), round(rp.portfolio_kzt, 2))
FROM reporting.v_portfolio_metrics m JOIN raw_portfolio rp USING (report_date)
UNION ALL
SELECT m.report_date, 'сумма по разрезу ' || d.dimension || ' = портфель',
       abs(m.portfolio_kzt - d.s) < 1, format('разница %s', round(m.portfolio_kzt - d.s, 2))
FROM reporting.v_portfolio_metrics m JOIN dim_tot d USING (report_date)
UNION ALL
SELECT m.report_date, 'сумма корзин просрочки (' || b.dimension || ') = портфель',
       abs(m.portfolio_kzt - b.s) < 1, format('разница %s', round(m.portfolio_kzt - b.s, 2))
FROM reporting.v_portfolio_metrics m JOIN bucket_tot b USING (report_date)
UNION ALL
SELECT report_date, 'PAR90 <= NPL <= 100% и PAR90 <= PAR30',
       par90_share <= npl_share AND npl_share <= 1 AND par90_share <= par30_share,
       format('PAR30 %s, PAR90 %s, NPL %s', round(par30_share, 4), round(par90_share, 4), round(npl_share, 4))
FROM reporting.v_portfolio_metrics;

-- Подозрительные переходы между соседними срезами. Это не ошибки витрины,
-- а вопросы к источнику: в расчёт метрик идут как есть, но выносятся на риск-комитет.
CREATE OR REPLACE VIEW reporting.v_dq_transitions AS
WITH snap AS (
    SELECT s.*,
           -- номер среза среди всех дат, чтобы lag брал именно соседний срез, а не «последний, где был кредит»
           dense_rank() OVER (ORDER BY s.report_date) AS snap_no
    FROM reporting.v_loan_snapshot s
),
lagged AS (
    SELECT s.report_date, s.loan_id, s.group_id, s.sector, s.program,
           s.days_past_due  AS dpd,
           s.is_written_off,
           s.is_restructured,
           s.principal_outstanding AS principal,
           s.outstanding_kzt,
           s.snap_no,
           lag(s.snap_no)               OVER w AS prev_snap_no,
           lag(s.report_date)           OVER w AS prev_report_date,
           lag(s.days_past_due)         OVER w AS prev_dpd,
           lag(s.is_written_off)        OVER w AS prev_written_off,
           lag(s.principal_outstanding) OVER w AS prev_principal
    FROM snap s
    WINDOW w AS (PARTITION BY s.loan_id ORDER BY s.report_date)
),
pairs AS (
    SELECT report_date, prev_report_date, loan_id, group_id, sector, program,
           prev_dpd, dpd, prev_written_off, is_written_off, is_restructured,
           prev_principal, principal, outstanding_kzt
    FROM lagged
    WHERE prev_snap_no = snap_no - 1
)
SELECT p.*,
       CASE
           WHEN p.prev_written_off AND NOT p.is_written_off THEN 'вернулся в портфель после списания'
           WHEN p.prev_dpd > 90 AND p.dpd = 0 AND NOT p.is_restructured THEN 'просрочка 90+ обнулилась без реструктуризации'
       END AS issue,
       round(1 - p.principal / nullif(p.prev_principal, 0), 4) AS principal_paydown
FROM pairs p
WHERE (p.prev_written_off AND NOT p.is_written_off)
   OR (p.prev_dpd > 90 AND p.dpd = 0 AND NOT p.is_restructured);

-- Чувствительность: что было бы с метриками, если подозрительные переходы не подтвердятся
-- (вернувшиеся из списания остаются списанными, «вылеченные» 90+ остаются NPL).
CREATE OR REPLACE VIEW reporting.v_dq_sensitivity AS
WITH adj AS (
    SELECT s.report_date, s.outstanding_kzt, s.is_par30, s.is_par90, s.is_npl, s.in_portfolio,
           t.issue
    FROM reporting.v_loan_snapshot s
    LEFT JOIN reporting.v_dq_transitions t USING (report_date, loan_id)
)
SELECT report_date,
       sum(outstanding_kzt) FILTER (WHERE in_portfolio AND issue IS DISTINCT FROM 'вернулся в портфель после списания') AS portfolio_kzt_adj,
       sum(outstanding_kzt) FILTER (WHERE in_portfolio AND issue IS DISTINCT FROM 'вернулся в портфель после списания'
                                     AND (is_par90 OR issue = 'просрочка 90+ обнулилась без реструктуризации'))
         / sum(outstanding_kzt) FILTER (WHERE in_portfolio AND issue IS DISTINCT FROM 'вернулся в портфель после списания') AS par90_share_adj,
       sum(outstanding_kzt) FILTER (WHERE in_portfolio AND issue IS DISTINCT FROM 'вернулся в портфель после списания'
                                     AND (is_npl OR issue = 'просрочка 90+ обнулилась без реструктуризации'))
         / sum(outstanding_kzt) FILTER (WHERE in_portfolio AND issue IS DISTINCT FROM 'вернулся в портфель после списания') AS npl_share_adj,
       count(*) FILTER (WHERE issue IS NOT NULL) AS flagged_loans
FROM adj
GROUP BY report_date;

SELECT * FROM reporting.v_checks ORDER BY report_date, check_name;
SELECT report_date, issue, count(*) AS loans, round(sum(outstanding_kzt) / 1e9, 2) AS bn_kzt
FROM reporting.v_dq_transitions GROUP BY 1, 2 ORDER BY 1, 2;
