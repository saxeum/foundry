-- Cluster-relative work for one app on one RDS instance. Run as the RDS master
-- over the SSM tunnel. No secret is in this file; psql variables carry them.
--
-- Roles are cluster-scoped; databases are not. The owner owns the app database
-- and runs the migration Job. The app role is DML only.

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'owner_role', :'owner_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'owner_role') \gexec

SELECT format('ALTER ROLE %I PASSWORD %L', :'owner_role', :'owner_pw') \gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_role', :'app_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_role') \gexec

SELECT format('ALTER ROLE %I PASSWORD %L', :'app_role', :'app_pw') \gexec

-- CREATE DATABASE ... OWNER requires the current role to be able to SET ROLE to
-- the owner; the RDS master is not a member by default.
SELECT format('GRANT %I TO %I', :'owner_role', :'master_role') \gexec

SELECT format('CREATE DATABASE %I OWNER %I', :'app_db', :'owner_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') \gexec
