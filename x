// Cloudflare Workers - Indodax Market Analyzer - Full Stock Exchange Style
const INDODAX_API_BASE = 'https://indodax.com/api';

// Global storage for multi-timeframe candles
let candleHistory = {
    '15m': {}, '30m': {}, '1h': {}, '2h': {}, '4h': {},
    '1d': {}, '3d': {}, '1w': {}, '2w': {}, '1m': {}
};

let lastCandleTime = {
    '15m': {}, '30m': {}, '1h': {}, '2h': {}, '4h': {},
    '1d': {}, '3d': {}, '1w': {}, '2w': {}, '1m': {}
};

// Convert timeframe string to milliseconds
function timeframeToMs(tf) {
    const map = {
        '15m': 15 * 60 * 1000,
        '30m': 30 * 60 * 1000,
        '1h': 60 * 60 * 1000,
        '2h': 2 * 60 * 60 * 1000,
        '4h': 4 * 60 * 60 * 1000,
        '1d': 24 * 60 * 60 * 1000,
        '3d': 3 * 24 * 60 * 60 * 1000,
        '1w': 7 * 24 * 60 * 60 * 1000,
        '2w': 14 * 24 * 60 * 60 * 1000,
        '1m': 30 * 24 * 60 * 60 * 1000
    };
    return map[tf] || 3600000;
}

// Update candle history for a ticker across timeframes
function updateCandleHistory(ticker, timeframes) {
    const now = Date.now();
    
    timeframes.forEach(tf => {
        const tfMs = timeframeToMs(tf);
        
        if (!candleHistory[tf][ticker.pair]) {
            candleHistory[tf][ticker.pair] = [];
            lastCandleTime[tf][ticker.pair] = now;
        }
        
        const currentCandles = candleHistory[tf][ticker.pair];
        const lastTime = lastCandleTime[tf][ticker.pair];
        const timeDiff = now - lastTime;
        
        // Create new candle or update existing
        if (timeDiff >= tfMs) {
            // Use previous candle's close as open, or ticker.last if no history
            const prevClose = currentCandles.length > 0 
                ? currentCandles[currentCandles.length - 1].close 
                : ticker.last;
            
            currentCandles.push({
                open: prevClose,
                high: ticker.last,
                low: ticker.last,
                close: ticker.last,
                volume: ticker.volume,
                timestamp: now
            });
            lastCandleTime[tf][ticker.pair] = now;
            
            // Limit to 100 candles per timeframe
            if (currentCandles.length > 100) {
                currentCandles.shift();
            }
        } else {
            // Update current candle
            if (currentCandles.length > 0) {
                const lastCandle = currentCandles[currentCandles.length - 1];
                lastCandle.high = Math.max(lastCandle.high, ticker.last);
                lastCandle.low = Math.min(lastCandle.low, ticker.last);
                lastCandle.close = ticker.last;
                lastCandle.volume = ticker.volume;
            }
        }
    });
}

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);
  
  if (url.pathname === '/api/market') {
    return await getMarketData();
  }
  
  if (url.pathname.startsWith('/api/ticker/')) {
    const pair = url.pathname.split('/').pop();
    return await getTickerHistory(pair);
  }
  
  return new Response(getHTML(), {
    headers: { 'content-type': 'text/html;charset=UTF-8' },
  });
}

async function getMarketData() {
  try {
    const response = await fetch(`${INDODAX_API_BASE}/summaries`);
    const data = await response.json();
    
    if (!data.tickers || typeof data.tickers !== 'object') {
      throw new Error('Failed to fetch market data');
    }
    
    const usdtIdrRate = data.tickers['usdt_idr'] ? parseFloat(data.tickers['usdt_idr'].last) : 0;
    
    const tickers = Object.entries(data.tickers).map(([pair, ticker]) => {
      const last = parseFloat(ticker.last) || 0;
      const high = parseFloat(ticker.high) || 0;
      const low = parseFloat(ticker.low) || 0;
      
      const isUsdtPair = pair.includes('_usdt') || pair.endsWith('usdt');
      
      let volumeIDR = 0;
      if (isUsdtPair) {
        const volUsdt = parseFloat(ticker.vol_usdt) || 0;
        volumeIDR = volUsdt * usdtIdrRate;
      } else {
        volumeIDR = parseFloat(ticker.vol_idr) || 0;
      }
      
      // Calculate from mid-price for accurate momentum/trend
      const midPrice = (high + low) / 2;
      let priceChangePercent = 0;
      if (midPrice > 0) {
        priceChangePercent = ((last - midPrice) / midPrice * 100);
      }
      
      return {
        pair: pair,
        name: ticker.name || pair,
        last: last,
        high: high,
        low: low,
        volume: volumeIDR,
        volumeBase: parseFloat(ticker.vol_btc) || parseFloat(ticker.vol_eth) || parseFloat(ticker.vol_usdt) || 0,
        buy: parseFloat(ticker.buy) || 0,
        sell: parseFloat(ticker.sell) || 0,
        priceChange: last - low,
        priceChangePercent: priceChangePercent,
        isUsdtPair: isUsdtPair,
        usdtRate: isUsdtPair ? usdtIdrRate : null,
        serverTime: ticker.server_time || Date.now()
      };
    });
    
    const validTickers = tickers.filter(t => t.last > 0);
    
    const totalVolume = validTickers.reduce((sum, t) => sum + t.volume, 0);
    const avgVolume = totalVolume / validTickers.length;
    
    // Update candle history for all timeframes
    const timeframes = ['15m', '30m', '1h', '2h', '4h', '1d', '3d', '1w', '2w', '1m'];
    validTickers.forEach(ticker => {
      updateCandleHistory(ticker, timeframes);
    });
    
    const tickersWithSignals = validTickers.map(ticker => {
      const signals = {};
      
      timeframes.forEach(tf => {
        const tfCandles = candleHistory[tf][ticker.pair] || [];
        signals[tf] = analyzeSignalAdvanced(ticker, avgVolume, tf, tfCandles);
      });
      
      return { ...ticker, signals };
    });
    
    const topVolume = [...tickersWithSignals]
      .filter(t => t.volume > 0)
      .sort((a, b) => b.volume - a.volume);
    
    return new Response(JSON.stringify({
      success: true,
      timestamp: new Date().toISOString(),
      usdtIdrRate: usdtIdrRate,
      stats: {
        totalPairs: validTickers.length,
        totalVolume: totalVolume,
        activeMarkets: validTickers.filter(t => t.volume > 0).length,
        totalVolumeAssets: topVolume.length
      },
      tickers: tickersWithSignals,
      topVolume: topVolume
    }), {
      headers: { 
        'content-type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0'
      },
    });
    
  } catch (error) {
    return new Response(JSON.stringify({ 
      success: false,
      error: error.message,
      stack: error.stack 
    }), {
      status: 500,
      headers: { 'content-type': 'application/json' },
    });
  }
}

// Helper function to calculate Bollinger Band position for recommendation logic
// This version calculates both support and resistance based on Bollinger Bands
// Used early in signal analysis before type is fully determined
// Bollinger Bands (20,2) - Industry Standard Setting
// Note: Approximated from 24h range due to real-time API limitations
function calculateBBPositionForRecommendation(ticker, high, low, timeframe) {
  const last = ticker.last;
  const tolerance = 0.015; // 1.5% tolerance
  
  // Estimate BB(20,2) from 24h range
  const range24h = high - low;
  const midPrice = (high + low) / 2;
  
  // High/Low typically represent ~3σ movement (99.7% of price action)
  // So we estimate: σ ≈ range / 6
  // Then BB(20,2) = SMA ± 2σ ≈ SMA ± (2 * range/6) = SMA ± range/3
  const estimatedStdDev = range24h / 6;
  
  // Calculate BB(20,2) approximation
  const upperBand = midPrice + (2 * estimatedStdDev);  // SMA + 2σ
  const lowerBand = midPrice - (2 * estimatedStdDev);  // SMA - 2σ
  const middleBand = midPrice;
  
  // Calculate BB position percentage (0-100%)
  const bbRange = upperBand - lowerBand;
  const bbPositionPercent = bbRange > 0 ? ((last - lowerBand) / bbRange) * 100 : 50;
  
  // Calculate support/resistance levels proportional to BB width
  const bandWidth = upperBand - lowerBand;
  
  // Support levels (for BUY signals)
  const support1 = lowerBand + (bandWidth * 0.05);  // 5% above lower band
  const support2 = lowerBand + (bandWidth * 0.02);  // 2% above lower band
  const support3 = lowerBand;                       // At lower band
  
  // Resistance levels (for SELL signals)
  const resistance1 = upperBand - (bandWidth * 0.05);  // 5% below upper band
  const resistance2 = upperBand - (bandWidth * 0.02);  // 2% below upper band
  const resistance3 = upperBand;                       // At upper band
  
  // Check near support (lower 25% of BB range)
  const nearSupport = (
    Math.abs(last - support1) / last < tolerance ||
    Math.abs(last - support2) / last < tolerance ||
    Math.abs(last - support3) / last < tolerance ||
    bbPositionPercent <= 25 ||
    (last >= support3 && last <= support1 * 1.03)
  );
  
  // Check near resistance (top 25% of BB range)
  const nearResistance = (
    Math.abs(last - resistance1) / last < tolerance ||
    Math.abs(last - resistance2) / last < tolerance ||
    Math.abs(last - resistance3) / last < tolerance ||
    bbPositionPercent >= 75 ||
    (last <= resistance3 && last >= resistance1 * 0.97)
  );
  
  // Determine BB status
  let bbStatus = 'MID';
  if (bbPositionPercent >= 90) bbStatus = 'EXTREME_OVERBOUGHT';
  else if (bbPositionPercent >= 80) bbStatus = 'OVERBOUGHT';
  else if (bbPositionPercent >= 60) bbStatus = 'UPPER';
  else if (bbPositionPercent <= 10) bbStatus = 'EXTREME_OVERSOLD';
  else if (bbPositionPercent <= 20) bbStatus = 'OVERSOLD';
  else if (bbPositionPercent <= 40) bbStatus = 'LOWER';
  
  // Calculate bandwidth (volatility indicator)
  const bandwidth = ((upperBand - lowerBand) / middleBand) * 100;
  const isSqueeze = bandwidth < 8; // BB Squeeze = potential breakout
  
  return {
    nearSupport,
    nearResistance,
    upper: upperBand,
    middle: middleBand,
    lower: lowerBand,
    positionPercent: Math.round(bbPositionPercent * 10) / 10,
    status: bbStatus,
    bandwidth: Math.round(bandwidth * 10) / 10,
    supports: { s1: support1, s2: support2, s3: support3 },
    resistances: { r1: resistance1, r2: resistance2, r3: resistance3 },
    isSqueeze,
    isOverbought: bbPositionPercent >= 80,
    isOversold: bbPositionPercent <= 20
  };
}

// New getRecommendation function with clear, non-overlapping logic
function getRecommendation(ticker, bullishCount, bearishCount, winRate, trend, timeframe, avgVolume) {
    const bbPosition = calculateBBPositionForRecommendation(ticker, ticker.high, ticker.low, timeframe);
    
    // Check volume and volatility
    const volatility = ((ticker.high - ticker.low) / ticker.low) * 100;
    const volumeRatio = ticker.volume / avgVolume;
    
    const isLowVolume = volumeRatio < 0.5;
    const isHighVolatility = volatility > 15;
    
    // 1. Sideways trend with low confidence
    if (trend === 'SIDEWAYS' && winRate < 55) {
        return { text: '➖ SIDEWAYS' };
    }
    
    // 2. Strong Bullish (with BB confirmation)
    if (bullishCount >= 7 && winRate >= 87.5 && bbPosition.nearSupport) {
        if (isLowVolume) return { text: '🟡 BUY WATCH' }; // Downgrade for low volume
        if (isHighVolatility) return { text: '🟢 ACCUMULATE' }; // Downgrade for high volatility
        return { text: '🟢 BUY STRONG' };
    }
    if (bullishCount >= 6 && winRate >= 75 && bbPosition.nearSupport) {
        if (isLowVolume) return { text: '🟠 BUY WATCH' };
        if (isHighVolatility) return { text: '🟡 WAIT BUY' };
        return { text: '🟢 BUY NOW' };
    }
    if (bullishCount >= 5 && winRate >= 62.5 && bbPosition.nearSupport) {
        if (isLowVolume) return { text: '🟠 BUY WATCH' };
        if (isHighVolatility) return { text: '🟡 WAIT BUY' };
        return { text: '🟢 ACCUMULATE' };
    }
    
    // 3. Moderate Bullish (need confirmation)
    if (bullishCount >= 5 && winRate >= 62.5) {
        // Has 5+ bullish signals but NOT at support
        if (isLowVolume || isHighVolatility) return { text: '🟡 WAIT' };
        return { text: '🟠 BUY WATCH' };
    }
    if (bullishCount >= 4 && winRate >= 50) {
        if (trend === 'DOWNTREND') return { text: '🟡 WAIT BUY' }; // Wait for reversal
        if (isLowVolume || isHighVolatility) return { text: '🟡 WAIT' };
        return { text: '🟠 BUY WATCH' };
    }
    
    // 4. Strong Bearish (with BB confirmation)
    if (bearishCount >= 7 && winRate >= 87.5 && bbPosition.nearResistance) {
        if (isLowVolume) return { text: '🟡 SELL WATCH' }; // Downgrade for low volume
        if (isHighVolatility) return { text: '🟡 DISTRIBUTE' }; // Downgrade for high volatility
        return { text: '🔴 SELL STRONG' };
    }
    if (bearishCount >= 6 && winRate >= 75 && bbPosition.nearResistance) {
        if (isLowVolume) return { text: '🟠 SELL WATCH' };
        if (isHighVolatility) return { text: '🟡 WAIT SELL' };
        return { text: '🔴 SELL NOW' };
    }
    if (bearishCount >= 5 && winRate >= 62.5 && bbPosition.nearResistance) {
        if (isLowVolume) return { text: '🟠 SELL WATCH' };
        if (isHighVolatility) return { text: '🟡 WAIT SELL' };
        return { text: '🟡 DISTRIBUTE' };
    }
    
    // 5. Moderate Bearish (need confirmation)
    if (bearishCount >= 5 && winRate >= 62.5) {
        // Has 5+ bearish signals but NOT at resistance
        if (isLowVolume || isHighVolatility) return { text: '🟡 WAIT' };
        return { text: '🟠 SELL WATCH' };
    }
    if (bearishCount >= 4 && winRate >= 50) {
        if (trend === 'UPTREND') return { text: '🟡 WAIT SELL' }; // Wait for reversal
        if (isLowVolume || isHighVolatility) return { text: '🟡 WAIT' };
        return { text: '🟠 SELL WATCH' };
    }
    
    // 6. Weak/Neutral signals
    if (bullishCount >= 3 && bullishCount > bearishCount) {
        return { text: '🟡 WAIT' };
    }
    if (bearishCount >= 3 && bearishCount > bullishCount) {
        return { text: '🟡 WAIT' };
    }
    
    // 7. Completely neutral or conflicting
    return { text: '⚪ HOLD' };
}

// Detect trend from candle patterns
function detectTrendFromCandles(candles) {
    if (candles.length < 10) return 'SIDEWAYS';
    
    const recentCandles = candles.slice(-10);
    let higherHighs = 0, higherLows = 0, lowerHighs = 0, lowerLows = 0;
    
    for (let i = 1; i < recentCandles.length; i++) {
        const prev = recentCandles[i - 1];
        const curr = recentCandles[i];
        
        if (curr.high > prev.high) higherHighs++;
        else lowerHighs++;
        
        if (curr.low > prev.low) higherLows++;
        else lowerLows++;
    }
    
    const closes = recentCandles.map(c => c.close);
    const sma5 = closes.slice(-5).reduce((a, b) => a + b, 0) / 5;
    const sma10 = closes.reduce((a, b) => a + b, 0) / 10;
    const currentPrice = closes[closes.length - 1];
    
    // UPTREND: Higher highs + higher lows + price > SMA
    if (higherHighs >= 6 && higherLows >= 6 && currentPrice > sma10 && sma5 > sma10) {
        return 'UPTREND';
    }
    // DOWNTREND: Lower highs + lower lows + price < SMA
    else if (lowerHighs >= 6 && lowerLows >= 6 && currentPrice < sma10 && sma5 < sma10) {
        return 'DOWNTREND';
    }
    else {
        return 'SIDEWAYS';
    }
}

// Bollinger Bands (20, 2) - MATCHES TradingView/Indodax Charts
// Uses POPULATION standard deviation (divides by N, not N-1)
function calculateBollingerBands(candles, period = 20, stdDevMultiplier = 2) {
    if (!candles || candles.length < period) {
        console.warn('⚠️ Insufficient candles for BB(20,2). Need:', period, 'Have:', candles ? candles.length : 0);
        
        // Fallback for insufficient data
        if (candles && candles.length > 0) {
            const closes = candles.map(c => c.close);
            const high = Math.max(...closes);
            const low = Math.min(...closes);
            const mid = (high + low) / 2;
            const range = high - low;
            
            return {
                upper: mid + (range / 2),
                middle: mid,
                lower: mid - (range / 2),
                stdDev: range / 4,
                posPercent: 50,
                dataSource: 'FALLBACK'
            };
        }
        
        return {
            upper: 0,
            middle: 0,
            lower: 0,
            stdDev: 0,
            posPercent: 50,
            dataSource: 'EMPTY'
        };
    }
    
    // ========================================
    // STEP 1: Get LAST 20 candles (most recent)
    // ========================================
    const recentCandles = candles.slice(-period);
    const closes = recentCandles.map(c => c.close);
    
    // ========================================
    // STEP 2: Calculate SMA (Simple Moving Average)
    // This becomes the MIDDLE BAND
    // ========================================
    let sum = 0;
    for (let i = 0; i < closes.length; i++) {
        sum += closes[i];
    }
    const sma = sum / period;
    
    // ========================================
    // STEP 3: Calculate POPULATION Standard Deviation
    // CRITICAL: Use N (not N-1) to match TradingView
    // ========================================
    
    // Calculate sum of squared differences from mean
    let sumSquaredDifferences = 0;
    for (let i = 0; i < closes.length; i++) {
        const difference = closes[i] - sma;
        sumSquaredDifferences += difference * difference;
    }
    
    // POPULATION Variance = Sum of squared differences / N
    // (NOT N-1 which is SAMPLE variance)
    const populationVariance = sumSquaredDifferences / period;
    
    // Standard Deviation = Square root of variance
    const stdDev = Math.sqrt(populationVariance);
    
    // ========================================
    // STEP 4: Calculate Upper and Lower Bands
    // ========================================
    const upperBand = sma + (stdDevMultiplier * stdDev);
    const lowerBand = sma - (stdDevMultiplier * stdDev);
    
    // ========================================
    // STEP 5: Calculate current price position (0-100%)
    // ========================================
    const currentClose = candles[candles.length - 1].close;
    let posPercent = 50;
    
    const bandWidth = upperBand - lowerBand;
    if (bandWidth > 0) {
        posPercent = ((currentClose - lowerBand) / bandWidth) * 100;
        // Clamp between 0 and 100
        posPercent = Math.max(0, Math.min(100, posPercent));
    }
    
    // ========================================
    // DEBUG LOGGING: Verify calculation
    // ========================================
    const pairName = candles[0]?.pair || 'Unknown';
    console.log('📊 BB(20,2) Calculation for', pairName, {
        currentClose: currentClose,
        sma: sma.toFixed(2),
        stdDev: stdDev.toFixed(2),
        upper: upperBand.toFixed(2),
        middle: sma.toFixed(2),
        lower: lowerBand.toFixed(2),
        position: posPercent.toFixed(1) + '%',
        bandWidth: bandWidth.toFixed(2),
        candleCount: candles.length,
        last5Closes: closes.slice(-5).map(c => c.toFixed(2)),
        calculationType: 'POPULATION_STDEV'
    });
    
    return {
        upper: upperBand,
        middle: sma,
        lower: lowerBand,
        stdDev: stdDev,
        posPercent: posPercent,
        dataSource: 'CALCULATED',
        candleCount: candles.length
    };
}

// Verification: Compare calculated BB with expected chart values
// Use this to test against TradingView/Indodax chart readings
function verifyBBCalculation(candles, expectedUpper, expectedMiddle, expectedLower, tolerance = 0.02) {
    if (!candles || candles.length < 20) {
        console.error('❌ Cannot verify: Need at least 20 candles');
        return false;
    }
    
    const bbData = calculateBollingerBands(candles, 20, 2);
    
    // Calculate percentage differences
    const upperDiff = Math.abs((bbData.upper - expectedUpper) / expectedUpper);
    const middleDiff = Math.abs((bbData.middle - expectedMiddle) / expectedMiddle);
    const lowerDiff = Math.abs((bbData.lower - expectedLower) / expectedLower);
    
    const upperMatch = upperDiff < tolerance;
    const middleMatch = middleDiff < tolerance;
    const lowerMatch = lowerDiff < tolerance;
    
    const allMatch = upperMatch && middleMatch && lowerMatch;
    
    console.log('🔍 BB(20,2) Verification:', {
        pair: candles[0]?.pair || 'Unknown',
        calculated: {
            upper: bbData.upper.toFixed(2),
            middle: bbData.middle.toFixed(2),
            lower: bbData.lower.toFixed(2)
        },
        expected: {
            upper: expectedUpper.toFixed(2),
            middle: expectedMiddle.toFixed(2),
            lower: expectedLower.toFixed(2)
        },
        difference: {
            upper: (upperDiff * 100).toFixed(2) + '%',
            middle: (middleDiff * 100).toFixed(2) + '%',
            lower: (lowerDiff * 100).toFixed(2) + '%'
        },
        match: {
            upper: upperMatch ? '✅' : '❌',
            middle: middleMatch ? '✅' : '❌',
            lower: lowerMatch ? '✅' : '❌',
            overall: allMatch ? '✅ PASS' : '❌ FAIL'
        },
        tolerance: (tolerance * 100).toFixed(1) + '%'
    });
    
    return allMatch;
}

/*
 * Indicator Settings for Signal Analysis:
 * - RSI: Period 14, SMA 14
 * - Stochastic RSI: 14 14 3 3 (RSI Period 14, Stoch Period 14, SmoothK 3, SmoothD 3)
 * - Volume: SMA 9
 * - MACD: 12, 26, Close, 9 (Fast EMA 12, Slow EMA 26, Signal 9)
 * - Momentum: Period 10
 * - Bollinger Bands: Period 20, StdDev 2
 */
function analyzeSignalAdvanced(ticker, avgVolume, timeframe = '1h', candles = null) {
  let score = 0;
  let signals = [];
  let type = 'HOLD';
  
  const tfMultipliers = {
    '15m': { sensitivity: 1.8, volatility: 1.5, trendThreshold: 1.2, name: '15 Minute' },
    '30m': { sensitivity: 1.6, volatility: 1.4, trendThreshold: 1.3, name: '30 Minute' },
    '1h': { sensitivity: 1.4, volatility: 1.3, trendThreshold: 1.5, name: '1 Hour' },
    '2h': { sensitivity: 1.2, volatility: 1.2, trendThreshold: 1.6, name: '2 Hours' },
    '4h': { sensitivity: 1.0, volatility: 1.0, trendThreshold: 1.8, name: '4 Hours' },
    '1d': { sensitivity: 0.8, volatility: 0.9, trendThreshold: 2.0, name: '1 Day' },
    '3d': { sensitivity: 0.6, volatility: 0.7, trendThreshold: 2.5, name: '3 Days' },
    '1w': { sensitivity: 0.5, volatility: 0.6, trendThreshold: 3.0, name: '1 Week' },
    '2w': { sensitivity: 0.4, volatility: 0.5, trendThreshold: 3.5, name: '2 Week' },
    '1m': { sensitivity: 0.3, volatility: 0.4, trendThreshold: 4.0, name: '1 Month' }
  };
  
  const tfConfig = tfMultipliers[timeframe] || tfMultipliers['1h'];
  
  const pricePosition = ((ticker.last - ticker.low) / (ticker.high - ticker.low)) * 100 || 50;
  
  // Momentum calculation - Using price change percent as proxy for momentum indicator
  // When candle data is available, calculateMomentum function uses 10-period
  const momentum = ticker.priceChangePercent * tfConfig.sensitivity;
  let rsiProxy = 50;
  
  if (momentum > 0) {
    rsiProxy = 50 + Math.min(momentum * 3, 50);
  } else {
    rsiProxy = 50 + Math.max(momentum * 3, -50);
  }
  rsiProxy = Math.max(0, Math.min(100, rsiProxy));
  
  const stochRSI = pricePosition;
  
  // Calculate volatility safely to avoid division by zero
  const avgPrice = (ticker.high + ticker.low) / 2;
  const volatility = avgPrice > 0 
    ? ((ticker.high - ticker.low) / avgPrice) * 100 * tfConfig.volatility 
    : 0;
  
  // Calculate Bollinger Bands - use true BB(20,2) when candles available
  let bbSignal = 'NEUTRAL';
  let bbData = { upper: 0, middle: 0, lower: 0, posPercent: 50 };
  let bbPercent = 50;
  
  if (candles && candles.length >= 20) {
    // Use CORRECTED BB calculation with population stdev
    bbData = calculateBollingerBands(candles, 20, 2);
    bbPercent = bbData.posPercent;
    
    // Determine BB signal based on position
    if (bbPercent >= 90) bbSignal = 'EXTREME_OVERBOUGHT';
    else if (bbPercent >= 80) bbSignal = 'OVERBOUGHT';
    else if (bbPercent >= 60) bbSignal = 'ABOVE_MID';
    else if (bbPercent >= 40) bbSignal = 'NEUTRAL';
    else if (bbPercent >= 20) bbSignal = 'BELOW_MID';
    else if (bbPercent >= 10) bbSignal = 'OVERSOLD';
    else bbSignal = 'EXTREME_OVERSOLD';
  } else {
    // Fallback if insufficient candles
    const pricePosition = ((ticker.last - ticker.low) / (ticker.high - ticker.low)) * 100 || 50;
    bbPercent = pricePosition;
    if (pricePosition >= 80) bbSignal = 'OVERBOUGHT';
    else if (pricePosition >= 60) bbSignal = 'ABOVE_MID';
    else if (pricePosition >= 40) bbSignal = 'NEUTRAL';
    else if (pricePosition >= 20) bbSignal = 'BELOW_MID';
    else bbSignal = 'OVERSOLD';
  }
  
  const volumeRatio = ticker.volume / avgVolume;
  
  let orderBookPressure = 'NEUTRAL';
  if (ticker.buy > 0 && ticker.sell > 0) {
    const spread = ((ticker.sell - ticker.buy) / ticker.buy) * 100;
    if (spread < -2) {
      orderBookPressure = 'BUY_PRESSURE';
    } else if (spread > 2) {
      orderBookPressure = 'SELL_PRESSURE';
    }
  }
  
  // Detect trend - use candle patterns if available, otherwise use momentum
  let trend = 'SIDEWAYS';
  if (candles && candles.length >= 10) {
    trend = detectTrendFromCandles(candles);
  } else {
    // Fallback to momentum-based trend detection
    if (momentum > tfConfig.trendThreshold) {
      trend = 'UPTREND';
    } else if (momentum < -tfConfig.trendThreshold) {
      trend = 'DOWNTREND';
    }
  }
  
  // MACD proxy - use price position relative to midpoint and volume for more independence
  // This makes it different from pure momentum
  const midPoint = (ticker.high + ticker.low) / 2;
  const priceVsMid = ((ticker.last - midPoint) / midPoint) * 100;
  const volumeBoost = volumeRatio > 1.2 ? 1.5 : 1.0;
  const macd = priceVsMid * volumeBoost * tfConfig.sensitivity;
  
  const rsiOversoldThreshold = 30 + (tfConfig.sensitivity - 1) * 10;
  const rsiOverboughtThreshold = 70 - (tfConfig.sensitivity - 1) * 10;
  
  if (rsiProxy < rsiOversoldThreshold) {
    score += 25;
    signals.push('📊 RSI Oversold');
  } else if (rsiProxy < 40) {
    score += 15;
    signals.push('📊 RSI Low');
  } else if (rsiProxy > rsiOverboughtThreshold) {
    score += 25;
    signals.push('⚠️ RSI Overbought');
  } else if (rsiProxy > 60) {
    score += 15;
    signals.push('⚠️ RSI High');
  } else {
    score += 5;
    signals.push('📊 RSI Neutral');
  }
  
  if (stochRSI < 20) {
    score += 20;
    signals.push('🎯 StochRSI Oversold');
  } else if (stochRSI < 30) {
    score += 12;
    signals.push('🎯 StochRSI Low');
  } else if (stochRSI > 80) {
    score += 20;
    signals.push('⚠️ StochRSI Overbought');
  } else if (stochRSI > 70) {
    score += 12;
    signals.push('⚠️ StochRSI High');
  } else {
    score += 5;
    signals.push('🎯 StochRSI Mid');
  }
  
  if (bbSignal === 'OVERSOLD') {
    score += 25;
    signals.push('📉 BB: Near Lower');
  } else if (bbSignal === 'OVERBOUGHT') {
    score += 25;
    signals.push('📈 BB: Near Upper');
  } else if (bbSignal === 'BELOW_MID') {
    score += 10;
    signals.push('📍 BB: Below Mid');
  } else if (bbSignal === 'ABOVE_MID') {
    score += 10;
    signals.push('📍 BB: Above Mid');
  } else {
    score += 5;
  }
  
  if (volumeRatio > 3) {
    score += 15;
    signals.push('🔥 Vol Spike');
  } else if (volumeRatio > 2) {
    score += 10;
    signals.push('📈 High Vol');
  } else if (volumeRatio > 1.5) {
    score += 7;
    signals.push('✅ Above Avg');
  } else if (volumeRatio > 0.5) {
    score += 3;
  }
  
  const absM = Math.abs(momentum);
  if (absM > 10) {
    score += 15;
    signals.push(momentum > 0 ? '🚀 Strong+' : '📉 Strong-');
  } else if (absM > 5) {
    score += 10;
    signals.push(momentum > 0 ? '↗️ Momentum+' : '↘️ Momentum-');
  } else if (absM > 2) {
    score += 5;
  }
  
  if (momentum > 0 || rsiProxy < 50 || stochRSI < 50 || bbSignal === 'OVERSOLD' || bbSignal === 'BELOW_MID') {
    type = 'BUY';
    
    if (rsiProxy < rsiOversoldThreshold && stochRSI < 20) {
      signals.push('✨ STRONG BUY');
    } else if (rsiProxy < 40 && momentum > 2 * tfConfig.sensitivity) {
      signals.push('💡 BUY Signal');
    } else if (bbSignal === 'OVERSOLD') {
      signals.push('🎯 Oversold Bounce');
    } else {
      signals.push('✅ Potential Buy');
    }
  }
  
  if (momentum < 0 || rsiProxy > 50 || stochRSI > 50 || bbSignal === 'OVERBOUGHT' || bbSignal === 'ABOVE_MID') {
    if (type === 'BUY') {
      const bullishScore = (momentum > 0 ? 1 : 0) + (rsiProxy < 50 ? 1 : 0) + (stochRSI < 50 ? 1 : 0);
      const bearishScore = (momentum < 0 ? 1 : 0) + (rsiProxy > 50 ? 1 : 0) + (stochRSI > 50 ? 1 : 0);
      
      if (bearishScore > bullishScore) {
        type = 'SELL';
        signals = signals.filter(s => !s.includes('BUY') && !s.includes('Buy'));
      }
    } else {
      type = 'SELL';
    }
    
    if (type === 'SELL') {
      if (rsiProxy > rsiOverboughtThreshold && stochRSI > 80) {
        signals.push('⚠️ STRONG SELL');
      } else if (rsiProxy > 60 && momentum < -2 * tfConfig.sensitivity) {
        signals.push('📉 SELL Signal');
      } else if (bbSignal === 'OVERBOUGHT') {
        signals.push('🎯 Overbought Drop');
      } else {
        signals.push('⚠️ Potential Sell');
      }
    }
  }
  
  if (type === 'HOLD') {
    type = pricePosition < 50 ? 'BUY' : 'SELL';
    signals.push(type === 'BUY' ? '✅ Below Mid' : '⚠️ Above Mid');
  }
  
  if (type === 'BUY' && orderBookPressure === 'BUY_PRESSURE') {
    signals.push('📥 Buy Support');
  }
  if (type === 'SELL' && orderBookPressure === 'SELL_PRESSURE') {
    signals.push('📤 Sell Pressure');
  }
  
  const finalScore = Math.min(score, 100);
  
  // Calculate bullish/bearish counts for the new 8-indicator system
  let bullishCount = 0;
  let bearishCount = 0;
  
  // 1. RSI
  if (rsiProxy < 30) bullishCount++;
  else if (rsiProxy > 70) bearishCount++;
  
  // 2. StochRSI
  if (stochRSI < 20) bullishCount++;
  else if (stochRSI > 80) bearishCount++;
  
  // 3. BB
  if (bbSignal === 'OVERSOLD') bullishCount++;
  else if (bbSignal === 'OVERBOUGHT') bearishCount++;
  
  // 4. MACD
  if (macd > 0) bullishCount++;
  else if (macd < 0) bearishCount++;
  
  // 5. Volume
  const priceUp = ticker.priceChangePercent > 0;
  const priceDown = ticker.priceChangePercent < 0;
  const volumeSpike = volumeRatio > 1.5;
  if (volumeSpike && priceUp) bullishCount++;
  else if (volumeSpike && priceDown) bearishCount++;
  
  // 6. Momentum
  if (momentum > 0) bullishCount++;
  else if (momentum < 0) bearishCount++;
  
  // 7. BB Position (Support/Resistance)
  const bbPosition = calculateBBPositionForRecommendation(ticker, ticker.high, ticker.low, timeframe);
  if (bbPosition.nearSupport) bullishCount++;
  else if (bbPosition.nearResistance) bearishCount++;
  
  // 8. Trend
  if (trend === 'UPTREND') bullishCount++;
  else if (trend === 'DOWNTREND') bearishCount++;
  
  // Calculate win rate
  const totalIndicators = 8;
  let winRate;
  if (bullishCount > bearishCount) {
    winRate = (bullishCount / totalIndicators) * 100;
  } else if (bearishCount > bullishCount) {
    winRate = (bearishCount / totalIndicators) * 100;
  } else {
    winRate = 50;
  }
  
  // Get recommendation using new system
  const recommendationData = getRecommendation(ticker, bullishCount, bearishCount, Math.round(winRate), trend, timeframe, avgVolume);
  const recommendation = recommendationData.text;
  
  return {
    type,
    timeframe: tfConfig.name,
    score: finalScore,
    recommendation: recommendation,
    signals,
    bullishCount,
    bearishCount,
    winRate: Math.round(winRate),
    indicators: {
      rsi: rsiProxy.toFixed(1),
      stochRSI: stochRSI.toFixed(1),
      bbPosition: bbSignal,
      macd: macd.toFixed(1),
      momentum: momentum.toFixed(2),
      volumeRatio: volumeRatio.toFixed(2),
      volatility: volatility.toFixed(2),
      pricePosition: pricePosition.toFixed(0),
      orderPressure: orderBookPressure,
      trend: trend,
      volumeSpike: volumeSpike,
      priceUp: priceUp,
      priceDown: priceDown
    }
  };
}

async function getTickerHistory(pair) {
  try {
    const response = await fetch(`${INDODAX_API_BASE}/trades/${pair}`);
    const trades = await response.json();
    
    return new Response(JSON.stringify({
      success: true,
      pair: pair,
      trades: Array.isArray(trades) ? trades.slice(0, 100) : []
    }), {
      headers: { 
        'content-type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-cache'
      },
    });
    
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { 'content-type': 'application/json' },
    });
  }
}

function getHTML() {
  return `<!DOCTYPE html>
<html lang="id">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Indodax Market Analyzer - Signal Analysis</title>
    <style>
        /* ============================================================
           CSS VARIABLES - CONSISTENT FONT SIZES
           ============================================================ */
        :root {
            --font-xs: 10px;
            --font-sm: 12px;
            --font-base: 14px;
            --font-lg: 16px;
            --font-xl: 18px;
        }
        
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #0f0f1e;
            color: #e0e0e0;
            min-height: 100vh;
            padding: 20px;
            font-size: var(--font-base) !important;
        }
        .container {
            max-width: 1600px;
            margin: 0 auto;
        }
        .header {
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding: 30px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            margin-bottom: 20px;
            border: 1px solid #2a2a3e;
        }
        h1 {
            color: #4ade80;
            margin-bottom: 10px;
            font-size: 2.5em;
            display: flex;
            align-items: center;
            gap: 15px;
            flex-wrap: wrap;
        }
        .live-badge {
            background: #ef4444;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: var(--font-base) !important;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        
        /* FLASH ANIMATIONS - Stock Exchange Style */
        @keyframes flash-green {
            0% { 
                background-color: rgba(74, 222, 128, 0.8);
                box-shadow: 0 0 10px rgba(74, 222, 128, 0.6);
            }
            100% { 
                background-color: transparent;
                box-shadow: none;
            }
        }
        
        @keyframes flash-red {
            0% { 
                background-color: rgba(239, 68, 68, 0.8);
                box-shadow: 0 0 10px rgba(239, 68, 68, 0.6);
            }
            100% { 
                background-color: transparent;
                box-shadow: none;
            }
        }
        
        .flash-up {
            animation: flash-green 0.8s ease-out;
        }
        
        .flash-down {
            animation: flash-red 0.8s ease-out;
        }
        
        @keyframes pulse-volume {
            0%, 100% { 
                box-shadow: 0 0 5px rgba(74, 222, 128, 0.5);
                transform: scale(1);
            }
            50% { 
                box-shadow: 0 0 15px rgba(74, 222, 128, 0.8);
                transform: scale(1.02);
            }
        }
        
        .volume-spike {
            animation: pulse-volume 1.5s ease-in-out infinite;
            font-weight: bold;
        }
        
        .subtitle {
            color: #9ca3af;
            font-size: var(--font-lg) !important;
        }
        .usdt-rate {
            color: #fbbf24;
            font-size: var(--font-base) !important;
            margin-top: 10px;
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin-bottom: 20px;
            align-items: start;
        }
        .stat-card {
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding: 25px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            border: 1px solid #2a2a3e;
            transition: transform 0.3s, border-color 0.3s;
            display: flex;
            flex-direction: column;
            height: 100%;
        }
        .stat-card:hover {
            transform: translateY(-5px);
            border-color: #4ade80;
        }
        .stat-label {
            color: #9ca3af;
            font-size: var(--font-base) !important;
            margin-bottom: 8px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        .stat-value {
            color: #4ade80;
            font-size: 32px;
            font-weight: bold;
        }
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        .tab {
            padding: 12px 25px;
            background: #1a1a2e;
            border: 1px solid #2a2a3e;
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.3s;
            color: #9ca3af;
            font-weight: 500;
        }
        .tab.active {
            background: linear-gradient(135deg, #4ade80 0%, #22c55e 100%);
            color: white;
            border-color: #4ade80;
        }
        .tab:hover {
            border-color: #4ade80;
        }
        .timeframe-selector {
            display: flex;
            gap: 8px;
            margin-bottom: 15px;
            flex-wrap: wrap;
            padding: 15px;
            background: #0f0f1e;
            border-radius: 8px;
        }
        .tf-btn {
            padding: 8px 16px;
            background: #1a1a2e;
            border: 1px solid #2a2a3e;
            border-radius: 6px;
            cursor: pointer;
            color: #9ca3af;
            font-size: var(--font-sm) !important;
            font-weight: 600;
            transition: all 0.2s;
        }
        .tf-btn:hover {
            border-color: #4ade80;
            color: #4ade80;
        }
        .tf-btn.active {
            background: #4ade80;
            color: #0f0f1e;
            border-color: #4ade80;
        }
        .table-card {
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding: 25px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.5);
            border: 1px solid #2a2a3e;
            margin-bottom: 20px;
        }
        .table-title {
            font-size: var(--font-xl) !important;
            font-weight: bold;
            margin-bottom: 15px;
            color: #4ade80;
            position: sticky;
            top: 0;
            z-index: 70;
            background-color: #1a1a2e;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            padding-top: 5px;
            padding-bottom: 15px;
        }
        .search-box {
            width: 100%;
            padding: 12px;
            background: #0f0f1e;
            border: 1px solid #2a2a3e;
            border-radius: 8px;
            color: #e0e0e0;
            font-size: var(--font-base) !important;
            margin-bottom: 15px;
            position: sticky;
            top: 45px;
            z-index: 65;
        }
        .search-box:focus {
            outline: none;
            border-color: #4ade80;
        }
        .table-wrapper {
            position: relative;
            overflow-x: auto;
            max-height: 600px;
            overflow-y: auto;
            border-radius: 8px;
            background: #0f0f1e;
            scroll-behavior: auto;
            -webkit-overflow-scrolling: touch;
            overscroll-behavior: contain;
        }
        .table-wrapper::-webkit-scrollbar {
            width: 8px;
            height: 8px;
        }
        .table-wrapper::-webkit-scrollbar-track {
            background: #0f0f1e;
            border-radius: 4px;
        }
        .table-wrapper::-webkit-scrollbar-thumb {
            background: #4ade80;
            border-radius: 4px;
        }
        .table-wrapper::-webkit-scrollbar-thumb:hover {
            background: #22c55e;
        }
        table {
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            transform: translateZ(0);
            will-change: transform;
            font-size: var(--font-base) !important;
        }
        thead {
            position: sticky;
            top: 0;
            z-index: 100;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #2a2a3e;
            transition: background-color 0.2s;
            font-size: var(--font-base) !important;
        }
        th {
            background: #0f0f1e !important;
            font-weight: bold;
            color: #4ade80;
            border-bottom: 2px solid #2a2a3e;
            cursor: pointer;
            user-select: none;
            white-space: nowrap;
            font-size: var(--font-base) !important;
        }
        th:hover {
            background: #1a1a2e !important;
        }
        th.sortable {
            position: relative;
            padding-right: 25px;
        }
        th.sortable::after {
            content: '⇅';
            position: absolute;
            right: 8px;
            opacity: 0.3;
            font-size: var(--font-sm) !important;
        }
        th.sortable.asc::after {
            content: '▲';
            opacity: 1;
        }
        th.sortable.desc::after {
            content: '▼';
            opacity: 1;
        }
        tbody tr {
            background: transparent;
        }
        tbody tr:hover {
            background: #1f1f2e;
        }
        .positive {
            color: #4ade80;
            font-weight: 600;
        }
        .negative {
            color: #ef4444;
            font-weight: 600;
        }
        .usdt-badge {
            background: #fbbf24;
            color: #0f0f1e;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: var(--font-xs) !important;
            font-weight: bold;
            margin-left: 5px;
        }
        .signal-score {
            font-size: var(--font-xl) !important;
            font-weight: bold;
        }
        .signal-indicators {
            font-size: 10px !important;
            color: #9ca3af;
            margin-top: 2px;
            line-height: 1.2;
            display: flex;
            flex-wrap: wrap;
            gap: 2px;
            align-items: center;
        }
        .indicator-badge {
            display: inline-block;
            padding: 1px 4px;
            border-radius: 3px;
            font-size: 9px !important;
            font-weight: bold;
            white-space: nowrap;
        }
        .rsi-oversold {
            background: #22c55e;
            color: white;
        }
        .rsi-overbought {
            background: #ef4444;
            color: white;
        }
        .rsi-neutral {
            background: #6b7280;
            color: white;
        }
        .bb-lower {
            background: #3b82f6;
            color: white;
        }
        .bb-upper {
            background: #f59e0b;
            color: white;
        }
        .stochrsi-badge {
            background: #7c3aed;
            color: white;
        }
        .volume-badge {
            background: #0891b2;
            color: white;
        }
        .volatility-badge {
            background: #db2777;
            color: white;
        }
        .tf-badge {
            background: #8b5cf6;
            color: white;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: var(--font-xs) !important;
            font-weight: bold;
            margin-left: 8px;
        }
        .recommendation-badge {
            display: inline-block;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: var(--font-xs) !important;
            font-weight: bold;
            margin-top: 4px;
            text-transform: uppercase;
        }
        .recommendation-badge.buy-now {
            background: #10b981;
            color: white;
        }
        .recommendation-badge.buy-strong {
            background: #22c55e;
            color: white;
        }
        .recommendation-badge.hold {
            background: #6b7280;
            color: white;
        }
        .recommendation-badge.hold-sideway {
            background: #9ca3af;
            color: #1f1f2e;
        }
        .recommendation-badge.sell-strong {
            background: #f97316;
            color: white;
        }
        .recommendation-badge.sell-now {
            background: #ef4444;
            color: white;
        }
        .recommendation-badge.buy-watch {
            background: #84cc16;
            color: white;
        }
        .recommendation-badge.sell-watch {
            background: #fb923c;
            color: white;
        }
        .recommendation-badge.accumulate {
            background: #06b6d4;
            color: white;
        }
        .recommendation-badge.distribute {
            background: #f472b6;
            color: white;
        }
        .recommendation-badge.wait {
            background: #6b7280;
            color: white;
        }
        
        /* New recommendation badges for 15-status system */
        .recommendation-badge.strong-buy {
            background: linear-gradient(135deg, #10b981 0%, #059669 100%);
            color: white;
        }
        .recommendation-badge.buy-now {
            background: #10b981;
            color: white;
        }
        .recommendation-badge.buy {
            background: #22c55e;
            color: white;
        }
        .recommendation-badge.watch-buy {
            background: #fbbf24;
            color: #1f1f2e;
        }
        .recommendation-badge.wait-buy {
            background: #fcd34d;
            color: #1f1f2e;
        }
        .recommendation-badge.strong-sell {
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
            color: white;
        }
        .recommendation-badge.sell-now {
            background: #ef4444;
            color: white;
        }
        .recommendation-badge.sell {
            background: #f97316;
            color: white;
        }
        .recommendation-badge.watch-sell {
            background: #fb923c;
            color: white;
        }
        .recommendation-badge.wait-sell {
            background: #fdba74;
            color: #1f1f2e;
        }
        .recommendation-badge.sideways {
            background: #6b7280;
            color: white;
        }
        
        /* Vertical signals and technical indicators layout */
        .signals-list,
        .technical-list {
            display: flex;
            flex-direction: column;
            gap: 4px;
        }
        
        .signal-item,
        .tech-item {
            font-size: 11px !important;
            white-space: nowrap;
            padding: 2px 0;
            line-height: 1.3;
        }
        
        .signal-item.bullish {
            color: #4ade80;
        }
        
        .signal-item.bearish {
            color: #ef4444;
        }
        
        .signal-item.neutral {
            color: #9ca3af;
        }
        
        .signals-cell,
        .technical-cell {
            font-size: 11px !important;
            max-width: 280px;
        }
        
        .loading {
            text-align: center;
            color: #4ade80;
            font-size: 18px;
            padding: 40px;
        }
        .error {
            background: #ef4444;
            color: white;
            padding: 20px;
            border-radius: 8px;
            margin: 20px 0;
            text-align: center;
        }
        .content-section {
            display: none;
        }
        .content-section.active {
            display: block;
        }
        .count-badge {
            background: #3b82f6;
            color: white;
            padding: 4px 12px;
            border-radius: 15px;
            font-size: var(--font-base) !important;
            font-weight: 600;
            margin-left: 10px;
        }
        .paused-badge {
            background: #f59e0b;
            color: white;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: var(--font-sm) !important;
            margin-left: 10px;
        }
        
        /* ============================================================
           SIGNAL TABS - BUY/SELL TOGGLE
           ============================================================ */
        .signal-tabs {
            display: flex;
            gap: 6px;
            margin-bottom: 10px;
            flex-wrap: wrap;
        }
        .signal-tab {
            padding: 6px 12px;
            background: #1a1a2e;
            border: 1px solid #2a2a3e;
            border-radius: 6px;
            cursor: pointer;
            color: #9ca3af;
            font-size: 11px !important;
            font-weight: 600;
            transition: all 0.3s;
        }
        .signal-tab.active-buy {
            background: linear-gradient(135deg, #22c55e 0%, #16a34a 100%);
            color: white;
            border-color: #22c55e;
        }
        .signal-tab.active-sell {
            background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%);
            color: white;
            border-color: #ef4444;
        }
        .signal-tab:hover {
            border-color: #4ade80;
        }
        .signal-content {
            display: none;
        }
        .signal-content.active {
            display: block;
        }
        
        /* ============================================================
           NEW FEATURES STYLES
           ============================================================ */
        
        /* Risk Badge */
        .risk-badge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            padding: 3px 8px;
            border-radius: 4px;
            font-size: var(--font-xs);
            font-weight: bold;
        }
        .risk-very-high {
            background: rgba(220, 38, 38, 0.3);
            color: #dc2626;
            border: 1px solid #dc2626;
        }
        .risk-high {
            background: rgba(239, 68, 68, 0.2);
            color: #ef4444;
            border: 1px solid #ef4444;
        }
        .risk-medium {
            background: rgba(245, 158, 11, 0.2);
            color: #f59e0b;
            border: 1px solid #f59e0b;
        }
        .risk-low {
            background: rgba(34, 197, 94, 0.2);
            color: #22c55e;
            border: 1px solid #22c55e;
        }
        
        /* Targets Info */
        .targets-info {
            background: #0f0f1e;
            border: 1px solid #2a2a3e;
            border-radius: 8px;
            padding: 12px;
            margin-top: 8px;
        }
        .target-row {
            display: flex;
            justify-content: space-between;
            padding: 4px 0;
            font-size: var(--font-sm);
        }
        .target-label {
            color: #9ca3af;
        }
        .target-value {
            font-weight: 600;
        }
        .target-row.stop-loss {
            border-bottom: 1px solid #2a2a3e;
            padding-bottom: 8px;
            margin-bottom: 4px;
        }
        
        @media (max-width: 768px) {
            h1 { font-size: 1.8em; }
            table { font-size: 12px; }
            th, td { padding: 8px; }
        }

        /* ============================================================
           RESPONSIVE: TABLET (max-width: 1024px)
           ============================================================ */
        @media (max-width: 1024px) {
            :root {
                --font-xs: 9px;
                --font-sm: 11px;
                --font-base: 13px;
                --font-lg: 15px;
                --font-xl: 16px;
            }
            
            body {
                padding: 16px;
            }
            .container {
                max-width: 100%;
            }
            .header {
                padding: 22px 20px;
                border-radius: 12px;
            }
            h1 {
                font-size: 2em;
                gap: 10px;
            }
            .stats-grid {
                grid-template-columns: repeat(2, 1fr);
                gap: 14px;
            }
            .stat-card {
                padding: 18px;
            }
            .stat-value {
                font-size: 26px;
            }
            .tabs {
                gap: 8px;
            }
            .tab {
                padding: 10px 18px;
            }
            .table-card {
                padding: 18px;
                border-radius: 12px;
            }
            .table-wrapper {
                max-height: 500px;
            }
            th, td {
                padding: 10px 8px;
            }
        }

        /* ============================================================
           RESPONSIVE: MOBILE (max-width: 768px)
           ============================================================ */
        @media (max-width: 768px) {
            :root {
                --font-xs: 8px;
                --font-sm: 10px;
                --font-base: 12px;
                --font-lg: 14px;
                --font-xl: 15px;
            }
            
            body {
                padding: 10px;
                min-height: 100vh;
                min-height: -webkit-fill-available;
            }
            .container {
                max-width: 100%;
                padding: 0;
            }

            /* --- Header --- */
            .header {
                padding: 16px 14px;
                border-radius: 10px;
                margin-bottom: 12px;
            }
            h1 {
                font-size: 1.45em;
                gap: 8px;
                margin-bottom: 6px;
                flex-wrap: wrap;
                align-items: center;
            }
            .live-badge {
                padding: 3px 10px;
            }
            .paused-badge {
                padding: 3px 9px;
                margin-left: 6px;
            }
            .subtitle {
                margin-top: 4px;
            }
            .usdt-rate {
                margin-top: 6px;
            }

            /* --- Stats Grid: 2x2 on mobile --- */
            .stats-grid {
                display: grid;
                grid-template-columns: repeat(2, 1fr);
                gap: 8px;
                margin-bottom: 12px;
            }
            .stat-card {
                padding: 12px 10px;
                border-radius: 10px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.4);
            }
            .stat-card:hover {
                transform: none;
            }
            .stat-label {
                letter-spacing: 0.5px;
                margin-bottom: 4px;
            }
            .stat-value {
                font-size: 18px;
            }
            #lastUpdate {
                font-size: 13px !important;
            }

            /* --- Tabs: horizontal scroll row --- */
            .tabs {
                display: flex;
                gap: 6px;
                margin-bottom: 12px;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
                flex-wrap: nowrap;
                padding-bottom: 6px;
                scrollbar-width: none;
            }
            .tabs::-webkit-scrollbar {
                display: none;
            }
            .tab {
                padding: 9px 14px;
                border-radius: 6px;
                white-space: nowrap;
                flex-shrink: 0;
            }
            .count-badge {
                padding: 2px 7px;
                margin-left: 5px;
            }

            /* --- Timeframe Selector: scroll row --- */
            .timeframe-selector {
                display: flex;
                gap: 5px;
                padding: 10px 8px;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
                flex-wrap: nowrap;
                border-radius: 6px;
                margin-bottom: 10px;
                scrollbar-width: none;
            }
            .timeframe-selector::-webkit-scrollbar {
                display: none;
            }
            .timeframe-selector > span {
                display: none;
            }
            .tf-btn {
                padding: 6px 11px;
                border-radius: 5px;
                white-space: nowrap;
                flex-shrink: 0;
            }

            /* --- Table Card --- */
            .table-card {
                padding: 12px 10px;
                border-radius: 10px;
                margin-bottom: 14px;
                box-shadow: 0 6px 18px rgba(0,0,0,0.45);
            }
            .table-title {
                font-size: 15px;
                margin-bottom: 10px;
            }
            .search-box {
                padding: 9px 10px;
                border-radius: 6px;
                margin-bottom: 10px;
            }

            /* --- Table wrapper & scrolling --- */
            .table-wrapper {
                max-height: 420px;
                border-radius: 6px;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
            }
            .table-wrapper::-webkit-scrollbar {
                width: 4px;
                height: 4px;
            }

            /* --- Table cells --- */
            table {
                min-width: 540px;     /* enforce horizontal scroll threshold on mobile */
            }
            th, td {
                padding: 8px 6px;
                white-space: nowrap;
            }
            th.sortable {
                padding-right: 18px;
            }
            th.sortable::after {
                right: 4px;
            }

            /* --- Pair name clamping --- */
            td strong {
                max-width: 72px;
                display: inline-block;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                vertical-align: middle;
            }
            .usdt-badge {
                padding: 1px 4px;
            }
            .tf-badge {
                padding: 1px 5px;
                margin-left: 4px;
            }
            .recommendation-badge {
                padding: 2px 5px;
                margin-top: 2px;
            }

            /* --- Signal score --- */
            .signal-score {
                font-size: 15px;
            }

            /* --- Indicator badges --- */
            .signal-indicators {
                line-height: 1.5;
            }
            .indicator-badge {
                padding: 1px 4px;
                margin-right: 2px;
                margin-bottom: 2px;
            }

            /* --- Loading / Error --- */
            .loading {
                font-size: 15px;
                padding: 30px 10px;
            }
            .error {
                padding: 14px;
                font-size: 13px;
                border-radius: 8px;
            }
        }

        /* ============================================================
           RESPONSIVE: SMALL MOBILE (max-width: 420px)
           ============================================================ */
        @media (max-width: 420px) {
            body {
                padding: 6px;
            }
            .header {
                padding: 12px 10px;
                border-radius: 8px;
            }
            h1 {
                font-size: 1.2em;
                gap: 6px;
            }
            .live-badge {
                padding: 2px 7px;
            }
            .subtitle {
            }
            .usdt-rate {
            }

            /* Stats: still 2-col but tighter */
            .stats-grid {
                gap: 5px;
            }
            .stat-card {
                padding: 9px 7px;
                border-radius: 8px;
            }
            .stat-label {
            }
            .stat-value {
                font-size: 15px;
            }
            #lastUpdate {
                font-size: 11px !important;
            }

            /* Tabs */
            .tab {
                padding: 7px 10px;
                font-size: 10.5px;
            }

            /* Timeframe */
            .tf-btn {
                padding: 5px 8px;
            }

            /* Table */
            .table-card {
                padding: 9px 7px;
            }
            .table-title {
                font-size: 13px;
            }
            .search-box {
                padding: 7px 8px;
            }
            table {
                min-width: 480px;
            }
            th, td {
                padding: 6px 4px;
            }
            td strong {
                max-width: 58px;
            }
            .signal-score {
                font-size: 13px;
            }
            .signal-indicators {
            }
            .indicator-badge {
                padding: 1px 3px;
            }
            .table-wrapper {
                max-height: 360px;
            }
        }

        /* ============================================================
           RESPONSIVE: LANDSCAPE MOBILE (orientation: landscape + short)
           ============================================================ */
        @media (max-height: 500px) and (orientation: landscape) {
            .header {
                padding: 10px 14px;
                margin-bottom: 8px;
            }
            h1 {
                font-size: 1.3em;
            }
            .subtitle, .usdt-rate {
                display: none;
            }
            .stats-grid {
                grid-template-columns: repeat(4, 1fr);
                gap: 6px;
                margin-bottom: 8px;
            }
            .stat-card {
                padding: 8px 6px;
            }
            .stat-label {
            }
            .stat-value {
                font-size: 16px;
            }
            .tabs {
                margin-bottom: 8px;
            }
            .tab {
                padding: 6px 10px;
                font-size: 11px;
            }
            .table-card {
                padding: 8px;
                margin-bottom: 8px;
            }
            .table-title {
                font-size: 13px;
                margin-bottom: 6px;
            }
            .search-box {
                padding: 5px 8px;
                margin-bottom: 6px;
                font-size: 12px;
            }
            .table-wrapper {
                max-height: 200px;
            }
            .timeframe-selector {
                padding: 6px 8px;
                margin-bottom: 6px;
            }
            .tf-btn {
                padding: 4px 8px;
                font-size: 10px;
            }
        }
        
        /* Chart-related CSS removed */
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>
                Indodax Market Analyzer
                <span class="live-badge">● LIVE</span>
                <span id="pausedBadge" class="paused-badge" style="display:none;">⏸ PAUSED</span>
            </h1>
            <p class="subtitle">Real-time cryptocurrency market with Signal Analysis</p>
            <p class="usdt-rate" id="usdtRate">💱 USDT/IDR Rate: Loading...</p>
        </div>
        
        <div id="loading" class="loading">⏳ Loading market data...</div>
        <div id="error" class="error" style="display:none;"></div>
        
        <div id="results" style="display:none;">
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="stat-label">Total Trading Pairs</div>
                    <div class="stat-value" id="totalPairs">0</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">24h Volume (IDR)</div>
                    <div class="stat-value" id="totalVolume">Rp 0</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Active Markets</div>
                    <div class="stat-value" id="activeMarkets">0</div>
                </div>
                <div class="stat-card">
                    <div class="stat-label">Last Updated</div>
                    <div class="stat-value" id="lastUpdate" style="font-size: 16px;">-</div>
                </div>
            </div>
            
            <div class="tabs">
                <div class="tab active" onclick="switchTab('signals', event)">🎯 Signal Analysis</div>
                <div class="tab" onclick="switchTab('overview', event)">📈 Market Overview</div>
                <div class="tab" onclick="switchTab('volume', event)">
                    💰 Top Volume
                    <span class="count-badge" id="volumeCount">0</span>
                </div>
            </div>
            
            <div id="signals" class="content-section active">
                <div class="table-card">
                    <div class="table-title">🎯 Signal Analysis</div>
                    
                    <!-- Signal Tabs: Buy/Sell Toggle -->
                    <div class="signal-tabs">
                        <div class="signal-tab active-buy" id="buySignalTab" onclick="switchSignalTab('buy')">
                            🟢 Buy Signals - <span id="buySignalsCount">0</span>
                        </div>
                        <div class="signal-tab" id="sellSignalTab" onclick="switchSignalTab('sell')">
                            🔴 Sell Signals - <span id="sellSignalsCount">0</span>
                        </div>
                    </div>
                    
                    <!-- Timeframe Selector (shared between Buy and Sell) -->
                    <div class="timeframe-selector">
                        <span style="color:#9ca3af;font-weight:600;margin-right:10px;">Timeframe:</span>
                        <button class="tf-btn" onclick="selectTimeframe('15m')">15m</button>
                        <button class="tf-btn" onclick="selectTimeframe('30m')">30m</button>
                        <button class="tf-btn active" onclick="selectTimeframe('1h')">1h</button>
                        <button class="tf-btn" onclick="selectTimeframe('2h')">2h</button>
                        <button class="tf-btn" onclick="selectTimeframe('4h')">4h</button>
                        <button class="tf-btn" onclick="selectTimeframe('1d')">1d</button>
                        <button class="tf-btn" onclick="selectTimeframe('3d')">3d</button>
                        <button class="tf-btn" onclick="selectTimeframe('1w')">1w</button>
                        <button class="tf-btn" onclick="selectTimeframe('2w')">2w</button>
                        <button class="tf-btn" onclick="selectTimeframe('1m')">1m</button>
                    </div>
                    
                    <!-- Buy Signals Content -->
                    <div id="buySignalsContent" class="signal-content active">
                        <input type="text" id="searchBuySignals" class="search-box" placeholder="🔍 Search buy signals..." onkeyup="filterBuySignalsTable()">
                        <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                            <table id="buySignalsTable">
                                <thead>
                                    <tr>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 0, 'number')">Rank</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 1, 'string')">Pair</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 2, 'number')">Price</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 3, 'number')">24h Change</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 4, 'number')">Score</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 5, 'string')">Recommendation</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 6, 'string')">Signals</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 7, 'number')">Volume</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 8, 'string')">Risk</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 9, 'string')">🎯 Target/SL/Risk</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 10, 'string')">📊 Win Rate</th>
                                    </tr>
                                </thead>
                                <tbody id="buySignalsBody"></tbody>
                            </table>
                        </div>
                    </div>
                    
                    <!-- Sell Signals Content -->
                    <div id="sellSignalsContent" class="signal-content">
                        <input type="text" id="searchSellSignals" class="search-box" placeholder="🔍 Search sell signals..." onkeyup="filterSellSignalsTable()">
                        <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                            <table id="sellSignalsTable">
                                <thead>
                                    <tr>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 0, 'number')">Rank</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 1, 'string')">Pair</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 2, 'number')">Price</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 3, 'number')">24h Change</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 4, 'number')">Score</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 5, 'string')">Recommendation</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 6, 'string')">Signals</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 7, 'number')">Volume</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 8, 'string')">Risk</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 9, 'string')">🎯 Target/SL/Risk</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 10, 'string')">📊 Win Rate</th>
                                    </tr>
                                </thead>
                                <tbody id="sellSignalsBody"></tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
            
            <div id="overview" class="content-section">
                <div class="table-card">
                    <div class="table-title"> All Market</div>
                    <input type="text" id="searchBox" class="search-box" placeholder="🔍 Search pair..." onkeyup="filterTable()">
                    <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                        <table id="allMarketsTable">
                            <thead>
                                <tr>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 0, 'string')">Pair</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 1, 'number')">Last Price</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 2, 'number')">24h Change</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 3, 'number')">24h High</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 4, 'number')">24h Low</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 5, 'number')">Volume</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 6, 'number')">Buy</th>
                                    <th class="sortable" onclick="sortTable('allMarketsTable', 7, 'number')">Sell</th>
                                </tr>
                            </thead>
                            <tbody id="allMarketsBody"></tbody>
                        </table>
                    </div>
                </div>
            </div>
            
            <div id="volume" class="content-section">
                <div class="table-card">
                    <div class="table-title">💰 All Highest Volume Markets (24h) - <span id="volumeChartCount">0</span> Assets</div>
                    <input type="text" id="searchVolume" class="search-box" placeholder="🔍 Search by volume..." onkeyup="filterVolumeTable()">
                    <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                        <table id="volumeTable">
                            <thead>
                                <tr>
                                    <th class="sortable" onclick="sortTable('volumeTable', 0, 'number')">Rank</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 1, 'string')">Pair</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 2, 'number')">Last Price</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 3, 'number')">24h Change</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 4, 'number')">24h High</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 5, 'number')">24h Low</th>
                                    <th class="sortable" onclick="sortTable('volumeTable', 6, 'number')">Volume</th>
                                </tr>
                            </thead>
                            <tbody id="volumeBody"></tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Chart Modal removed -->

    <script>
        let marketData = null;
        let previousMarketData = null;
        let isLoading = false;
        let sortStates = {};
        let activeSorts = {}; // Track active sorting: { tableId: { column: number, direction: 'asc'|'desc', type: 'number'|'string' } }
        let countdownInterval;
        let secondsUntilRefresh = 5;
        let selectedTimeframe = '1h';
        let activeSignalTab = 'buy';  // default to buy signals
        let isPaused = false;
        let lastInteractionTime = Date.now();
        let scrollTimeout;
        
        // New feature variables
        let signalHistory = JSON.parse(localStorage.getItem('indodax_signal_history') || '{}');
        let refreshIntervalId = null;
        let refreshIntervalTime = 10000; // default 10 seconds
        
        // ============================================================
        // REAL CANDLESTICK DATA FUNCTIONS (Placeholder for future enhancement)
        // ============================================================
        
        // Fetch candlestick data untuk indikator akurat (stub for now)
        async function getCandlestickData(pair, timeframe) {
            // TODO: Implement when Indodax provides historical candlestick API
            // For now, return empty array - indicators will use ticker data
            return [];
        }

        // Calculate RSI from real candle data (14 period with SMA 14)
        // RSI Settings: Period 14, SMA 14
        function calculateRSI(candles, period = 14) {
            if (!candles || candles.length < period + 1) return 50;
            
            let gains = 0;
            let losses = 0;
            
            for (let i = 1; i <= period; i++) {
                const change = candles[i].close - candles[i-1].close;
                if (change >= 0) {
                    gains += change;
                } else {
                    losses -= change;
                }
            }
            
            // Standard RSI calculation using period (14) for averaging
            const avgGain = gains / period;
            const avgLoss = losses / period;
            
            if (avgLoss === 0) return 100;
            
            const rs = avgGain / avgLoss;
            const rsi = 100 - (100 / (1 + rs));
            
            return rsi;
        }

        // Calculate StochRSI from real data
        // StochRSI Settings: 14 14 3 3 (RSI Period 14, Stoch Period 14, SmoothK 3, SmoothD 3)
        function calculateStochRSI(candles, rsiPeriod = 14, stochPeriod = 14, smoothK = 3, smoothD = 3) {
            if (!candles || candles.length < rsiPeriod * 2 + smoothK) return 50;
            
            const rsiValues = [];
            
            for (let i = rsiPeriod; i < candles.length; i++) {
                const slice = candles.slice(i - rsiPeriod, i + 1);
                rsiValues.push(calculateRSI(slice, rsiPeriod));
            }
            
            // Need at least stochPeriod RSI values to calculate raw StochRSI
            if (rsiValues.length < stochPeriod) return 50;
            
            // Calculate raw Stochastic RSI values
            const rawStochRSI = [];
            for (let i = stochPeriod - 1; i < rsiValues.length; i++) {
                const recentRSI = rsiValues.slice(i - stochPeriod + 1, i + 1);
                const minRSI = Math.min(...recentRSI);
                const maxRSI = Math.max(...recentRSI);
                
                if (maxRSI === minRSI) {
                    rawStochRSI.push(50);
                } else {
                    const currentRSI = rsiValues[i];
                    rawStochRSI.push(((currentRSI - minRSI) / (maxRSI - minRSI)) * 100);
                }
            }
            
            if (rawStochRSI.length < smoothK) return 50;
            
            // Apply SmoothK (3-period SMA of raw StochRSI) - this is the %K line
            const kValues = [];
            for (let i = smoothK - 1; i < rawStochRSI.length; i++) {
                const slice = rawStochRSI.slice(i - smoothK + 1, i + 1);
                kValues.push(slice.reduce((a, b) => a + b, 0) / smoothK);
            }
            
            if (kValues.length < smoothD) return kValues[kValues.length - 1] || 50;
            
            // Apply SmoothD (3-period SMA of %K) - this is the %D line
            // Return the smoothed %K value (most commonly used)
            const lastK = kValues[kValues.length - 1];
            
            return lastK;
        }

        // Bollinger Bands (20, 2) - MATCHES TradingView/Indodax Charts
        // Uses POPULATION standard deviation (divides by N, not N-1)
        function calculateBollingerBands(candles, period = 20, stdDevMultiplier = 2) {
            if (!candles || candles.length < period) {
                console.warn('⚠️ Insufficient candles for BB(20,2). Need:', period, 'Have:', candles ? candles.length : 0);
                
                // Fallback for insufficient data
                if (candles && candles.length > 0) {
                    const closes = candles.map(c => c.close);
                    const high = Math.max(...closes);
                    const low = Math.min(...closes);
                    const mid = (high + low) / 2;
                    const range = high - low;
                    
                    return {
                        upper: mid + (range / 2),
                        middle: mid,
                        lower: mid - (range / 2),
                        stdDev: range / 4,
                        posPercent: 50,
                        dataSource: 'FALLBACK'
                    };
                }
                
                return {
                    upper: 0,
                    middle: 0,
                    lower: 0,
                    stdDev: 0,
                    posPercent: 50,
                    dataSource: 'EMPTY'
                };
            }
            
            // ========================================
            // STEP 1: Get LAST 20 candles (most recent)
            // ========================================
            const recentCandles = candles.slice(-period);
            const closes = recentCandles.map(c => c.close);
            
            // ========================================
            // STEP 2: Calculate SMA (Simple Moving Average)
            // This becomes the MIDDLE BAND
            // ========================================
            let sum = 0;
            for (let i = 0; i < closes.length; i++) {
                sum += closes[i];
            }
            const sma = sum / period;
            
            // ========================================
            // STEP 3: Calculate POPULATION Standard Deviation
            // CRITICAL: Use N (not N-1) to match TradingView
            // ========================================
            
            // Calculate sum of squared differences from mean
            let sumSquaredDifferences = 0;
            for (let i = 0; i < closes.length; i++) {
                const difference = closes[i] - sma;
                sumSquaredDifferences += difference * difference;
            }
            
            // POPULATION Variance = Sum of squared differences / N
            // (NOT N-1 which is SAMPLE variance)
            const populationVariance = sumSquaredDifferences / period;
            
            // Standard Deviation = Square root of variance
            const stdDev = Math.sqrt(populationVariance);
            
            // ========================================
            // STEP 4: Calculate Upper and Lower Bands
            // ========================================
            const upperBand = sma + (stdDevMultiplier * stdDev);
            const lowerBand = sma - (stdDevMultiplier * stdDev);
            
            // ========================================
            // STEP 5: Calculate current price position (0-100%)
            // ========================================
            const currentClose = candles[candles.length - 1].close;
            let posPercent = 50;
            
            const bandWidth = upperBand - lowerBand;
            if (bandWidth > 0) {
                posPercent = ((currentClose - lowerBand) / bandWidth) * 100;
                // Clamp between 0 and 100
                posPercent = Math.max(0, Math.min(100, posPercent));
            }
            
            // ========================================
            // DEBUG LOGGING: Verify calculation
            // ========================================
            const pairName = candles[0]?.pair || 'Unknown';
            console.log('📊 BB(20,2) Calculation for', pairName, {
                currentClose: currentClose,
                sma: sma.toFixed(2),
                stdDev: stdDev.toFixed(2),
                upper: upperBand.toFixed(2),
                middle: sma.toFixed(2),
                lower: lowerBand.toFixed(2),
                position: posPercent.toFixed(1) + '%',
                bandWidth: bandWidth.toFixed(2),
                candleCount: candles.length,
                last5Closes: closes.slice(-5).map(c => c.toFixed(2)),
                calculationType: 'POPULATION_STDEV'
            });
            
            return {
                upper: upperBand,
                middle: sma,
                lower: lowerBand,
                stdDev: stdDev,
                posPercent: posPercent,
                dataSource: 'CALCULATED',
                candleCount: candles.length
            };
        }

        // Calculate EMA helper function
        function calculateEMA(data, period) {
            if (!data || data.length < period) return data[data.length - 1];
            
            const multiplier = 2 / (period + 1);
            let ema = data.slice(0, period).reduce((a, b) => a + b, 0) / period;
            
            for (let i = period; i < data.length; i++) {
                ema = (data[i] - ema) * multiplier + ema;
            }
            
            return ema;
        }

        // Calculate MACD from real data (12, 26, close, 9)
        // MACD Settings: Fast EMA 12, Slow EMA 26, Signal EMA 9, Source: Close
        function calculateMACD(candles, fastPeriod = 12, slowPeriod = 26, signalPeriod = 9) {
            // Need slowPeriod + signalPeriod - 1 candles minimum for proper signal line calculation
            if (!candles || candles.length < slowPeriod + signalPeriod - 1) {
                return { macd: 0, signal: 0, histogram: 0 };
            }
            
            const closes = candles.map(c => c.close);
            
            // Calculate EMA values for each point to build MACD line history
            const macdHistory = [];
            for (let i = slowPeriod - 1; i < closes.length; i++) {
                const slice = closes.slice(0, i + 1);
                const emaFast = calculateEMA(slice, fastPeriod);
                const emaSlow = calculateEMA(slice, slowPeriod);
                macdHistory.push(emaFast - emaSlow);
            }
            
            if (macdHistory.length < signalPeriod) {
                return { macd: 0, signal: 0, histogram: 0 };
            }
            
            // Current MACD line value
            const macdLine = macdHistory[macdHistory.length - 1];
            
            // Signal line is 9-period EMA of MACD values
            const signalLine = calculateEMA(macdHistory, signalPeriod);
            
            // Histogram is MACD line minus Signal line
            const histogram = macdLine - signalLine;
            
            return { macd: macdLine, signal: signalLine, histogram };
        }
        
        // Calculate Momentum from real data (10 period)
        // Momentum Settings: Period 10
        function calculateMomentum(candles, period = 10) {
            if (!candles || candles.length < period + 1) return 0;
            
            const currentClose = candles[candles.length - 1].close;
            const previousClose = candles[candles.length - 1 - period].close;
            
            if (previousClose === 0) return 0;
            
            // Momentum as percentage change over period
            const momentum = ((currentClose - previousClose) / previousClose) * 100;
            
            return momentum;
        }
        
        // Calculate Volume SMA (9 period)
        // Volume SMA Settings: Period 9
        function calculateVolumeSMA(candles, period = 9) {
            if (!candles || candles.length < period) return 0;
            
            const volumes = candles.slice(-period).map(c => c.volume);
            const sma = volumes.reduce((a, b) => a + b, 0) / period;
            
            return sma;
        }
        
        // Calculate risk level based on new indicator signals
        // Risk follows Score Recommendation and uses indicator thresholds from:
        // RSI(14,SMA14), StochRSI(14,14,3,3), Volume SMA(9), MACD(12,26,close,9), Momentum(10), BB(20,2)
        function calculateRiskLevel(ticker, signal, avgVolume) {
            let riskScore = 0;
            
            // Volatility check
            const volatility = ((ticker.high - ticker.low) / ticker.low) * 100;
            if (volatility > 20) riskScore += 3;
            else if (volatility > 10) riskScore += 2;
            else if (volatility > 5) riskScore += 1;
            
            // Volume check (IMPROVED)
            const volumeRatio = ticker.volume / avgVolume;
            if (volumeRatio < 0.2) riskScore += 3; // Very low volume = HIGH RISK
            else if (volumeRatio < 0.5) riskScore += 2;
            else if (volumeRatio < 1) riskScore += 1;
            
            // Spread check
            if (ticker.buy > 0 && ticker.sell > 0) {
                const spread = ((ticker.sell - ticker.buy) / ticker.buy) * 100;
                if (spread > 5) riskScore += 2;
                else if (spread > 2) riskScore += 1;
            }
            
            // BB position risk (NEW)
            if (signal.indicators && signal.indicators.bbPosition) {
                const bbPos = signal.indicators.bbPosition;
                if (bbPos === 'EXTREME_OVERBOUGHT' || bbPos === 'EXTREME_OVERSOLD') {
                    riskScore += 1; // Extreme positions = higher risk
                }
            }
            
            // RSI/StochRSI extreme levels (NEW)
            if (signal.indicators) {
                const rsi = parseFloat(signal.indicators.rsi);
                const stochRSI = parseFloat(signal.indicators.stochRSI);
                if (rsi > 85 || rsi < 15 || stochRSI > 90 || stochRSI < 10) {
                    riskScore += 2;
                }
            }
            
            // Low win rate = higher risk (NEW)
            if (signal.winRate < 40) {
                riskScore += 2;
            }
            
            // Counter-trend signal = higher risk (NEW)
            if (signal.indicators) {
                const trend = signal.indicators.trend;
                if ((signal.type === 'BUY' && trend === 'DOWNTREND') ||
                    (signal.type === 'SELL' && trend === 'UPTREND')) {
                    riskScore += 2;
                }
            }
            
            // Determine risk level
            if (riskScore >= 8) return { level: 'VERY HIGH', color: '#dc2626', icon: '🔴⚠️', class: 'risk-very-high' };
            if (riskScore >= 6) return { level: 'HIGH', color: '#ef4444', icon: '🔴', class: 'risk-high' };
            if (riskScore >= 3) return { level: 'MEDIUM', color: '#f59e0b', icon: '🟡', class: 'risk-medium' };
            return { level: 'LOW', color: '#22c55e', icon: '🟢', class: 'risk-low' };
        }
        
        // Calculate Support/Resistance using Bollinger Bands (20, 2)
        // BB Settings: Period 20, Standard Deviation 2
        // CRITICAL: Based on PRICE POSITION in BB, NOT signal type
        function calculateBollingerBandLevels(high, low, last, signalType, timeframe) {
            // Estimate BB(20,2) from 24h range based on Indodax price movements
            const range24h = high - low;
            const midPrice = (high + low) / 2;
            // High/Low typically represent ~3σ movement, so σ ≈ range / 6
            const estimatedStdDev = range24h / 6;
            let upperBand = midPrice + (2 * estimatedStdDev);  // Upper BB (SMA + 2σ)
            let lowerBand = midPrice - (2 * estimatedStdDev);  // Lower BB (SMA - 2σ)
            let middleBand = midPrice;
            const stdDev = estimatedStdDev;
            
            // Validate BB levels
            if (upperBand <= middleBand || middleBand <= lowerBand) {
                console.warn('⚠️ Invalid BB levels detected, using fallback calculation:', { 
                    upper: upperBand, 
                    middle: middleBand, 
                    lower: lowerBand,
                    currentPrice: last
                });
                const range = Math.max(high - low, last * 0.1);
                upperBand = last + (range * 0.5);
                middleBand = last;
                lowerBand = last - (range * 0.5);
            }
            
            // ========================================
            // CRITICAL: Determine zone by PRICE POSITION in BB
            // NOT by signal type!
            // ========================================
            
            const pricePosition = ((last - lowerBand) / (upperBand - lowerBand)) * 100;
            
            // Price in BULLISH ZONE (>= middle) - Show SUPPORT levels BELOW price
            if (last >= middleBand || pricePosition >= 50) {
                let support1 = middleBand;
                let support2 = lowerBand;
                let support3 = lowerBand - stdDev;
                let stopLoss = lowerBand - (stdDev * 1.2);
                
                // VALIDATION: All levels MUST be BELOW current price
                if (support1 >= last) support1 = last * 0.98;
                if (support2 >= support1) support2 = support1 * 0.95;
                if (support3 >= support2) support3 = support2 * 0.93;
                if (stopLoss >= support3) stopLoss = support3 * 0.97;
                
                // Ensure all are below price
                support1 = Math.min(support1, last * 0.98);
                support2 = Math.min(support2, last * 0.95);
                support3 = Math.min(support3, last * 0.92);
                stopLoss = Math.min(stopLoss, last * 0.90);
                
                const target = upperBand;
                
                return {
                    type: 'SUPPORT',
                    level1: support1,
                    level2: support2,
                    level3: support3,
                    stopLoss: stopLoss,
                    target: target,
                    zone: 'BULLISH',
                    pricePosition: pricePosition.toFixed(1),
                    bbLevels: { upper: upperBand, middle: middleBand, lower: lowerBand }
                };
            }
            
            // Price in BEARISH ZONE (< middle) - Show RESISTANCE levels ABOVE price
            else {
                let resistance1 = middleBand;
                let resistance2 = upperBand;
                let resistance3 = upperBand + stdDev;
                let stopLoss = upperBand + (stdDev * 1.2);
                
                // VALIDATION: All levels MUST be ABOVE current price
                if (resistance1 <= last) resistance1 = last * 1.02;
                if (resistance2 <= resistance1) resistance2 = resistance1 * 1.05;
                if (resistance3 <= resistance2) resistance3 = resistance2 * 1.07;
                if (stopLoss <= resistance3) stopLoss = resistance3 * 1.03;
                
                // Ensure all are above price
                resistance1 = Math.max(resistance1, last * 1.02);
                resistance2 = Math.max(resistance2, last * 1.05);
                resistance3 = Math.max(resistance3, last * 1.08);
                stopLoss = Math.max(stopLoss, last * 1.10);
                
                // For bearish zone, target represents take profit level (same as stop loss position)
                const target = stopLoss;
                
                return {
                    type: 'RESISTANCE',
                    level1: resistance1,
                    level2: resistance2,
                    level3: resistance3,
                    stopLoss: stopLoss,
                    target: target,
                    zone: 'BEARISH',
                    pricePosition: pricePosition.toFixed(1),
                    bbLevels: { upper: upperBand, middle: middleBand, lower: lowerBand }
                };
            }
        }
        
        // Calculate Target/SL/Risk using Bollinger Bands (20, 2)
        // Target/SL/Risk now based on PRICE POSITION in BB, not signal type
        // Based on Indodax price movements for accurate support and resistance levels
        function calculateTargetSLRisk(ticker, signal, timeframe = '1h') {
            const last = ticker.last;
            const high = ticker.high;
            const low = ticker.low;
            
            // Use the Bollinger Band Levels function (BB 20,2) for support/resistance
            // Now determines zone based on price position in BB
            const bb = calculateBollingerBandLevels(high, low, last, signal.type, timeframe);
            
            let result = {
                targets: [],
                stopLoss: bb.stopLoss,
                riskReward: 0,
                entry: last,
                zone: bb.zone,
                pricePosition: bb.pricePosition
            };
            
            // Display based on BB zone (price position), not signal type
            if (bb.type === 'RESISTANCE') {
                // Price in bearish zone - show resistances
                result.targets = [
                    { 
                        label: 'Resistance 1', 
                        value: bb.level1,
                        percent: ((bb.level1 - last) / last * 100).toFixed(2)
                    },
                    { 
                        label: 'Resistance 2', 
                        value: bb.level2,
                        percent: ((bb.level2 - last) / last * 100).toFixed(2)
                    },
                    { 
                        label: 'Resistance 3', 
                        value: bb.level3,
                        percent: ((bb.level3 - last) / last * 100).toFixed(2)
                    }
                ];
                
                // For bearish zone:
                // Stop Loss: Above resistances (for short positions)
                // Risk: Distance from entry to stop loss
                // Reward: Distance from entry to lower BB
                const risk = Math.abs(bb.stopLoss - last);
                const reward = Math.abs(last - bb.bbLevels.lower);
                result.riskReward = risk > 0 ? (reward / risk).toFixed(1) : 0;
                
            } else {
                // Price in bullish zone - show supports
                result.targets = [
                    { 
                        label: 'Support 1', 
                        value: bb.level1,
                        percent: ((bb.level1 - last) / last * 100).toFixed(2)
                    },
                    { 
                        label: 'Support 2', 
                        value: bb.level2,
                        percent: ((bb.level2 - last) / last * 100).toFixed(2)
                    },
                    { 
                        label: 'Support 3', 
                        value: bb.level3,
                        percent: ((bb.level3 - last) / last * 100).toFixed(2)
                    }
                ];
                
                // For bullish zone:
                // Stop Loss: Below supports
                // Risk: Distance from entry to stop loss
                // Reward: Distance from entry to upper BB
                const risk = Math.abs(last - bb.stopLoss);
                const reward = Math.abs(bb.bbLevels.upper - last);
                result.riskReward = risk > 0 ? (reward / risk).toFixed(1) : 0;
            }
            
            return result;
        }
        
        // Helper function: Calculate BB Position based on signal type
        // This version uses signal.type to determine which levels to check
        // Used in win rate calculation where signal type is already known
        function calculateBBPosition(ticker, signal, timeframe) {
            const bb = calculateBollingerBandLevels(ticker.high, ticker.low, ticker.last, signal.type, timeframe);
            const last = ticker.last;
            const tolerance = 0.02; // 2%
            
            let nearSupport = false;
            let nearResistance = false;
            
            if (signal.type === 'BUY') {
                // Check if near support levels
                nearSupport = (
                    Math.abs(last - bb.level1) / last < tolerance ||
                    Math.abs(last - bb.level2) / last < tolerance ||
                    Math.abs(last - bb.level3) / last < tolerance ||
                    last <= bb.level1 * 1.02 // Within 2% above lowest support level
                );
            } else if (signal.type === 'SELL') {
                // Check if near resistance levels
                nearResistance = (
                    Math.abs(last - bb.level1) / last < tolerance ||
                    Math.abs(last - bb.level2) / last < tolerance ||
                    Math.abs(last - bb.level3) / last < tolerance ||
                    last >= bb.level1 * 0.98 // Within 2% below highest resistance level
                );
            }
            
            return { nearSupport, nearResistance };
        }
        
        // Calculate Win Rate based on 8 indicators
        // Indicator Settings: RSI(14,SMA14), StochRSI(14,14,3,3), Volume SMA(9), MACD(12,26,close,9), Momentum(10), BB(20,2)
        // Win rate follows the new indicator signals for accurate scoring
        function calculateWinRate(ticker, signal, avgVolume, timeframe = '1h') {
            // Use the counts already calculated in analyzeSignalAdvanced
            const bullishCount = signal.bullishCount || 0;
            const bearishCount = signal.bearishCount || 0;
            const totalIndicators = 8;
            
            // Use the win rate already calculated based on new indicator signals
            let winRate = signal.winRate || 50;
            
            const ind = signal.indicators;
            const rsi = parseFloat(ind.rsi);
            const stochRSI = parseFloat(ind.stochRSI);
            const bbPosition = ind.bbPosition;
            const macd = parseFloat(ind.macd);
            const momentum = parseFloat(ind.momentum);
            const volumeRatio = parseFloat(ind.volumeRatio);
            const trend = ind.trend;
            
            // Calculate statuses for display based on updated indicator thresholds
            const rsiStatus = rsi < 30 ? 'bullish' : rsi > 70 ? 'bearish' : 'neutral';
            const stochStatus = stochRSI < 20 ? 'bullish' : stochRSI > 80 ? 'bearish' : 'neutral';
            const bbStatus = bbPosition === 'OVERSOLD' ? 'bullish' : bbPosition === 'OVERBOUGHT' ? 'bearish' : 'neutral';
            const macdStatus = macd > 0 ? 'bullish' : macd < 0 ? 'bearish' : 'neutral';
            const momentumStatus = momentum > 0 ? 'bullish' : momentum < 0 ? 'bearish' : 'neutral';
            
            const priceUp = ind.priceUp;
            const priceDown = ind.priceDown;
            const volumeSpike = ind.volumeSpike;
            const volStatus = (volumeSpike && priceUp) ? 'bullish' : (volumeSpike && priceDown) ? 'bearish' : 'neutral';
            
            const bbPositionStatus = calculateBBPosition(ticker, signal, timeframe);
            const srStatus = bbPositionStatus.nearSupport ? 'bullish' : bbPositionStatus.nearResistance ? 'bearish' : 'neutral';
            
            const trendStatus = trend === 'UPTREND' ? 'bullish' : trend === 'DOWNTREND' ? 'bearish' : 'neutral';
            
            // Determine level
            let level;
            if (winRate >= 80) level = 'Very High';
            else if (winRate >= 65) level = 'High';
            else if (winRate >= 50) level = 'Medium';
            else level = 'Low';
            
            return {
                winRate: winRate,
                accuracy: level,
                bullish: bullishCount,
                bearish: bearishCount,
                total: totalIndicators,
                details: {
                    rsi: rsiStatus === 'bullish' ? '✅' : rsiStatus === 'bearish' ? '❌' : '➖',
                    stochRSI: stochStatus === 'bullish' ? '✅' : stochStatus === 'bearish' ? '❌' : '➖',
                    bb: bbStatus === 'bullish' ? '✅' : bbStatus === 'bearish' ? '❌' : '➖',
                    macd: macdStatus === 'bullish' ? '✅' : macdStatus === 'bearish' ? '❌' : '➖',
                    volume: volStatus === 'bullish' ? '✅' : volStatus === 'bearish' ? '❌' : '➖',
                    momentum: momentumStatus === 'bullish' ? '✅' : momentumStatus === 'bearish' ? '❌' : '➖',
                    sr: srStatus === 'bullish' ? '✅' : srStatus === 'bearish' ? '❌' : '➖',
                    trend: trendStatus === 'bullish' ? '✅' : trendStatus === 'bearish' ? '❌' : '➖'
                }
            };
        }
        
        // Format Target/SL/Risk display
        // Now displays based on BB zone (price position), not signal type
        function formatTargetSLDisplay(targetData, signal) {
            // Check zone from targetData (based on BB position)
            if (targetData.zone === 'BEARISH') {
                // Price in bearish zone - show resistance levels with red styling
                return \`
                    <div style="background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); padding: 15px; border-radius: 10px; box-shadow: 0 4px 12px rgba(239, 68, 68, 0.3);">
                        <div style="color: white; font-size: 11px; line-height: 1.5; margin-bottom: 8px; font-weight: 600; opacity: 0.95;">
                            📊 Resistance Levels (Price in Bearish Zone)
                        </div>
                        <div style="color: white; font-size: 11px; line-height: 1.4;">
                            🔴 Resistance 1: \${formatSupportResistance(targetData.targets[0].value)} <span style="opacity: 0.85;">(+\${targetData.targets[0].percent}%)</span><br>
                            🔴 Resistance 2: \${formatSupportResistance(targetData.targets[1].value)} <span style="opacity: 0.85;">(+\${targetData.targets[1].percent}%)</span><br>
                            🔴 Resistance 3: \${formatSupportResistance(targetData.targets[2].value)} <span style="opacity: 0.85;">(+\${targetData.targets[2].percent}%)</span><br>
                            🛑 Stop Loss: \${formatSupportResistance(targetData.stopLoss)} <span style="opacity: 0.85;">(+\${((targetData.stopLoss - targetData.entry) / targetData.entry * 100).toFixed(2)}%)</span><br>
                            <span style="font-weight: 700; margin-top: 5px; display: inline-block;">💎 R/R: 1:\${targetData.riskReward}</span>
                        </div>
                    </div>
                \`;
            } else {
                // Price in bullish zone - show support levels with green styling
                return \`
                    <div style="background: linear-gradient(135deg, #22c55e 0%, #16a34a 100%); padding: 15px; border-radius: 10px; box-shadow: 0 4px 12px rgba(34, 197, 94, 0.3);">
                        <div style="color: white; font-size: 11px; line-height: 1.5; margin-bottom: 8px; font-weight: 600; opacity: 0.95;">
                            📊 Support Levels (Price in Bullish Zone)
                        </div>
                        <div style="color: white; font-size: 11px; line-height: 1.4;">
                            🟢 Support 1: \${formatSupportResistance(targetData.targets[0].value)} <span style="opacity: 0.85;">(\${targetData.targets[0].percent}%)</span><br>
                            🟢 Support 2: \${formatSupportResistance(targetData.targets[1].value)} <span style="opacity: 0.85;">(\${targetData.targets[1].percent}%)</span><br>
                            🟢 Support 3: \${formatSupportResistance(targetData.targets[2].value)} <span style="opacity: 0.85;">(\${targetData.targets[2].percent}%)</span><br>
                            🛑 Stop Loss: \${formatSupportResistance(targetData.stopLoss)} <span style="opacity: 0.85;">(\${((targetData.stopLoss - targetData.entry) / targetData.entry * 100).toFixed(2)}%)</span><br>
                            <span style="font-weight: 700; margin-top: 5px; display: inline-block;">💎 R/R: 1:\${targetData.riskReward}</span>
                        </div>
                    </div>
                \`;
            }
        }
        
        // Format Win Rate display
        // Shows win rate based on 8 indicators with updated settings
        function formatWinRateDisplay(winRateData) {
            const details = winRateData.details;
            const count = winRateData.bullish > 0 ? winRateData.bullish : winRateData.bearish;
            
            return \`
                <div style="font-size:11px;line-height:1.5;">
                    📊 Win Rate<br>
                    <strong>\${winRateData.winRate}%</strong> \${winRateData.accuracy}<br>
                    ─────────<br>
                    RSI(14): \${details.rsi} StochRSI: \${details.stochRSI} BB: \${details.bb}<br>
                    MACD: \${details.macd} Vol: \${details.volume} Mom: \${details.momentum}<br>
                    S/R: \${details.sr} Trend: \${details.trend}<br>
                    <strong>\${count}/\${winRateData.total} Indicators</strong>
                </div>
            \`;
        }
        
        
        function switchSignalTab(tab) {
            activeSignalTab = tab;
            
            // Update tab styling
            const buyTab = document.getElementById('buySignalTab');
            const sellTab = document.getElementById('sellSignalTab');
            const buyContent = document.getElementById('buySignalsContent');
            const sellContent = document.getElementById('sellSignalsContent');
            
            buyTab.classList.remove('active-buy');
            sellTab.classList.remove('active-sell');
            
            if (tab === 'buy') {
                buyTab.classList.add('active-buy');
                buyContent.classList.add('active');
                sellContent.classList.remove('active');
            } else {
                sellTab.classList.add('active-sell');
                sellContent.classList.add('active');
                buyContent.classList.remove('active');
            }
        }
        
        function pauseAutoRefresh() {
            // DISABLED - Auto refresh always active
            return;
        }
        
        function resumeAutoRefresh() {
            // DISABLED - Auto refresh always active
            return;
        }
        
        function handleScroll() {
            // DISABLED - Scroll does not pause refresh
            return;
        }
        
        function selectTimeframe(tf) {
            selectedTimeframe = tf;
            document.querySelectorAll('.tf-btn').forEach(btn => btn.classList.remove('active'));
            event.target.classList.add('active');
            if (marketData) {
                displayMarketData(marketData);
            }
        }
        
        async function loadMarketData(silent = false) {
            if (isLoading) return;
            isLoading = true;
            
            if (!silent) {
                document.getElementById('loading').style.display = 'block';
            }
            
            document.getElementById('error').style.display = 'none';
            
            try {
                const response = await fetch('/api/market?t=' + Date.now());
                const data = await response.json();
                
                if (!data.success) {
                    throw new Error(data.error || 'Failed to fetch market data');
                }
                
                marketData = data;
                
                if (!isPaused || !silent) {
                    displayMarketData(data);
                }
                
                document.getElementById('results').style.display = 'block';
                document.getElementById('loading').style.display = 'none';
                
                secondsUntilRefresh = 5;
                
            } catch (error) {
                console.error('Error:', error);
                if (!silent) {
                    const errorDiv = document.getElementById('error');
                    errorDiv.textContent = '❌ Error: ' + error.message + '. Retrying...';
                    errorDiv.style.display = 'block';
                    document.getElementById('loading').style.display = 'none';
                }
            } finally {
                isLoading = false;
            }
        }
        
        // Countdown timer for auto-refresh - decrements every second and triggers refresh at 0
        // Respects isPaused flag - countdown continues when not paused
        function updateCountdown() {
            if (!isPaused) {
                secondsUntilRefresh--;
                if (secondsUntilRefresh <= 0) {
                    secondsUntilRefresh = 5;
                    loadMarketData(true);
                }
            }
        }
        
        function displayMarketData(data) {
            // Save search box values before refresh
            const searchValues = {
                searchBox: document.getElementById('searchBox')?.value || '',
                searchVolume: document.getElementById('searchVolume')?.value || '',
                searchBuySignals: document.getElementById('searchBuySignals')?.value || '',
                searchSellSignals: document.getElementById('searchSellSignals')?.value || ''
            };
            
            // Save scroll positions to prevent jump during refresh
            const scrollPositions = {
                allMarkets: document.querySelector('#allMarkets .table-wrapper')?.scrollTop || 0,
                volume: document.querySelector('#volume .table-wrapper')?.scrollTop || 0,
                buySignals: document.querySelector('#buySignalsTable')?.closest('.table-wrapper')?.scrollTop || 0,
                sellSignals: document.querySelector('#sellSignalsTable')?.closest('.table-wrapper')?.scrollTop || 0
            };
            
            if (data.usdtIdrRate) {
                document.getElementById('usdtRate').textContent = 
                    '💱 USDT/IDR Rate: ' + formatPrice(data.usdtIdrRate);
            }
            
            document.getElementById('totalPairs').textContent = data.stats.totalPairs;
            document.getElementById('totalVolume').textContent = formatVolume(data.stats.totalVolume);
            document.getElementById('activeMarkets').textContent = data.stats.activeMarkets;
            document.getElementById('lastUpdate').textContent = new Date(data.timestamp).toLocaleTimeString('id-ID');
            
            document.getElementById('volumeCount').textContent = data.stats.totalVolumeAssets || 0;
            
            updateAllMarketsTable(data.tickers, previousMarketData ? previousMarketData.tickers : null);
            
            if (data.topVolume && data.topVolume.length > 0) {
                updateVolumeSection(data.topVolume, previousMarketData ? previousMarketData.topVolume : null);
            }
            updateSignalsSection(data.tickers, previousMarketData ? previousMarketData.tickers : null);
            
            // Restore search box values after refresh
            const searchBoxEl = document.getElementById('searchBox');
            const searchVolumeEl = document.getElementById('searchVolume');
            const searchBuySignalsEl = document.getElementById('searchBuySignals');
            const searchSellSignalsEl = document.getElementById('searchSellSignals');
            
            if (searchBoxEl) searchBoxEl.value = searchValues.searchBox;
            if (searchVolumeEl) searchVolumeEl.value = searchValues.searchVolume;
            if (searchBuySignalsEl) searchBuySignalsEl.value = searchValues.searchBuySignals;
            if (searchSellSignalsEl) searchSellSignalsEl.value = searchValues.searchSellSignals;
            
            // Re-apply filters if there were search values
            if (searchValues.searchBox) filterTable();
            if (searchValues.searchVolume) filterVolumeTable();
            if (searchValues.searchBuySignals) filterBuySignalsTable();
            if (searchValues.searchSellSignals) filterSellSignalsTable();
            
            previousMarketData = JSON.parse(JSON.stringify(data));
            
            // Restore scroll positions immediately after DOM update
            requestAnimationFrame(() => {
                const allMarketsWrapper = document.querySelector('#allMarkets .table-wrapper');
                const volumeWrapper = document.querySelector('#volume .table-wrapper');
                const buySignalsWrapper = document.querySelector('#buySignalsTable')?.closest('.table-wrapper');
                const sellSignalsWrapper = document.querySelector('#sellSignalsTable')?.closest('.table-wrapper');
                
                if (allMarketsWrapper) allMarketsWrapper.scrollTop = scrollPositions.allMarkets;
                if (volumeWrapper) volumeWrapper.scrollTop = scrollPositions.volume;
                if (buySignalsWrapper) buySignalsWrapper.scrollTop = scrollPositions.buySignals;
                if (sellSignalsWrapper) sellSignalsWrapper.scrollTop = scrollPositions.sellSignals;
            });
        }
        
        // UPDATED: Hanya return ▲ atau ▼ berdasarkan 24h change
        function getPriceIndicator(ticker) {
            return ticker.priceChangePercent >= 0 ? '▲' : '▼';
        }
        
        // Format volume display with warnings and icons
        function formatVolumeDisplay(currentVolume, avgVolume) {
            const multiplier = currentVolume / avgVolume;
            
            if (multiplier < 0.1) {
                return '⚠️ ' + (multiplier * 100).toFixed(0) + '% Avg';
            } else if (multiplier < 0.5) {
                return '⚠️ ' + multiplier.toFixed(1) + 'x Avg';
            } else if (multiplier > 3) {
                return '🔥 ' + multiplier.toFixed(1) + 'x Avg';
            } else {
                return multiplier.toFixed(1) + 'x Avg';
            }
        }
        
        // Format signals list vertically (8 indicators)
        // Indicator Settings: RSI(14,SMA14), StochRSI(14,14,3,3), Volume SMA(9), MACD(12,26,close,9), Momentum(10), BB(20,2)
        function formatSignalsList(signal, ticker) {
            const ind = signal.indicators;
            const rsi = parseFloat(ind.rsi);
            const stochRSI = parseFloat(ind.stochRSI);
            const bbPosition = ind.bbPosition;
            const macd = parseFloat(ind.macd);
            const momentum = parseFloat(ind.momentum);
            const volumeRatio = parseFloat(ind.volumeRatio);
            const trend = ind.trend;
            const volumeSpike = ind.volumeSpike;
            const priceUp = ind.priceUp;
            const priceDown = ind.priceDown;
            
            const signalsList = [];
            
            // 1. RSI (14, SMA 14) - Current RSI value
            const rsiClass = rsi < 30 ? 'bullish' : rsi > 70 ? 'bearish' : 'neutral';
            signalsList.push(\`<div class="signal-item \${rsiClass}">📊 RSI (14): \${rsi.toFixed(1)}</div>\`);
            
            // 2. Stochastic RSI (14,14,3,3) - Indicate overbought/oversold
            let stochStatus = '';
            let stochClass = 'neutral';
            if (stochRSI > 80) {
                stochStatus = \`❌ StochRSI Overbought (\${stochRSI.toFixed(0)})\`;
                stochClass = 'bearish';
            } else if (stochRSI < 20) {
                stochStatus = \`✅ StochRSI Oversold (\${stochRSI.toFixed(0)})\`;
                stochClass = 'bullish';
            } else {
                stochStatus = \`➖ StochRSI: \${stochRSI.toFixed(0)}\`;
                stochClass = 'neutral';
            }
            signalsList.push(\`<div class="signal-item \${stochClass}">\${stochStatus}</div>\`);
            
            // 3. Bollinger Bands (20,2) - Position against upper/lower bounds
            let bbStatus = '';
            let bbClass = 'neutral';
            if (bbPosition === 'OVERSOLD') {
                bbStatus = '❌ BB: Near Lower';
                bbClass = 'bullish';
            } else if (bbPosition === 'OVERBOUGHT') {
                bbStatus = '❌ BB: Near Upper';
                bbClass = 'bearish';
            } else if (bbPosition === 'ABOVE_MID') {
                bbStatus = '➖ BB: Above Mid';
                bbClass = 'neutral';
            } else if (bbPosition === 'BELOW_MID') {
                bbStatus = '➖ BB: Below Mid';
                bbClass = 'neutral';
            } else {
                bbStatus = '➖ BB: Neutral';
                bbClass = 'neutral';
            }
            signalsList.push(\`<div class="signal-item \${bbClass}">\${bbStatus}</div>\`);
            
            // 4. MACD (12,26,close,9) - Bullish or bearish trend
            const macdClass = macd > 0 ? 'bullish' : macd < 0 ? 'bearish' : 'neutral';
            const macdTrend = macd > 0 ? 'Bullish' : macd < 0 ? 'Bearish' : 'Neutral';
            const macdIcon = macd > 0 ? '✅' : macd < 0 ? '❌' : '➖';
            signalsList.push(\`<div class="signal-item \${macdClass}">\${macdIcon} MACD: \${macdTrend} (\${macd > 0 ? '+' : ''}\${macd.toFixed(0)})</div>\`);
            
            // 5. Volume (SMA 9) - Detect volume spikes with improved formatting
            let volumeStatus = '';
            let volumeClass = 'neutral';
            if (volumeSpike) {
                if (priceUp) {
                    volumeStatus = \`🔥 Vol (SMA 9): \${volumeRatio.toFixed(1)}x Spike + Price Up\`;
                    volumeClass = 'bullish';
                } else if (priceDown) {
                    volumeStatus = \`🔥 Vol (SMA 9): \${volumeRatio.toFixed(1)}x Spike + Price Down\`;
                    volumeClass = 'bearish';
                } else {
                    volumeStatus = \`🔥 Vol (SMA 9): \${volumeRatio.toFixed(1)}x Spike\`;
                    volumeClass = 'neutral';
                }
            } else {
                // Use improved volume formatting for non-spike volumes
                const volDisplay = formatVolumeDisplay(ticker.volume, ticker.volume / volumeRatio);
                volumeStatus = \`📊 Vol (SMA 9): \${volDisplay}\`;
                volumeClass = 'neutral';
            }
            signalsList.push(\`<div class="signal-item \${volumeClass}">\${volumeStatus}</div>\`);
            
            // 6. Momentum (10) - Calculate momentum change as a percentage
            const momentumClass = momentum > 0 ? 'bullish' : momentum < 0 ? 'bearish' : 'neutral';
            const momentumIcon = momentum > 0 ? '↗️' : momentum < 0 ? '↘️' : '➡️';
            signalsList.push(\`<div class="signal-item \${momentumClass}">\${momentumIcon} Momentum (10): \${momentum > 0 ? '+' : ''}\${momentum.toFixed(1)}%</div>\`);
            
            // 7. Bollinger Bands (20,2) - Used for Target/SL/Risk calculation
            signalsList.push(\`<div class="signal-item neutral">📐 BB (20,2): Target/SL/Risk</div>\`);
            
            // 8. Trend - Display trend
            const trendClass = trend === 'UPTREND' ? 'bullish' : trend === 'DOWNTREND' ? 'bearish' : 'neutral';
            const trendIcon = trend === 'UPTREND' ? '📈' : trend === 'DOWNTREND' ? '📉' : '➖';
            const trendText = trend === 'UPTREND' ? 'Uptrend' : trend === 'DOWNTREND' ? 'Downtrend' : 'Sideways';
            signalsList.push(\`<div class="signal-item \${trendClass}">\${trendIcon} Trend: \${trendText}</div>\`);
            
            return \`<div class="signals-list">\${signalsList.join('')}</div>\`;
        }
        
        // Format technical indicators vertically (8 indicators + BB levels)
        // Indicator Settings: RSI(14,SMA14), StochRSI(14,14,3,3), Volume SMA(9), MACD(12,26,close,9), Momentum(10), BB(20,2)
        function formatTechnicalIndicators(signal, ticker, timeframe) {
            const ind = signal.indicators;
            const bb = calculateBollingerBandLevels(ticker.high, ticker.low, ticker.last, signal.type, timeframe);
            
            const techList = [];
            
            techList.push(\`<div class="tech-item">RSI (14, SMA 14): \${ind.rsi} \${parseFloat(ind.rsi) < 30 ? '✅ Oversold' : parseFloat(ind.rsi) > 70 ? '❌ Overbought' : ''}</div>\`);
            techList.push(\`<div class="tech-item">StochRSI (14,14,3,3): \${ind.stochRSI} \${parseFloat(ind.stochRSI) < 20 ? '✅ Oversold' : parseFloat(ind.stochRSI) > 80 ? '❌ Overbought' : ''}</div>\`);
            techList.push(\`<div class="tech-item">BB (20,2): \${ind.bbPosition === 'OVERSOLD' ? 'Near Lower' : ind.bbPosition === 'OVERBOUGHT' ? 'Near Upper' : ind.bbPosition}</div>\`);
            techList.push(\`<div class="tech-item">MACD (12,26,close,9): \${ind.macd} \${parseFloat(ind.macd) > 0 ? '📈 Bullish' : parseFloat(ind.macd) < 0 ? '📉 Bearish' : ''}</div>\`);
            
            // Improved volume display with SMA 9
            const volumeRatio = parseFloat(ind.volumeRatio);
            const volDisplay = formatVolumeDisplay(ticker.volume, ticker.volume / volumeRatio);
            techList.push(\`<div class="tech-item">Volume (SMA 9): \${volDisplay} \${ind.volumeSpike ? '🔥 Spike' : ''}</div>\`);
            
            techList.push(\`<div class="tech-item">Momentum (10): \${ind.momentum}% \${parseFloat(ind.momentum) > 0 ? '↗️' : parseFloat(ind.momentum) < 0 ? '↘️' : '➡️'}</div>\`);
            
            // Bollinger Band levels
            if (signal.type === 'BUY') {
                techList.push(\`<div class="tech-item">BB Support 1: \${formatSupportResistance(bb.level1)}</div>\`);
                techList.push(\`<div class="tech-item">BB Support 2: \${formatSupportResistance(bb.level2)}</div>\`);
                techList.push(\`<div class="tech-item">BB Support 3: \${formatSupportResistance(bb.level3)}</div>\`);
                techList.push(\`<div class="tech-item">BB Position: Near Support</div>\`);
            } else {
                techList.push(\`<div class="tech-item">BB Resistance 1: \${formatSupportResistance(bb.level1)}</div>\`);
                techList.push(\`<div class="tech-item">BB Resistance 2: \${formatSupportResistance(bb.level2)}</div>\`);
                techList.push(\`<div class="tech-item">BB Resistance 3: \${formatSupportResistance(bb.level3)}</div>\`);
                techList.push(\`<div class="tech-item">BB Position: Near Resistance</div>\`);
            }
            
            techList.push(\`<div class="tech-item">Trend: \${ind.trend} \${ind.trend === 'UPTREND' ? '📈' : ind.trend === 'DOWNTREND' ? '📉' : '⚪'}</div>\`);
            
            return \`<div class="technical-list">\${techList.join('')}</div>\`;
        }
        
        function getRSIBadge(rsi) {
            const val = parseFloat(rsi);
            if (val < 30) return '<span class="indicator-badge rsi-oversold">RSI: ' + rsi + '</span>';
            if (val > 70) return '<span class="indicator-badge rsi-overbought">RSI: ' + rsi + '</span>';
            return '<span class="indicator-badge rsi-neutral">RSI: ' + rsi + '</span>';
        }
        
        function getBBBadge(bb) {
            if (bb === 'OVERSOLD') return '<span class="indicator-badge bb-lower">BB: Lower</span>';
            if (bb === 'OVERBOUGHT') return '<span class="indicator-badge bb-upper">BB: Upper</span>';
            return '<span class="indicator-badge rsi-neutral">BB: ' + bb + '</span>';
        }
        
        function updateSignalsSection(tickers, previousTickers) {
            const prevMap = {};
            if (previousTickers && Array.isArray(previousTickers)) {
                previousTickers.forEach(t => {
                    prevMap[t.pair] = t;
                });
            }
            
            let buySignals = tickers
                .filter(t => t.signals[selectedTimeframe] && t.signals[selectedTimeframe].type === 'BUY')
                .sort((a, b) => b.signals[selectedTimeframe].score - a.signals[selectedTimeframe].score);
            
            let sellSignals = tickers
                .filter(t => t.signals[selectedTimeframe] && t.signals[selectedTimeframe].type === 'SELL')
                .sort((a, b) => b.signals[selectedTimeframe].score - a.signals[selectedTimeframe].score);
            
            // Calculate average volume for risk calculation
            const avgVolume = tickers.reduce((sum, t) => sum + t.volume, 0) / tickers.length;
            
            document.getElementById('buySignalsCount').textContent = buySignals.length;
            document.getElementById('sellSignalsCount').textContent = sellSignals.length;
            
            const buyBody = document.getElementById('buySignalsBody');
            buyBody.innerHTML = '';
            
            if (buySignals.length === 0) {
                buyBody.innerHTML = '<tr><td colspan="11" style="text-align:center;color:#9ca3af;">No buy signals for this timeframe</td></tr>';
            } else {
                buySignals.forEach((ticker, index) => {
                    const signal = ticker.signals[selectedTimeframe];
                    const prevTicker = prevMap[ticker.pair];
                    
                    let priceFlash = '';
                    let changeFlash = '';
                    let scoreFlash = '';
                    let volumeFlash = '';
                    
                    if (prevTicker) {
                        if (ticker.last > prevTicker.last) {
                            priceFlash = 'flash-up';
                        } else if (ticker.last < prevTicker.last) {
                            priceFlash = 'flash-down';
                        }
                        
                        if (ticker.priceChangePercent > prevTicker.priceChangePercent) {
                            changeFlash = 'flash-up';
                        } else if (ticker.priceChangePercent < prevTicker.priceChangePercent) {
                            changeFlash = 'flash-down';
                        }
                        
                        const prevSignal = prevTicker.signals[selectedTimeframe];
                        if (prevSignal && signal.score !== prevSignal.score) {
                            scoreFlash = signal.score > prevSignal.score ? 'flash-up' : 'flash-down';
                        }
                        
                        if (ticker.volume > prevTicker.volume * 1.5) {
                            volumeFlash = 'volume-spike';
                        }
                    }
                    
                    const pairDisplay = ticker.isUsdtPair ? 
                        \`<strong>\${ticker.pair.toUpperCase()}</strong><span class="usdt-badge">USDT</span>\` : 
                        \`<strong>\${ticker.pair.toUpperCase()}</strong>\`;
                    
                    const priceIndicator = getPriceIndicator(ticker);
                    const priceColorClass = ticker.priceChangePercent >= 0 ? 'positive' : 'negative';
                    
                    const ind = signal.indicators;
                    
                    // Format signals and technical indicators vertically
                    const technicalIndicatorsDisplay = formatTechnicalIndicators(signal, ticker, selectedTimeframe);
                    const signalsDisplay = formatSignalsList(signal, ticker);
                    
                    // Create sortable values for Technical Indicators and Signals
                    const technicalIndicatorsText = \`RSI:\${ind.rsi} StochRSI:\${ind.stochRSI} BB:\${ind.bbPosition} MACD:\${ind.macd} Vol:\${ind.volumeRatio}x\`;
                    const signalsText = \`\${ind.rsi} \${ind.stochRSI} \${ind.bbPosition} \${ind.macd}\`;
                    
                    // Calculate risk level
                    const riskLevel = calculateRiskLevel(ticker, signal, avgVolume);
                    
                    // Calculate Target/SL/Risk
                    const targetData = calculateTargetSLRisk(ticker, signal, selectedTimeframe);
                    const targetDisplay = formatTargetSLDisplay(targetData, signal);
                    
                    // Calculate Win Rate
                    const winRateData = calculateWinRate(ticker, signal, avgVolume, selectedTimeframe);
                    const winRateDisplay = formatWinRateDisplay(winRateData);
                    
                    const row = buyBody.insertRow();
                    row.innerHTML = \`
                        <td data-value="\${index + 1}">\${index + 1}</td>
                        <td data-value="\${ticker.pair}">\${pairDisplay}</td>
                        <td data-value="\${ticker.last}" class="\${priceColorClass} \${priceFlash}">
                            \${priceIndicator} \${formatPrice(ticker.last)}
                        </td>
                        <td data-value="\${ticker.priceChangePercent}" class="\${ticker.priceChangePercent >= 0 ? 'positive' : 'negative'} \${changeFlash}">
                            \${ticker.priceChangePercent >= 0 ? '▲' : '▼'} \${Math.abs(ticker.priceChangePercent).toFixed(2)}%
                        </td>
                        <td data-value="\${signal.score}" class="\${scoreFlash}">
                            <span class="signal-score positive">\${signal.score}</span>/100
                        </td>
                        <td data-value="\${signal.recommendation}">
                            <span class="recommendation-badge \${signal.recommendation.toLowerCase().replace(/ /g, '-')}">\${signal.recommendation}</span>
                        </td>
                        <td data-value="\${signalsText}" class="signals-cell">
                            \${signalsDisplay}
                        </td>
                        <td data-value="\${ticker.volume}" class="\${volumeFlash}">\${formatVolume(ticker.volume)}</td>
                        <td data-value="\${riskLevel.level}">
                            <span class="risk-badge \${riskLevel.class}">\${riskLevel.icon} \${riskLevel.level}</span>
                        </td>
                        <td data-value="\${targetData.riskReward}">
                            \${targetDisplay}
                        </td>
                        <td data-value="\${winRateData.winRate}">
                            \${winRateDisplay}
                        </td>
                    \`;
                    
                    setTimeout(() => {
                        row.querySelectorAll('.flash-up, .flash-down').forEach(cell => {
                            cell.classList.remove('flash-up', 'flash-down');
                        });
                    }, 800);
                });
            }
            
            const sellBody = document.getElementById('sellSignalsBody');
            sellBody.innerHTML = '';
            
            if (sellSignals.length === 0) {
                sellBody.innerHTML = '<tr><td colspan="11" style="text-align:center;color:#9ca3af;">No sell signals for this timeframe</td></tr>';
            } else {
                sellSignals.forEach((ticker, index) => {
                    const signal = ticker.signals[selectedTimeframe];
                    const prevTicker = prevMap[ticker.pair];
                    
                    let priceFlash = '';
                    let changeFlash = '';
                    let scoreFlash = '';
                    let volumeFlash = '';
                    
                    if (prevTicker) {
                        if (ticker.last > prevTicker.last) {
                            priceFlash = 'flash-up';
                        } else if (ticker.last < prevTicker.last) {
                            priceFlash = 'flash-down';
                        }
                        
                        if (ticker.priceChangePercent > prevTicker.priceChangePercent) {
                            changeFlash = 'flash-up';
                        } else if (ticker.priceChangePercent < prevTicker.priceChangePercent) {
                            changeFlash = 'flash-down';
                        }
                        
                        const prevSignal = prevTicker.signals[selectedTimeframe];
                        if (prevSignal && signal.score !== prevSignal.score) {
                            scoreFlash = signal.score > prevSignal.score ? 'flash-up' : 'flash-down';
                        }
                        
                        if (ticker.volume > prevTicker.volume * 1.5) {
                            volumeFlash = 'volume-spike';
                        }
                    }
                    
                    const pairDisplay = ticker.isUsdtPair ? 
                        \`<strong>\${ticker.pair.toUpperCase()}</strong><span class="usdt-badge">USDT</span>\` : 
                        \`<strong>\${ticker.pair.toUpperCase()}</strong>\`;
                    
                    const priceIndicator = getPriceIndicator(ticker);
                    const priceColorClass = ticker.priceChangePercent >= 0 ? 'positive' : 'negative';
                    
                    const ind = signal.indicators;
                    
                    // Format signals and technical indicators vertically
                    const technicalIndicatorsDisplay = formatTechnicalIndicators(signal, ticker, selectedTimeframe);
                    const signalsDisplay = formatSignalsList(signal, ticker);
                    
                    // Create sortable values for Technical Indicators and Signals
                    const technicalIndicatorsText = \`RSI:\${ind.rsi} StochRSI:\${ind.stochRSI} BB:\${ind.bbPosition} MACD:\${ind.macd} Vol:\${ind.volumeRatio}x\`;
                    const signalsText = \`\${ind.rsi} \${ind.stochRSI} \${ind.bbPosition} \${ind.macd}\`;
                    
                    // Calculate risk level
                    const riskLevel = calculateRiskLevel(ticker, signal, avgVolume);
                    
                    // Calculate Target/SL/Risk
                    const targetData = calculateTargetSLRisk(ticker, signal, selectedTimeframe);
                    const targetDisplay = formatTargetSLDisplay(targetData, signal);
                    
                    // Calculate Win Rate
                    const winRateData = calculateWinRate(ticker, signal, avgVolume, selectedTimeframe);
                    const winRateDisplay = formatWinRateDisplay(winRateData);
                    
                    const row = sellBody.insertRow();
                    row.innerHTML = \`
                        <td data-value="\${index + 1}">\${index + 1}</td>
                        <td data-value="\${ticker.pair}">\${pairDisplay}</td>
                        <td data-value="\${ticker.last}" class="\${priceColorClass} \${priceFlash}">
                            \${priceIndicator} \${formatPrice(ticker.last)}
                        </td>
                        <td data-value="\${ticker.priceChangePercent}" class="\${ticker.priceChangePercent >= 0 ? 'positive' : 'negative'} \${changeFlash}">
                            \${ticker.priceChangePercent >= 0 ? '▲' : '▼'} \${Math.abs(ticker.priceChangePercent).toFixed(2)}%
                        </td>
                        <td data-value="\${signal.score}" class="\${scoreFlash}">
                            <span class="signal-score negative">\${signal.score}</span>/100
                        </td>
                        <td data-value="\${signal.recommendation}">
                            <span class="recommendation-badge \${signal.recommendation.toLowerCase().replace(/ /g, '-')}">\${signal.recommendation}</span>
                        </td>
                        <td data-value="\${signalsText}" class="signals-cell">
                            \${signalsDisplay}
                        </td>
                        <td data-value="\${ticker.volume}" class="\${volumeFlash}">\${formatVolume(ticker.volume)}</td>
                        <td data-value="\${riskLevel.level}">
                            <span class="risk-badge \${riskLevel.class}">\${riskLevel.icon} \${riskLevel.level}</span>
                        </td>
                        <td data-value="\${targetData.riskReward}">
                            \${targetDisplay}
                        </td>
                        <td data-value="\${winRateData.winRate}">
                            \${winRateDisplay}
                        </td>
                    \`;
                    
                    setTimeout(() => {
                        row.querySelectorAll('.flash-up, .flash-down').forEach(cell => {
                            cell.classList.remove('flash-up', 'flash-down');
                        });
                    }, 800);
                });
            }
            
            // Reapply sort if active
            reapplySortIfActive('buySignalsTable');
            reapplySortIfActive('sellSignalsTable');
        }
        
        function updateAllMarketsTable(tickers, previousTickers) {
            const tbody = document.getElementById('allMarketsBody');
            
            const prevMap = {};
            if (previousTickers && Array.isArray(previousTickers)) {
                previousTickers.forEach(t => {
                    prevMap[t.pair] = t;
                });
            }
            
            if (!Array.isArray(tickers) || tickers.length === 0) {
                tbody.innerHTML = '<tr><td colspan="8" style="text-align:center;">No data available</td></tr>';
                return;
            }
            
            if (tbody.children.length === 0) {
                tickers.forEach(ticker => {
                    const row = tbody.insertRow();
                    row.setAttribute('data-pair', ticker.pair);
                    populateMarketRow(row, ticker, null);
                });
                return;
            }
            
            tickers.forEach((ticker) => {
                let row = tbody.querySelector(\`tr[data-pair="\${ticker.pair}"]\`);
                
                if (!row) {
                    row = tbody.insertRow();
                    row.setAttribute('data-pair', ticker.pair);
                }
                
                const prevTicker = prevMap[ticker.pair];
                populateMarketRow(row, ticker, prevTicker);
            });
        }
        
        function populateMarketRow(row, ticker, prevTicker) {
            const pairDisplay = ticker.isUsdtPair ? 
                \`<strong>\${ticker.pair.toUpperCase()}</strong><span class="usdt-badge">USDT</span>\` : 
                \`<strong>\${ticker.pair.toUpperCase()}</strong>\`;
            
            const priceIndicator = getPriceIndicator(ticker);
            const priceColorClass = ticker.priceChangePercent >= 0 ? 'positive' : 'negative';
            
            let priceFlash = '';
            let changeFlash = '';
            let volumeFlash = '';
            let buyFlash = '';
            let sellFlash = '';
            
            if (prevTicker) {
                if (ticker.last > prevTicker.last) {
                    priceFlash = 'flash-up';
                } else if (ticker.last < prevTicker.last) {
                    priceFlash = 'flash-down';
                }
                
                if (ticker.priceChangePercent > prevTicker.priceChangePercent) {
                    changeFlash = 'flash-up';
                } else if (ticker.priceChangePercent < prevTicker.priceChangePercent) {
                    changeFlash = 'flash-down';
                }
                
                if (ticker.volume > prevTicker.volume * 1.5) {
                    volumeFlash = 'volume-spike';
                }
                
                if (ticker.buy !== prevTicker.buy) {
                    buyFlash = ticker.buy > prevTicker.buy ? 'flash-up' : 'flash-down';
                }
                
                if (ticker.sell !== prevTicker.sell) {
                    sellFlash = ticker.sell > prevTicker.sell ? 'flash-up' : 'flash-down';
                }
            }
            
            const buyDiff = ticker.buy > 0 ? ((ticker.last - ticker.buy) / ticker.buy * 100) : 0;
            const sellDiff = ticker.sell > 0 ? ((ticker.last - ticker.sell) / ticker.sell * 100) : 0;
            
            const buyIndicator = buyDiff > 0 ? '▲' : buyDiff < 0 ? '▼' : '▼';
            const sellIndicator = sellDiff > 0 ? '▲' : sellDiff < 0 ? '▼' : '▼';
            
            row.innerHTML = \`
                <td>\${pairDisplay}</td>
                <td data-value="\${ticker.last}" class="\${priceColorClass} \${priceFlash}">
                    \${priceIndicator} \${formatPrice(ticker.last)}
                </td>
                <td data-value="\${ticker.priceChangePercent}" class="\${ticker.priceChangePercent >= 0 ? 'positive' : 'negative'} \${changeFlash}">
                    \${ticker.priceChangePercent >= 0 ? '▲' : '▼'} \${Math.abs(ticker.priceChangePercent).toFixed(2)}%
                </td>
                <td data-value="\${ticker.high}" style="color:#4ade80">▲ \${formatPrice(ticker.high)}</td>
                <td data-value="\${ticker.low}" style="color:#ef4444">▼ \${formatPrice(ticker.low)}</td>
                <td data-value="\${ticker.volume}" class="\${volumeFlash}">\${formatVolume(ticker.volume)}</td>
                <td data-value="\${ticker.buy}" class="\${buyDiff >= 0 ? 'positive' : 'negative'} \${buyFlash}">
                    \${buyIndicator} \${formatPrice(ticker.buy)}
                </td>
                <td data-value="\${ticker.sell}" class="\${sellDiff >= 0 ? 'positive' : 'negative'} \${sellFlash}">
                    \${sellIndicator} \${formatPrice(ticker.sell)}
                </td>
            \`;
            
            setTimeout(() => {
                row.querySelectorAll('.flash-up, .flash-down').forEach(cell => {
                    cell.classList.remove('flash-up', 'flash-down');
                });
            }, 800);
        }
        
        function updateVolumeSection(topVolume, previousVolume) {
            document.getElementById('volumeChartCount').textContent = topVolume.length;
            const tbody = document.getElementById('volumeBody');
            
            const prevMap = {};
            if (previousVolume && Array.isArray(previousVolume)) {
                previousVolume.forEach(v => prevMap[v.pair] = v);
            }
            
            tbody.innerHTML = '';
            
            topVolume.forEach((ticker, index) => {
                const prevTicker = prevMap[ticker.pair];
                
                let priceFlash = '';
                let changeFlash = '';
                let volumeFlash = '';
                
                if (prevTicker) {
                    if (ticker.last > prevTicker.last) {
                        priceFlash = 'flash-up';
                    } else if (ticker.last < prevTicker.last) {
                        priceFlash = 'flash-down';
                    }
                    
                    if (ticker.priceChangePercent > prevTicker.priceChangePercent) {
                        changeFlash = 'flash-up';
                    } else if (ticker.priceChangePercent < prevTicker.priceChangePercent) {
                        changeFlash = 'flash-down';
                    }
                    
                    if (ticker.volume > prevTicker.volume * 1.3) {
                        volumeFlash = 'volume-spike';
                    }
                }
                
                const pairDisplay = ticker.isUsdtPair ? 
                    \`<strong>\${ticker.pair.toUpperCase()}</strong><span class="usdt-badge">USDT</span>\` : 
                    \`<strong>\${ticker.pair.toUpperCase()}</strong>\`;
                
                const priceIndicator = getPriceIndicator(ticker);
                const priceColorClass = ticker.priceChangePercent >= 0 ? 'positive' : 'negative';
                
                const row = tbody.insertRow();
                row.innerHTML = \`
                    <td data-value="\${index + 1}">\${index + 1}</td>
                    <td>\${pairDisplay}</td>
                    <td data-value="\${ticker.last}" class="\${priceColorClass} \${priceFlash}">
                        \${priceIndicator} \${formatPrice(ticker.last)}
                    </td>
                    <td data-value="\${ticker.priceChangePercent}" class="\${ticker.priceChangePercent >= 0 ? 'positive' : 'negative'} \${changeFlash}">
                        \${ticker.priceChangePercent >= 0 ? '▲' : '▼'} \${Math.abs(ticker.priceChangePercent).toFixed(2)}%
                    </td>
                    <td data-value="\${ticker.high}" style="color:#4ade80">▲ \${formatPrice(ticker.high)}</td>
                    <td data-value="\${ticker.low}" style="color:#ef4444">▼ \${formatPrice(ticker.low)}</td>
                    <td data-value="\${ticker.volume}" class="\${volumeFlash}">\${formatVolume(ticker.volume)}</td>
                \`;
                
                setTimeout(() => {
                    row.querySelectorAll('.flash-up, .flash-down').forEach(cell => {
                        cell.classList.remove('flash-up', 'flash-down');
                    });
                }, 800);
            });
            
            // Reapply sort if active
            reapplySortIfActive('volumeTable');
        }
        
        function sortTable(tableId, columnIndex, dataType) {
            const table = document.getElementById(tableId);
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            const headers = table.querySelectorAll('th');
            
            const sortKey = tableId + '_' + columnIndex;
            if (!sortStates[sortKey]) {
                sortStates[sortKey] = 'none';
            }
            
            if (sortStates[sortKey] === 'none' || sortStates[sortKey] === 'desc') {
                sortStates[sortKey] = 'asc';
            } else {
                sortStates[sortKey] = 'desc';
            }
            
            // Save active sort state for this table
            activeSorts[tableId] = {
                column: columnIndex,
                direction: sortStates[sortKey],
                type: dataType
            };
            
            headers.forEach(h => h.classList.remove('asc', 'desc'));
            headers[columnIndex].classList.add(sortStates[sortKey]);
            
            rows.sort((a, b) => {
                const cellA = a.cells[columnIndex];
                const cellB = b.cells[columnIndex];
                
                let valueA, valueB;
                
                if (dataType === 'number') {
                    valueA = parseFloat(cellA.getAttribute('data-value')) || 0;
                    valueB = parseFloat(cellB.getAttribute('data-value')) || 0;
                } else {
                    // Use data-value attribute if available, otherwise use textContent
                    valueA = cellA.getAttribute('data-value') || cellA.textContent.trim();
                    valueB = cellB.getAttribute('data-value') || cellB.textContent.trim();
                    valueA = valueA.toLowerCase();
                    valueB = valueB.toLowerCase();
                }
                
                if (sortStates[sortKey] === 'asc') {
                    return valueA > valueB ? 1 : valueA < valueB ? -1 : 0;
                } else {
                    return valueA < valueB ? 1 : valueA > valueB ? -1 : 0;
                }
            });
            
            rows.forEach(row => tbody.appendChild(row));
        }
        
        // Helper function to reapply sort after table update
        function reapplySortIfActive(tableId) {
            if (activeSorts[tableId]) {
                const sort = activeSorts[tableId];
                const table = document.getElementById(tableId);
                if (!table) return;
                
                const tbody = table.querySelector('tbody');
                const rows = Array.from(tbody.querySelectorAll('tr'));
                const headers = table.querySelectorAll('th');
                
                // Clear header indicators
                headers.forEach(h => h.classList.remove('asc', 'desc'));
                if (headers[sort.column]) {
                    headers[sort.column].classList.add(sort.direction);
                }
                
                // Sort rows
                rows.sort((a, b) => {
                    const cellA = a.cells[sort.column];
                    const cellB = b.cells[sort.column];
                    
                    let valueA, valueB;
                    
                    if (sort.type === 'number') {
                        valueA = parseFloat(cellA.getAttribute('data-value')) || 0;
                        valueB = parseFloat(cellB.getAttribute('data-value')) || 0;
                    } else {
                        // Use data-value attribute if available, otherwise use textContent
                        valueA = cellA.getAttribute('data-value') || cellA.textContent.trim();
                        valueB = cellB.getAttribute('data-value') || cellB.textContent.trim();
                        valueA = valueA.toLowerCase();
                        valueB = valueB.toLowerCase();
                    }
                    
                    if (sort.direction === 'asc') {
                        return valueA > valueB ? 1 : valueA < valueB ? -1 : 0;
                    } else {
                        return valueA < valueB ? 1 : valueA > valueB ? -1 : 0;
                    }
                });
                
                rows.forEach(row => tbody.appendChild(row));
            }
        }
        
        function switchTab(tab, event) {
            document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
            document.querySelectorAll('.content-section').forEach(s => s.classList.remove('active'));
            
            event.target.closest('.tab').classList.add('active');
            document.getElementById(tab).classList.add('active');
        }
        
        function filterTable() {
            const input = document.getElementById('searchBox').value.toUpperCase();
            const tbody = document.getElementById('allMarketsBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[0];
                if (pairCell) {
                    const pairText = pairCell.textContent || pairCell.innerText;
                    row.style.display = pairText.toUpperCase().indexOf(input) > -1 ? '' : 'none';
                }
            }
        }
        
        
        function filterVolumeTable() {
            const input = document.getElementById('searchVolume').value.toUpperCase();
            const tbody = document.getElementById('volumeBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[1];
                if (pairCell) {
                    const pairText = pairCell.textContent || pairCell.innerText;
                    row.style.display = pairText.toUpperCase().indexOf(input) > -1 ? '' : 'none';
                }
            }
        }
        
        function filterBuySignalsTable() {
            const input = document.getElementById('searchBuySignals').value.toUpperCase();
            const tbody = document.getElementById('buySignalsBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[1];
                if (pairCell) {
                    const pairText = pairCell.textContent || pairCell.innerText;
                    row.style.display = pairText.toUpperCase().indexOf(input) > -1 ? '' : 'none';
                }
            }
        }
        
        function filterSellSignalsTable() {
            const input = document.getElementById('searchSellSignals').value.toUpperCase();
            const tbody = document.getElementById('sellSignalsBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[1];
                if (pairCell) {
                    const pairText = pairCell.textContent || pairCell.innerText;
                    row.style.display = pairText.toUpperCase().indexOf(input) > -1 ? '' : 'none';
                }
            }
        }
        
        // Chart modal functions removed
        
        function formatPrice(value) {
            if (!value || value === 0) return 'Rp 0';
            
            if (value >= 1000000) {
                return new Intl.NumberFormat('id-ID', { 
                    style: 'currency', 
                    currency: 'IDR',
                    minimumFractionDigits: 0,
                    maximumFractionDigits: 0
                }).format(value);
            }
            else if (value >= 1000) {
                return new Intl.NumberFormat('id-ID', { 
                    style: 'currency', 
                    currency: 'IDR',
                    minimumFractionDigits: 2,
                    maximumFractionDigits: 2
                }).format(value);
            }
            else if (value >= 1) {
                return new Intl.NumberFormat('id-ID', { 
                    style: 'currency', 
                    currency: 'IDR',
                    minimumFractionDigits: 4,
                    maximumFractionDigits: 4
                }).format(value);
            }
            else if (value >= 0.01) {
                return new Intl.NumberFormat('id-ID', { 
                    style: 'currency', 
                    currency: 'IDR',
                    minimumFractionDigits: 6,
                    maximumFractionDigits: 6
                }).format(value);
            }
            else {
                return new Intl.NumberFormat('id-ID', { 
                    style: 'currency', 
                    currency: 'IDR',
                    minimumFractionDigits: 8,
                    maximumFractionDigits: 8
                }).format(value);
            }
        }
        
        // Format Support/Resistance levels without decimals for proper Rupiah formatting
        function formatSupportResistance(value) {
            if (!value || value === 0) return 'Rp 0';
            
            // Always format without decimals for Support/Resistance levels
            return new Intl.NumberFormat('id-ID', { 
                style: 'currency', 
                currency: 'IDR',
                minimumFractionDigits: 0,
                maximumFractionDigits: 0
            }).format(value);
        }
        
        function formatVolume(value) {
            if (!value || value === 0) return 'Rp 0';
            
            if (value >= 1000000000) {
                return 'Rp ' + (value / 1000000000).toFixed(2) + 'B';
            } else if (value >= 1000000) {
                return 'Rp ' + (value / 1000000).toFixed(2) + 'M';
            } else if (value >= 1000) {
                return 'Rp ' + (value / 1000).toFixed(2) + 'K';
            }
            return new Intl.NumberFormat('id-ID', { 
                style: 'currency', 
                currency: 'IDR',
                minimumFractionDigits: 0,
                maximumFractionDigits: 0
            }).format(value);
        }
        
        // Initialize refresh interval on page load
        const savedInterval = localStorage.getItem('indodax_refresh_interval');
        if (savedInterval) {
            refreshIntervalTime = parseInt(savedInterval);
            const selectEl = document.getElementById('refreshInterval');
            if (selectEl) {
                selectEl.value = savedInterval;
            }
        }
        
        loadMarketData();
        countdownInterval = setInterval(updateCountdown, 1000);
        
        // Start auto refresh
        if (refreshIntervalTime > 0 && !isPaused) {
            refreshIntervalId = setInterval(() => loadMarketData(true), refreshIntervalTime);
        }
        
        window.addEventListener('beforeunload', () => {
            if (countdownInterval) clearInterval(countdownInterval);
            if (refreshIntervalId) clearInterval(refreshIntervalId);
        });
    </script>
</body>
</html>`;
}
