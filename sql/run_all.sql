-- Полный прогон из корня репозитория: psql -v ON_ERROR_STOP=1 -f sql/run_all.sql
\set ON_ERROR_STOP on
\i sql/00_raw.sql
\i sql/10_reporting.sql
\i sql/20_checks.sql
\i sql/30_export.sql
