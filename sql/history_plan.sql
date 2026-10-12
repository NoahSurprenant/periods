/*
 * The plan inserting into a history table is cached per history table.  It
 * must follow the history table when it is renamed or moved, and when the row
 * type of what we insert changes, and must not be prepared again for every
 * row.
 */

/* Run tests as unprivileged user */
SET ROLE TO periods_unprivileged_user;

CREATE TABLE hp (id integer PRIMARY KEY, value text);
SELECT periods.add_system_time_period('hp');
SELECT periods.add_system_versioning('hp');
INSERT INTO hp VALUES (1, 'a');
UPDATE hp SET value = 'b';
UPDATE hp SET value = 'c';
SELECT id, value FROM hp_history ORDER BY system_time_start;

/* Rename the history table; the history must follow it */
ALTER TABLE hp_history RENAME TO hp_past;
UPDATE hp SET value = 'd';
SELECT id, value FROM hp_past ORDER BY system_time_start;

/* A new table with the old name must not get any of it */
CREATE TABLE hp_history (LIKE hp_past);
UPDATE hp SET value = 'e';
SELECT id, value FROM hp_past ORDER BY system_time_start;
TABLE hp_history;
DROP TABLE hp_history;

/*
 * Change the main table so that its rows need converting to the history
 * table's row type
 */
BEGIN;
SELECT periods.drop_system_versioning('hp');
ALTER TABLE hp DROP COLUMN value;
ALTER TABLE hp ADD COLUMN value text;
SELECT periods.add_system_versioning('hp', history_table_name => 'hp_past');
COMMIT;
UPDATE hp SET value = 'f';
UPDATE hp SET value = 'g';
SELECT id, value FROM hp_past ORDER BY system_time_start;

/* Move it to another schema and rename it at once */
RESET ROLE;
CREATE SCHEMA hp_schema AUTHORIZATION periods_unprivileged_user;
SET ROLE TO periods_unprivileged_user;
BEGIN;
ALTER TABLE hp_past SET SCHEMA hp_schema;
ALTER TABLE hp_schema.hp_past RENAME TO hp_old;
COMMIT;
UPDATE hp SET value = 'h';
SELECT id, value FROM hp_schema.hp_old ORDER BY system_time_start;

/* Several rows, one plan (we can only see this from PostgreSQL 14) */
UPDATE hp SET value = value || '!';
UPDATE hp SET value = value || '!';
UPDATE hp SET value = value || '!';
UPDATE hp SET value = value || '!';
UPDATE hp SET value = value || '!';
SELECT id, value FROM hp;
SELECT count(*) FROM hp_schema.hp_old;
RESET ROLE;
DO $$
DECLARE
    plans bigint;
BEGIN
    IF pg_catalog.current_setting('server_version_num')::integer >= 140000 THEN
        EXECUTE $q$
            SELECT count(*)
            FROM pg_catalog.pg_backend_memory_contexts
            WHERE name = 'CachedPlanSource'
              AND ident LIKE 'INSERT INTO hp_schema.hp_old %'
        $q$ INTO plans;

        IF plans <> 1 THEN
            RAISE EXCEPTION '% plans to insert into hp_old', plans;
        END IF;
    END IF;
END;
$$;
SET ROLE TO periods_unprivileged_user;

SELECT periods.drop_system_versioning('hp', drop_behavior => 'CASCADE', purge => true);
DROP TABLE hp;
DROP SCHEMA hp_schema;
