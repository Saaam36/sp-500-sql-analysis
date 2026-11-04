-- ============================================================
--  S&P 500 Market Analysis — SQL Query Suite (DuckDB)
--  Author: Sam Zheng
--  Tables:
--    companies(symbol, name, sector, sub_industry, hq, date_added)
--    daily_prices(trade_date, symbol, open, high, low, close, volume)
--  Theme: liquidity, volatility, and risk across the S&P 500 (2013-2018)
-- ============================================================


-- @@Q1  Dataset overview: coverage, symbols, and date range
--       Technique: COUNT, COUNT(DISTINCT), MIN/MAX
SELECT
    COUNT(*)                       AS price_rows,
    COUNT(DISTINCT symbol)         AS num_stocks,
    MIN(trade_date)                AS first_day,
    MAX(trade_date)                AS last_day
FROM daily_prices;


-- @@Q2  Which sectors trade the most money per day?
--       Technique: JOIN, GROUP BY, aggregate (avg daily dollar volume)
SELECT
    c.sector,
    COUNT(DISTINCT p.symbol)               AS stocks,
    ROUND(AVG(p.close * p.volume) / 1e6, 1) AS avg_daily_dollar_vol_m
FROM daily_prices p
JOIN companies c USING (symbol)
GROUP BY c.sector
ORDER BY avg_daily_dollar_vol_m DESC;


-- @@Q3  Top 10 most actively traded stocks (by average daily share volume)
--       Technique: window function RANK() over an aggregated result (CTE)
WITH vol AS (
    SELECT symbol, AVG(volume) AS avg_vol
    FROM daily_prices
    GROUP BY symbol
)
SELECT
    RANK() OVER (ORDER BY avg_vol DESC) AS rnk,
    v.symbol, c.name, c.sector,
    ROUND(v.avg_vol / 1e6, 2)           AS avg_daily_vol_m
FROM vol v
LEFT JOIN companies c USING (symbol)
ORDER BY rnk
LIMIT 10;


-- @@Q4  The 10 largest single-day price jumps in the whole market
--       Technique: LAG() to get prior close, compute daily return, rank
WITH r AS (
    SELECT symbol, trade_date, close,
           LAG(close) OVER (PARTITION BY symbol ORDER BY trade_date) AS prev_close
    FROM daily_prices
)
SELECT symbol, trade_date,
       ROUND(prev_close, 2) AS prev_close,
       ROUND(close, 2)      AS close,
       ROUND(100.0 * (close - prev_close) / prev_close, 2) AS daily_return_pct
FROM r
WHERE prev_close IS NOT NULL
ORDER BY daily_return_pct DESC
LIMIT 10;


-- @@Q5  Most and least volatile stocks (annualized volatility of daily returns)
--       Technique: CTE of returns, STDDEV aggregate, *sqrt(252) annualization, JOIN
WITH ret AS (
    SELECT symbol,
           close / LAG(close) OVER (PARTITION BY symbol ORDER BY trade_date) - 1 AS r
    FROM daily_prices
),
vol AS (
    SELECT symbol,
           ROUND(STDDEV_SAMP(r) * SQRT(252) * 100, 1) AS ann_vol_pct,
           COUNT(r) AS n
    FROM ret
    WHERE r IS NOT NULL
    GROUP BY symbol
    HAVING COUNT(r) > 750           -- keep stocks with a full history
)
SELECT v.symbol, c.name, c.sector, v.ann_vol_pct
FROM vol v LEFT JOIN companies c USING (symbol)
ORDER BY v.ann_vol_pct DESC
LIMIT 10;


-- @@Q6  Trend signal: 50-day moving average and golden/death crosses for AAPL
--       Technique: windowed moving average (ROWS frame), LAG, CASE
WITH ma AS (
    SELECT trade_date, close,
           AVG(close) OVER (ORDER BY trade_date
                            ROWS BETWEEN 49 PRECEDING AND CURRENT ROW) AS ma50
    FROM daily_prices
    WHERE symbol = 'AAPL'
),
crossed AS (
    SELECT trade_date, close, ma50,
           LAG(close - ma50) OVER (ORDER BY trade_date) AS prev_gap,
           close - ma50 AS gap
    FROM ma
)
SELECT trade_date, ROUND(close,2) AS close, ROUND(ma50,2) AS ma50,
       CASE WHEN prev_gap < 0 AND gap >= 0 THEN 'cross ABOVE (bullish)'
            WHEN prev_gap > 0 AND gap <= 0 THEN 'cross BELOW (bearish)' END AS signal
FROM crossed
WHERE (prev_gap < 0 AND gap >= 0) OR (prev_gap > 0 AND gap <= 0)
ORDER BY trade_date;


-- @@Q7  Maximum drawdown per stock (worst peak-to-trough drop)
--       Technique: running peak via window MAX, then worst drop; a core risk metric
WITH dd AS (
    SELECT symbol, trade_date, close,
           MAX(close) OVER (PARTITION BY symbol ORDER BY trade_date
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_peak
    FROM daily_prices
)
SELECT symbol, c.name, c.sector,
       ROUND(MIN((close - running_peak) / running_peak) * 100, 1) AS max_drawdown_pct
FROM dd LEFT JOIN companies c USING (symbol)
GROUP BY symbol, c.name, c.sector
ORDER BY max_drawdown_pct ASC
LIMIT 10;


-- @@Q8  Which sectors delivered the best total return over the full period?
--       Technique: FIRST_VALUE/LAST_VALUE per stock, then average by sector (CTE+JOIN)
WITH bookends AS (
    SELECT DISTINCT symbol,
           FIRST_VALUE(close) OVER (PARTITION BY symbol ORDER BY trade_date) AS first_close,
           LAST_VALUE(close)  OVER (PARTITION BY symbol ORDER BY trade_date
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_close
    FROM daily_prices
),
stock_ret AS (
    SELECT symbol, (last_close / first_close - 1) AS total_ret FROM bookends
)
SELECT c.sector,
       COUNT(*)                               AS stocks,
       ROUND(AVG(s.total_ret) * 100, 1)       AS avg_total_return_pct
FROM stock_ret s JOIN companies c USING (symbol)
GROUP BY c.sector
ORDER BY avg_total_return_pct DESC;


-- @@Q9  Liquidity ranking via the Amihud illiquidity measure
--       Amihud = average of |daily return| / daily dollar volume (higher = less liquid)
--       Technique: CTE returns + dollar volume, aggregate, JOIN  (ties to microstructure research)
WITH base AS (
    SELECT symbol, trade_date,
           ABS(close / LAG(close) OVER (PARTITION BY symbol ORDER BY trade_date) - 1) AS abs_ret,
           close * volume AS dollar_vol
    FROM daily_prices
)
SELECT c.sector,
       ROUND(AVG(abs_ret / NULLIF(dollar_vol,0)) * 1e9, 3) AS amihud_illiq_x1e9
FROM base b LEFT JOIN companies c USING (symbol)
WHERE abs_ret IS NOT NULL
GROUP BY c.sector
ORDER BY amihud_illiq_x1e9 DESC;


-- @@Q10 Do volume spikes coincide with big price moves?
--       A "spike" = volume > 2x its trailing 20-day average. Compare returns on spike vs normal days.
--       Technique: trailing-window average (frame), LAG return, CASE bucketing, aggregate
WITH prep AS (
    SELECT symbol, trade_date,
           close / LAG(close) OVER (PARTITION BY symbol ORDER BY trade_date) - 1 AS r,
           volume,
           AVG(volume) OVER (PARTITION BY symbol ORDER BY trade_date
                             ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING) AS avg20_vol
    FROM daily_prices
)
SELECT
    CASE WHEN volume > 2 * avg20_vol THEN 'volume spike (>2x)' ELSE 'normal day' END AS day_type,
    COUNT(*)                              AS days,
    ROUND(AVG(ABS(r)) * 100, 3)           AS avg_abs_return_pct
FROM prep
WHERE r IS NOT NULL AND avg20_vol IS NOT NULL
GROUP BY day_type
ORDER BY avg_abs_return_pct DESC;


-- @@Q11 Co-movement: monthly-return correlation between AAPL and MSFT
--       Technique: date_trunc to month, monthly returns via LAG, CORR aggregate
WITH monthly AS (
    SELECT symbol, date_trunc('month', trade_date) AS mth, LAST(close ORDER BY trade_date) AS mclose
    FROM daily_prices
    WHERE symbol IN ('AAPL','MSFT')
    GROUP BY symbol, mth
),
mret AS (
    SELECT symbol, mth, mclose / LAG(mclose) OVER (PARTITION BY symbol ORDER BY mth) - 1 AS r
    FROM monthly
),
wide AS (
    SELECT a.mth, a.r AS aapl_r, m.r AS msft_r
    FROM mret a JOIN mret m ON a.mth = m.mth AND a.symbol='AAPL' AND m.symbol='MSFT'
    WHERE a.r IS NOT NULL AND m.r IS NOT NULL
)
SELECT ROUND(CORR(aapl_r, msft_r), 3) AS corr_aapl_msft, COUNT(*) AS months
FROM wide;


-- @@Q12 Data check: price-history tickers that are NOT in today's S&P 500
--       (companies that left the index since 2018) — Technique: LEFT JOIN anti-join
SELECT p.symbol, COUNT(*) AS trading_days
FROM (SELECT DISTINCT symbol FROM daily_prices) p
LEFT JOIN companies c USING (symbol)
JOIN daily_prices d USING (symbol)
WHERE c.symbol IS NULL
GROUP BY p.symbol
ORDER BY p.symbol
LIMIT 15;
