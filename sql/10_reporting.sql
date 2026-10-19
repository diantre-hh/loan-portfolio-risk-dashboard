-- Слой reporting: очищенная витрина и метрики.
-- Все вьюхи через CREATE OR REPLACE, повторный запуск ничего не ломает.
-- Если меняется набор колонок вьюхи — сначала DROP VIEW ... CASCADE руками, это осознанное действие.

-- Курсы: типизированные, без дублей по (дата, валюта).
CREATE OR REPLACE VIEW reporting.v_fx AS
SELECT DISTINCT ON (date::date, upper(trim(currency)))
       date::date               AS rate_date,
       upper(trim(currency))    AS currency,
       rate_kzt::numeric(18, 6) AS rate_kzt
FROM raw.fx
ORDER BY date::date, upper(trim(currency)), loaded_at DESC;

-- Очищенная витрина: одна строка = кредит на дату среза.
-- 1) В выгрузке есть полные дубли строк (60 пар) — оставляем одну.
-- 2) Остаток переводим в тенге по курсу на дату среза; если курса на эту дату нет,
--    берём последний известный до неё (rate_date показывает, какой взяли).
-- 3) Списанные кредиты остаются в витрине с флагом, но из портфеля исключаются (in_portfolio).
-- 4) Корзины просрочки и ставки провизий — по определениям задания:
--    NPL = просрочка > 90 дней или реструктуризация; провизии 1% / 10% / 50%.
CREATE OR REPLACE VIEW reporting.v_loan_snapshot AS
WITH typed AS (
    SELECT DISTINCT
           report_date::date                    AS report_date,
           trim(loan_id)                        AS loan_id,
           trim(borrower_id)                    AS borrower_id,
           trim(group_id)                       AS group_id,
           trim(sector)                         AS sector,
           trim(program)                        AS program,
           upper(trim(currency))                AS currency,
           issue_date::date                     AS issue_date,
           maturity_date::date                  AS maturity_date,
           principal_outstanding::numeric(20, 2) AS principal_outstanding,
           days_past_due::int                   AS days_past_due,
           restructured::int = 1                AS is_restructured,
           written_off::int = 1                 AS is_written_off
    FROM raw.portfolio
),
with_fx AS (
    SELECT t.*,
           CASE WHEN t.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS fx_rate,
           CASE WHEN t.currency = 'KZT' THEN t.report_date ELSE fx.rate_date END AS fx_rate_date
    FROM typed t
    LEFT JOIN LATERAL (
        SELECT f.rate_kzt, f.rate_date
        FROM reporting.v_fx f
        WHERE f.currency = t.currency
          AND f.rate_date <= t.report_date
        ORDER BY f.rate_date DESC
        LIMIT 1
    ) fx ON true
),
classified AS (
    SELECT w.*,
           round(w.principal_outstanding * w.fx_rate, 2) AS outstanding_kzt,
           NOT w.is_written_off                          AS in_portfolio,
           w.days_past_due > 30                          AS is_par30,
           w.days_past_due > 90                          AS is_par90,
           (w.days_past_due > 90 OR w.is_restructured)   AS is_npl
    FROM with_fx w
)
SELECT c.*,
       CASE
           WHEN c.is_npl             THEN '4. NPL'
           WHEN c.days_past_due > 30 THEN '3. 31–90 дней'
           WHEN c.days_past_due > 0  THEN '2. 1–30 дней'
           ELSE                           '1. Без просрочки'
       END AS dpd_bucket,
       CASE
           WHEN c.is_npl             THEN 0.50
           WHEN c.days_past_due > 30 THEN 0.10
           ELSE                           0.01
       END::numeric(5, 2) AS provision_rate,
       round(c.outstanding_kzt * CASE
           WHEN c.is_npl             THEN 0.50
           WHEN c.days_past_due > 30 THEN 0.10
           ELSE                           0.01
       END, 2) AS provision_kzt
FROM classified c;

-- Только то, что входит в портфель. Это источник для семантической модели и дашборда.
CREATE OR REPLACE VIEW reporting.v_portfolio AS
SELECT *
FROM reporting.v_loan_snapshot
WHERE in_portfolio;

-- Метрики портфеля на каждую дату среза и изменение к предыдущему срезу.
CREATE OR REPLACE VIEW reporting.v_portfolio_metrics AS
WITH base AS (
    SELECT report_date,
           count(*)                                              AS loans,
           sum(outstanding_kzt)                                  AS portfolio_kzt,
           sum(outstanding_kzt) FILTER (WHERE is_par30)          AS par30_kzt,
           sum(outstanding_kzt) FILTER (WHERE is_par90)          AS par90_kzt,
           sum(outstanding_kzt) FILTER (WHERE is_npl)            AS npl_kzt,
           sum(provision_kzt)                                    AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date
),
groups AS (
    SELECT report_date, group_id, sum(outstanding_kzt) AS group_kzt,
           row_number() OVER (PARTITION BY report_date ORDER BY sum(outstanding_kzt) DESC, group_id) AS rn
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
),
top10 AS (
    SELECT report_date, sum(group_kzt) AS top10_kzt
    FROM groups
    WHERE rn <= 10
    GROUP BY report_date
),
m AS (
    SELECT b.*,
           t.top10_kzt,
           b.par30_kzt      / b.portfolio_kzt AS par30_share,
           b.par90_kzt      / b.portfolio_kzt AS par90_share,
           b.npl_kzt        / b.portfolio_kzt AS npl_share,
           b.provisions_kzt / b.portfolio_kzt AS coverage_share,
           b.provisions_kzt / b.npl_kzt       AS npl_coverage,
           t.top10_kzt      / b.portfolio_kzt AS top10_share
    FROM base b
    JOIN top10 t USING (report_date)
)
SELECT m.*,
       lag(m.report_date)    OVER w AS prev_report_date,
       m.portfolio_kzt  - lag(m.portfolio_kzt)  OVER w AS portfolio_change_kzt,
       m.portfolio_kzt  / lag(m.portfolio_kzt)  OVER w - 1 AS portfolio_change_pct,
       m.provisions_kzt - lag(m.provisions_kzt) OVER w AS provisions_change_kzt,
       -- изменения долей — в процентных пунктах (0.012 = +1,2 п.п.)
       m.par30_share - lag(m.par30_share) OVER w AS par30_change_pp,
       m.par90_share - lag(m.par90_share) OVER w AS par90_change_pp,
       m.npl_share   - lag(m.npl_share)   OVER w AS npl_change_pp,
       m.top10_share - lag(m.top10_share) OVER w AS top10_change_pp
FROM m
WINDOW w AS (ORDER BY m.report_date);

-- Те же метрики в длинном формате: удобно для KPI-плиток и таблицы в README.
CREATE OR REPLACE VIEW reporting.v_kpi AS
SELECT m.report_date, k.sort_order, k.metric, k.label, k.value, k.change, k.unit
FROM reporting.v_portfolio_metrics m
CROSS JOIN LATERAL (VALUES
    (1, 'portfolio',  'Портфель, млрд ₸',     m.portfolio_kzt / 1e9,  m.portfolio_change_kzt / 1e9,  'bn'),
    (2, 'par30',      'PAR30',                m.par30_share,          m.par30_change_pp,             'share'),
    (3, 'par90',      'PAR90',                m.par90_share,          m.par90_change_pp,             'share'),
    (4, 'npl',        'NPL',                  m.npl_share,            m.npl_change_pp,               'share'),
    (5, 'top10',      'Топ-10 групп',         m.top10_share,          m.top10_change_pp,             'share'),
    (6, 'provisions', 'Провизии, млрд ₸',     m.provisions_kzt / 1e9, m.provisions_change_kzt / 1e9, 'bn')
) AS k(sort_order, metric, label, value, change, unit);

-- Разрезы по отрасли и программе в одном формате.
CREATE OR REPLACE VIEW reporting.v_metrics_by_dim AS
WITH dims AS (
    SELECT report_date, 'sector'::text AS dimension, sector AS dim_value,
           outstanding_kzt, provision_kzt, is_par30, is_par90, is_npl
    FROM reporting.v_portfolio
    UNION ALL
    SELECT report_date, 'program', program,
           outstanding_kzt, provision_kzt, is_par30, is_par90, is_npl
    FROM reporting.v_portfolio
)
SELECT report_date, dimension, dim_value,
       count(*)                                     AS loans,
       sum(outstanding_kzt)                         AS portfolio_kzt,
       sum(outstanding_kzt) FILTER (WHERE is_par30) / sum(outstanding_kzt) AS par30_share,
       sum(outstanding_kzt) FILTER (WHERE is_par90) / sum(outstanding_kzt) AS par90_share,
       sum(outstanding_kzt) FILTER (WHERE is_npl)   / sum(outstanding_kzt) AS npl_share,
       sum(provision_kzt)                           AS provisions_kzt
FROM dims
GROUP BY report_date, dimension, dim_value;

-- Структура портфеля по корзинам просрочки в разрезах.
CREATE OR REPLACE VIEW reporting.v_buckets_by_dim AS
SELECT report_date, 'sector'::text AS dimension, sector AS dim_value, dpd_bucket,
       sum(outstanding_kzt) AS portfolio_kzt
FROM reporting.v_portfolio
GROUP BY report_date, sector, dpd_bucket
UNION ALL
SELECT report_date, 'program', program, dpd_bucket, sum(outstanding_kzt)
FROM reporting.v_portfolio
GROUP BY report_date, program, dpd_bucket;

-- Десять крупнейших групп связанных заёмщиков на каждую дату.
CREATE OR REPLACE VIEW reporting.v_top_groups AS
WITH g AS (
    SELECT report_date, group_id,
           count(*)             AS loans,
           sum(outstanding_kzt) AS group_kzt,
           bool_or(is_npl)      AS has_npl
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
)
-- Долю считаем до фильтра rn <= 10: иначе знаменатель был бы суммой только топ-10.
SELECT report_date, group_id, loans, group_kzt, has_npl, share, rn AS rank
FROM (
    SELECT g.*,
           group_kzt / sum(group_kzt) OVER (PARTITION BY report_date) AS share,
           row_number() OVER (PARTITION BY report_date ORDER BY group_kzt DESC, group_id) AS rn
    FROM g
) ranked
WHERE rn <= 10;
