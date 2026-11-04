"""Build the DuckDB database from the two CSVs in data/.  Run:  python build_db.py"""
import duckdb
con = duckdb.connect("sp500.duckdb")
con.execute("""
CREATE OR REPLACE TABLE daily_prices AS
SELECT CAST(date AS DATE) AS trade_date, "Name" AS symbol,
       open, high, low, close, CAST(volume AS BIGINT) AS volume
FROM read_csv_auto('data/all_stocks_5yr.csv');
""")
con.execute("""
CREATE OR REPLACE TABLE companies AS
SELECT "Symbol" AS symbol, "Security" AS name, "GICS Sector" AS sector,
       "GICS Sub-Industry" AS sub_industry, "Headquarters Location" AS hq,
       CAST("Date added" AS DATE) AS date_added
FROM read_csv_auto('data/constituents.csv');
""")
print("Built sp500.duckdb:",
      con.execute("SELECT COUNT(*) FROM daily_prices").fetchone()[0], "price rows,",
      con.execute("SELECT COUNT(*) FROM companies").fetchone()[0], "companies")
con.close()
