# Repository Guide

This file is a quick orientation layer for reviewers who want to inspect the
project without reading every script first.

## Review Order

1. `README.md` - business overview, dashboard preview, findings, caveats.
2. `PROJECT_PROVENANCE.txt` - source status, synthetic-vs-real notes, build log.
3. `Reports/data_quality_report.md` - raw data defects and cleaning decisions.
4. `SQL/Database.sql` and `SQL/Data Cleaning.sql` - warehouse structure and cleaning.
5. `SQL/Business Questions.sql` - the 40 business questions and answers.
6. `Scripts/03_clean_and_analyze.py` - independent pandas validation layer.
7. `Excel Dashboard/Blinkit Dashboard.xlsx` - final interactive dashboard.

## What To Verify First

- Revenue reconciliation: raw revenue minus duplicate revenue equals clean revenue.
- Fat-content standardisation: seven raw labels collapse into two final values.
- Missing-value policy: product weights are imputed; outlet size is not guessed.
- Dashboard provenance: the preview image is exported from the workbook, not mocked.
- README claims: all headline values are sourced from `Reports/analysis_output.json`.

## Branch Convention

The repository uses numbered branches to mirror project build phases:

- `01-project-provenance`
- `02-dataset`
- `03-sql-cleaning`
- `04-sql-eda`
- `05-business-questions`
- `06-advanced-sql`
- `07-python-generation`
- `08-python-validation`
- `09-dashboard-automation`
- `10-reports`
- `11-dashboard-workbook`
- `12-readme-assets`
- `13-professional-readme`
- `14-repository-guide`
- `final`

`main` contains the complete portfolio-ready version.
