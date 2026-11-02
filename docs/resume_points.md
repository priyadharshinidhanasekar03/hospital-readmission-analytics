# Resume / interview notes

**Hospital Readmission Analytics (SQL, PL/pgSQL, Oracle PL/SQL)** — github.com/<you>/hospital-readmission-sql
- Designed a normalized healthcare database (8 tables, PK/FK/CHECK constraints) and ETL that cleans and loads 101K real hospital encounters from 130 US hospitals.
- Wrote 13 analytical SQL reports using CTEs, window functions, and Pareto/gaps-and-islands analysis. Found that 4.5% of patients account for 50% of 30-day readmissions.
- Built a PL/pgSQL risk-scoring function and a nightly stored procedure with error handling and run logging. The HIGH tier is readmitted at 28.6% vs 9.9% for LOW (about 3×).
- Added an audit trigger, a materialized view for BI, and 21 automated data-quality and unit tests. Ported the procedural layer to an Oracle PL/SQL package.

## Likely interview questions
- *Why stage as TEXT?* So a bad value can never abort the load. Casting happens in one transaction, and rejects go to a table.
- *Why exclude deaths/hospice?* They can't be readmitted. Leaving them in pushes the rate down (CMS rule).
- *How do you prevent SQL injection in dynamic SQL?* Use a whitelist plus `format('%I')` identifier quoting.
- *Why a generated column for the KPI?* It can never drift from the source value.
- *Why does the procedure COMMIT the log row first?* So a FAILED run is still recorded. Oracle uses PRAGMA AUTONOMOUS_TRANSACTION for this.
