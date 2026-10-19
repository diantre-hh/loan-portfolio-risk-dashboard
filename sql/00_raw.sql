-- Сырой слой: CSV грузятся как есть, всё текстом.
-- Типы и чистка — только во вьюхах reporting, чтобы кривая строка в выгрузке
-- не роняла загрузку, а была видна в проверках.
-- Скрипт идемпотентен: таблицы создаются один раз, данные перезаливаются целиком.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;

CREATE TABLE IF NOT EXISTS raw.portfolio (
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text,
    loaded_at             timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS raw.fx (
    date      text,
    currency  text,
    rate_kzt  text,
    loaded_at timestamptz DEFAULT now()
);

TRUNCATE raw.portfolio;
TRUNCATE raw.fx;

\copy raw.portfolio (report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date, maturity_date, principal_outstanding, days_past_due, restructured, written_off) FROM 'data/portfolio.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
\copy raw.fx (date, currency, rate_kzt) FROM 'data/fx.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')
