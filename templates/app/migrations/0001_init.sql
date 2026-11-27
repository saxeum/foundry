-- The template's one table. Replace it with the app's schema; the migration
-- runner, the checksum and the advisory lock are the part the platform owns.
CREATE TABLE hello (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    message text NOT NULL
);
