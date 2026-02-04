// Cloudflare Workers - Indodax Market Analyzer - Full Stock Exchange Style
const INDODAX_API_BASE = 'https://indodax.com/api';

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
      
      let priceChangePercent = 0;
      if (low > 0) {
        priceChangePercent = ((last - low) / low * 100);
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
    
    const tickersWithSignals = validTickers.map(ticker => {
      const signals = {};
      const timeframes = ['15m', '30m', '1h', '2h', '4h', '1d', '3d', '1w', '2w', '1m'];
      
      timeframes.forEach(tf => {
        signals[tf] = analyzeSignalAdvanced(ticker, avgVolume, tf);
      });
      
      return { ...ticker, signals };
    });
    
    const topGainers = [...tickersWithSignals]
      .filter(t => t.priceChangePercent > 0)
      .sort((a, b) => b.priceChangePercent - a.priceChangePercent);
    
    const topLosers = [...tickersWithSignals]
      .filter(t => t.priceChangePercent < 0)
      .sort((a, b) => a.priceChangePercent - b.priceChangePercent);
    
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
        totalGainers: topGainers.length,
        totalLosers: topLosers.length,
        totalVolumeAssets: topVolume.length
      },
      tickers: tickersWithSignals,
      topGainers: topGainers,
      topLosers: topLosers,
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

// Helper function to calculate Fibonacci position for recommendation logic
// This version calculates both support and resistance regardless of signal type
// Used early in signal analysis before type is fully determined
function calculateFibPositionForRecommendation(ticker, high, low, timeframe) {
  const tfMultiplier = {
    '15m': 0.5, '30m': 0.7, '1h': 1.0, '2h': 1.3,
    '4h': 1.8, '1d': 2.5, '3d': 3.5, '1w': 5.0,
    '2w': 6.5, '1m': 8.0
  };
  
  const multiplier = tfMultiplier[timeframe] || 1.0;
  const range = (high - low) * multiplier;
  const last = ticker.last;
  const tolerance = 0.02; // 2%
  
  // Calculate support levels (from high)
  const support1 = high - (range * 0.236);
  const support2 = high - (range * 0.382);
  const support3 = high - (range * 0.618);
  
  // Calculate resistance levels (from low)
  const resistance1 = low + (range * 0.236);
  const resistance2 = low + (range * 0.382);
  const resistance3 = low + (range * 0.618);
  
  const nearSupport = (
    Math.abs(last - support1) / last < tolerance ||
    Math.abs(last - support2) / last < tolerance ||
    Math.abs(last - support3) / last < tolerance
  );
  
  const nearResistance = (
    Math.abs(last - resistance1) / last < tolerance ||
    Math.abs(last - resistance2) / last < tolerance ||
    Math.abs(last - resistance3) / last < tolerance
  );
  
  return { nearSupport, nearResistance };
}

// New getRecommendation function with 15 status levels
function getRecommendation(ticker, bullishCount, bearishCount, winRate, trend, timeframe) {
    const fibPosition = calculateFibPositionForRecommendation(ticker, ticker.high, ticker.low, timeframe);
    if (trend === 'SIDEWAYS' && winRate < 55) return { text: '➖ SIDEWAYS' };
    if (bullishCount >= 7 && winRate >= 85 && fibPosition.nearSupport) return { text: '🟢 BUY STRONG' };
    if (bullishCount >= 6 && winRate >= 75 && fibPosition.nearSupport) return { text: '🟢 BUY NOW' };
    if (bullishCount >= 5 && winRate >= 65) return { text: '🟢 ACCUMULATE' };
    if (bullishCount >= 4 && winRate >= 55 && trend === 'DOWNTREND') return { text: '🟡 WAIT BUY' };
    if (bullishCount >= 3 && bullishCount <= 4 && winRate >= 50) return { text: '🟠 BUY WATCH' };
    if (bullishCount >= 4 && !fibPosition.nearSupport) return { text: '🟡 WAIT BUY' };
    if (bearishCount >= 7 && winRate >= 85 && fibPosition.nearResistance) return { text: '🔴 SELL STRONG' };
    if (bearishCount >= 6 && winRate >= 75 && fibPosition.nearResistance) return { text: '🔴 SELL NOW' };
    if (bearishCount >= 5 && winRate >= 65) return { text: '🟡 DISTRIBUTED' };
    if (bearishCount >= 4 && winRate >= 55 && trend === 'UPTREND') return { text: '🟡 WAIT SELL' };
    if (bearishCount >= 3 && bearishCount <= 4 && winRate >= 50) return { text: '🟠 SELL WATCH' };
    if (bearishCount >= 4 && !fibPosition.nearResistance) return { text: '🟡 WAIT SELL' };
    if (Math.abs(bullishCount - bearishCount) <= 1) return { text: '🟡 WAIT' };
    return { text: '⚪ HOLD' };
  }

function analyzeSignalAdvanced(ticker, avgVolume, timeframe = '1h') {
  let score = 0;
  let signals = [];
  let type = 'HOLD';
  
  const tfMultipliers = {
    '15m': { sensitivity: 1.8, volatility: 1.5, name: '15 Minute' },
    '30m': { sensitivity: 1.6, volatility: 1.4, name: '30 Minute' },
    '1h': { sensitivity: 1.4, volatility: 1.3, name: '1 Hour' },
    '2h': { sensitivity: 1.2, volatility: 1.2, name: '2 Hours' },
    '4h': { sensitivity: 1.0, volatility: 1.0, name: '4 Hours' },
    '1d': { sensitivity: 0.8, volatility: 0.9, name: '1 Day' },
    '3d': { sensitivity: 0.6, volatility: 0.7, name: '3 Days' },
    '1w': { sensitivity: 0.5, volatility: 0.6, name: '1 Week' },
    '2w': { sensitivity: 0.4, volatility: 0.5, name: '2 Week' },
    '1m': { sensitivity: 0.3, volatility: 0.4, name: '1 Month' }
  };
  
  const tfConfig = tfMultipliers[timeframe] || tfMultipliers['1h'];
  
  const pricePosition = ((ticker.last - ticker.low) / (ticker.high - ticker.low)) * 100 || 50;
  
  const momentum = ticker.priceChangePercent * tfConfig.sensitivity;
  let rsiProxy = 50;
  
  if (momentum > 0) {
    rsiProxy = 50 + Math.min(momentum * 3, 50);
  } else {
    rsiProxy = 50 + Math.max(momentum * 3, -50);
  }
  rsiProxy = Math.max(0, Math.min(100, rsiProxy));
  
  const stochRSI = pricePosition;
  
  const volatility = ((ticker.high - ticker.low) / ticker.low) * 100 * tfConfig.volatility;
  const midBand = (ticker.high + ticker.low) / 2;
  const bandWidth = ticker.high - ticker.low;
  
  const distanceFromUpper = ((ticker.high - ticker.last) / bandWidth) * 100;
  const distanceFromLower = ((ticker.last - ticker.low) / bandWidth) * 100;
  
  let bbSignal = 'NEUTRAL';
  if (distanceFromLower < 10) {
    bbSignal = 'OVERSOLD';
  } else if (distanceFromUpper < 10) {
    bbSignal = 'OVERBOUGHT';
  } else if (ticker.last > midBand) {
    bbSignal = 'ABOVE_MID';
  } else {
    bbSignal = 'BELOW_MID';
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
  
  // Detect trend
  let trend = 'SIDEWAYS';
  const trendThreshold = 2 * tfConfig.sensitivity;
  if (momentum > trendThreshold) {
    trend = 'UPTREND';
  } else if (momentum < -trendThreshold) {
    trend = 'DOWNTREND';
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
  
  // 7. Fib Position
  const fibPosition = calculateFibPositionForRecommendation(ticker, ticker.high, ticker.low, timeframe);
  if (fibPosition.nearSupport) bullishCount++;
  else if (fibPosition.nearResistance) bearishCount++;
  
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
  const recommendationData = getRecommendation(ticker, bullishCount, bearishCount, Math.round(winRate), trend, timeframe);
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
                <div class="tab" onclick="switchTab('gainers', event)">
                    🚀 Top Gainers
                    <span class="count-badge" id="gainersCount">0</span>
                </div>
                <div class="tab" onclick="switchTab('losers', event)">
                    📉 Top Losers
                    <span class="count-badge" id="losersCount">0</span>
                </div>
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
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 6, 'string')">Technical Indicators</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 7, 'string')">Signals</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 8, 'number')">Volume</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 9, 'string')">Risk</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 10, 'string')">🎯 Target/SL/Risk</th>
                                        <th class="sortable" onclick="sortTable('buySignalsTable', 11, 'string')">📊 Win Rate</th>
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
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 6, 'string')">Technical Indicators</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 7, 'string')">Signals</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 8, 'number')">Volume</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 9, 'string')">Risk</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 10, 'string')">🎯 Target/SL/Risk</th>
                                        <th class="sortable" onclick="sortTable('sellSignalsTable', 11, 'string')">📊 Win Rate</th>
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
            
            <div id="gainers" class="content-section">
                <div class="table-card">
                    <div class="table-title">🚀 All Top Gainers (24h) - <span id="gainersChartCount">0</span> Assets</div>
                    <input type="text" id="searchGainers" class="search-box" placeholder="🔍 Search gainers..." onkeyup="filterGainersTable()">
                    <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                        <table id="gainersTable">
                            <thead>
                                <tr>
                                    <th class="sortable" onclick="sortTable('gainersTable', 0, 'number')">Rank</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 1, 'string')">Pair</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 2, 'number')">Last Price</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 3, 'number')">24h Change</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 4, 'number')">24h High</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 5, 'number')">24h Low</th>
                                    <th class="sortable" onclick="sortTable('gainersTable', 6, 'number')">Volume</th>
                                </tr>
                            </thead>
                            <tbody id="gainersBody"></tbody>
                        </table>
                    </div>
                </div>
            </div>
            
            <div id="losers" class="content-section">
                <div class="table-card">
                    <div class="table-title">📉 All Top Losers (24h) - <span id="losersChartCount">0</span> Assets</div>
                    <input type="text" id="searchLosers" class="search-box" placeholder="🔍 Search losers..." onkeyup="filterLosersTable()">
                    <div class="table-wrapper" onscroll="handleScroll()" onmouseenter="pauseAutoRefresh()" onmouseleave="resumeAutoRefresh()">
                        <table id="losersTable">
                            <thead>
                                <tr>
                                    <th class="sortable" onclick="sortTable('losersTable', 0, 'number')">Rank</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 1, 'string')">Pair</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 2, 'number')">Last Price</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 3, 'number')">24h Change</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 4, 'number')">24h High</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 5, 'number')">24h Low</th>
                                    <th class="sortable" onclick="sortTable('losersTable', 6, 'number')">Volume</th>
                                </tr>
                            </thead>
                            <tbody id="losersBody"></tbody>
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

        // Calculate RSI from real candle data (14 period)
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
            
            const avgGain = gains / period;
            const avgLoss = losses / period;
            
            if (avgLoss === 0) return 100;
            
            const rs = avgGain / avgLoss;
            const rsi = 100 - (100 / (1 + rs));
            
            return rsi;
        }

        // Calculate StochRSI from real data (14 period)
        function calculateStochRSI(candles, period = 14) {
            if (!candles || candles.length < period * 2) return 50;
            
            const rsiValues = [];
            
            for (let i = period; i < candles.length; i++) {
                const slice = candles.slice(i - period, i + 1);
                rsiValues.push(calculateRSI(slice, period));
            }
            
            if (rsiValues.length < period) return 50;
            
            const recentRSI = rsiValues.slice(-period);
            const minRSI = Math.min(...recentRSI);
            const maxRSI = Math.max(...recentRSI);
            
            if (maxRSI === minRSI) return 50;
            
            const currentRSI = recentRSI[recentRSI.length - 1];
            const stochRSI = ((currentRSI - minRSI) / (maxRSI - minRSI)) * 100;
            
            return stochRSI;
        }

        // Calculate Bollinger Bands from real data (20 period, 2 std dev)
        function calculateBollingerBands(candles, period = 20, stdDev = 2) {
            if (!candles || candles.length < period) {
                return { upper: 0, middle: 0, lower: 0, position: 'MID', posPercent: 50 };
            }
            
            const closes = candles.slice(-period).map(c => c.close);
            const sma = closes.reduce((a, b) => a + b, 0) / period;
            
            const squaredDiffs = closes.map(c => Math.pow(c - sma, 2));
            const variance = squaredDiffs.reduce((a, b) => a + b, 0) / period;
            const std = Math.sqrt(variance);
            
            const upper = sma + (stdDev * std);
            const lower = sma - (stdDev * std);
            const current = candles[candles.length - 1].close;
            
            let position = 'MID';
            const range = upper - lower;
            const posPercent = range > 0 ? ((current - lower) / range) * 100 : 50;
            
            if (posPercent >= 80) position = 'OVERBOUGHT';
            else if (posPercent <= 20) position = 'OVERSOLD';
            else if (posPercent >= 60) position = 'UPPER';
            else if (posPercent <= 40) position = 'LOWER';
            
            return { upper, middle: sma, lower, position, posPercent };
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

        // Calculate MACD from real data (12, 26, 9)
        function calculateMACD(candles, fastPeriod = 12, slowPeriod = 26, signalPeriod = 9) {
            if (!candles || candles.length < slowPeriod) {
                return { macd: 0, signal: 0, histogram: 0 };
            }
            
            const closes = candles.map(c => c.close);
            
            const emaFast = calculateEMA(closes, fastPeriod);
            const emaSlow = calculateEMA(closes, slowPeriod);
            
            const macdLine = emaFast - emaSlow;
            
            // IMPORTANT: Signal line should be a 9-period EMA of MACD values
            // Current implementation uses approximation (MACD * 0.8)
            // TODO: Implement proper signal line as 9-period EMA of MACD history
            // This approximation may produce inaccurate signals
            const signalLine = macdLine * 0.8; // Approximation - not standard MACD
            const histogram = macdLine - signalLine;
            
            return { macd: macdLine, signal: signalLine, histogram };
        }
        
        // Calculate risk level
        function calculateRiskLevel(ticker, signal, avgVolume) {
            let riskScore = 0;
            
            // Volatility check
            const volatility = ((ticker.high - ticker.low) / ticker.low) * 100;
            if (volatility > 20) riskScore += 3;
            else if (volatility > 10) riskScore += 2;
            else if (volatility > 5) riskScore += 1;
            
            // Volume check
            const volumeRatio = ticker.volume / avgVolume;
            if (volumeRatio < 0.5) riskScore += 2;
            else if (volumeRatio < 1) riskScore += 1;
            
            // Spread check
            if (ticker.buy > 0 && ticker.sell > 0) {
                const spread = ((ticker.sell - ticker.buy) / ticker.buy) * 100;
                if (spread > 5) riskScore += 2;
                else if (spread > 2) riskScore += 1;
            }
            
            // Determine risk level
            if (riskScore >= 5) return { level: 'HIGH', color: '#ef4444', icon: '🔴', class: 'risk-high' };
            if (riskScore >= 3) return { level: 'MEDIUM', color: '#f59e0b', icon: '🟡', class: 'risk-medium' };
            return { level: 'LOW', color: '#22c55e', icon: '🟢', class: 'risk-low' };
        }
        
        // Calculate Fibonacci Retracement with proper timeframe multipliers
        function calculateFibonacciRetracement(high, low, last, signalType, timeframe) {
            // Fibonacci Levels
            const FIB_LEVELS = {
                236: 0.236,
                382: 0.382,
                500: 0.500,
                618: 0.618,
                786: 0.786
            };
            
            // Timeframe multiplier untuk range
            const tfMultiplier = {
                '15m': 0.5, '30m': 0.7, '1h': 1.0, '2h': 1.3,
                '4h': 1.8, '1d': 2.5, '3d': 3.5, '1w': 5.0,
                '2w': 6.5, '1m': 8.0
            };
            
            const multiplier = tfMultiplier[timeframe] || 1.0;
            const range = (high - low) * multiplier;
            
            if (signalType === 'BUY') {
                // Uptrend: Retracement dari High ke Low
                const fib236 = high - (range * FIB_LEVELS[236]);
                const fib382 = high - (range * FIB_LEVELS[382]);
                const fib618 = high - (range * FIB_LEVELS[618]);
                
                // Sort descending (S1 > S2 > S3)
                let supports = [fib236, fib382, fib618].sort((a, b) => b - a);
                
                return {
                    type: 'SUPPORT',
                    level1: supports[0],
                    level2: supports[1],
                    level3: supports[2],
                    stopLoss: low * (1 - (0.02 * multiplier))
                };
                
            } else { // SELL
                // Downtrend: Retracement dari Low ke High
                const fib236 = low + (range * FIB_LEVELS[236]);
                const fib382 = low + (range * FIB_LEVELS[382]);
                const fib618 = low + (range * FIB_LEVELS[618]);
                
                // Sort ascending (R1 < R2 < R3)
                let resistances = [fib236, fib382, fib618].sort((a, b) => a - b);
                
                return {
                    type: 'RESISTANCE',
                    level1: resistances[0],
                    level2: resistances[1],
                    level3: resistances[2],
                    stopLoss: high * (1 + (0.02 * multiplier))
                };
            }
        }
        
        // Calculate Target/SL/Risk using Fibonacci Retracement
        function calculateTargetSLRisk(ticker, signal, timeframe = '1h') {
            const last = ticker.last;
            const high = ticker.high;
            const low = ticker.low;
            
            // Use the new Fibonacci Retracement function
            const fib = calculateFibonacciRetracement(high, low, last, signal.type, timeframe);
            
            let result = {
                targets: [],
                stopLoss: fib.stopLoss,
                riskReward: 0,
                entry: last
            };
            
            if (signal.type === 'SELL') {
                result.targets = [
                    { label: 'Resistance 1', value: fib.level1 },
                    { label: 'Resistance 2', value: fib.level2 },
                    { label: 'Resistance 3', value: fib.level3 }
                ];
                
                const target = fib.level2;
                const risk = Math.abs(last - fib.stopLoss);
                const reward = Math.abs(target - last);
                result.riskReward = risk > 0 ? (reward / risk).toFixed(1) : 0;
                
            } else if (signal.type === 'BUY') {
                result.targets = [
                    { label: 'Support 1', value: fib.level1 },
                    { label: 'Support 2', value: fib.level2 },
                    { label: 'Support 3', value: fib.level3 }
                ];
                
                const target = last + (last - fib.level2);
                const risk = Math.abs(last - fib.stopLoss);
                const reward = Math.abs(target - last);
                result.riskReward = risk > 0 ? (reward / risk).toFixed(1) : 0;
            }
            
            return result;
        }
        
        // Helper function: Calculate Fib Position based on signal type
        // This version uses signal.type to determine which levels to check
        // Used in win rate calculation where signal type is already known
        function calculateFibPosition(ticker, signal, timeframe) {
            const fib = calculateFibonacciRetracement(ticker.high, ticker.low, ticker.last, signal.type, timeframe);
            const last = ticker.last;
            const tolerance = 0.02; // 2%
            
            let nearSupport = false;
            let nearResistance = false;
            
            if (signal.type === 'BUY') {
                // Cek apakah dekat support levels
                nearSupport = (
                    Math.abs(last - fib.level1) / last < tolerance ||
                    Math.abs(last - fib.level2) / last < tolerance ||
                    Math.abs(last - fib.level3) / last < tolerance
                );
            } else if (signal.type === 'SELL') {
                // Cek apakah dekat resistance levels
                nearResistance = (
                    Math.abs(last - fib.level1) / last < tolerance ||
                    Math.abs(last - fib.level2) / last < tolerance ||
                    Math.abs(last - fib.level3) / last < tolerance
                );
            }
            
            return { nearSupport, nearResistance };
        }
        
        // Calculate Win Rate based on 8 indicators
        function calculateWinRate(ticker, signal, avgVolume, timeframe = '1h') {
            // Use the counts already calculated in analyzeSignalAdvanced
            const bullishCount = signal.bullishCount || 0;
            const bearishCount = signal.bearishCount || 0;
            const totalIndicators = 8;
            
            // Use the win rate already calculated
            let winRate = signal.winRate || 50;
            
            const ind = signal.indicators;
            const rsi = parseFloat(ind.rsi);
            const stochRSI = parseFloat(ind.stochRSI);
            const bbPosition = ind.bbPosition;
            const macd = parseFloat(ind.macd);
            const momentum = parseFloat(ind.momentum);
            const volumeRatio = parseFloat(ind.volumeRatio);
            const trend = ind.trend;
            
            // Calculate statuses for display
            const rsiStatus = rsi < 30 ? 'bullish' : rsi > 70 ? 'bearish' : 'neutral';
            const stochStatus = stochRSI < 20 ? 'bullish' : stochRSI > 80 ? 'bearish' : 'neutral';
            const bbStatus = bbPosition === 'OVERSOLD' ? 'bullish' : bbPosition === 'OVERBOUGHT' ? 'bearish' : 'neutral';
            const macdStatus = macd > 0 ? 'bullish' : macd < 0 ? 'bearish' : 'neutral';
            const momentumStatus = momentum > 0 ? 'bullish' : momentum < 0 ? 'bearish' : 'neutral';
            
            const priceUp = ind.priceUp;
            const priceDown = ind.priceDown;
            const volumeSpike = ind.volumeSpike;
            const volStatus = (volumeSpike && priceUp) ? 'bullish' : (volumeSpike && priceDown) ? 'bearish' : 'neutral';
            
            const fibPosition = calculateFibPosition(ticker, signal, timeframe);
            const fibStatus = fibPosition.nearSupport ? 'bullish' : fibPosition.nearResistance ? 'bearish' : 'neutral';
            
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
                    fib: fibStatus === 'bullish' ? '✅' : fibStatus === 'bearish' ? '❌' : '➖',
                    trend: trendStatus === 'bullish' ? '✅' : trendStatus === 'bearish' ? '❌' : '➖'
                }
            };
        }
        
        // Format Target/SL/Risk display
        function formatTargetSLDisplay(targetData, signal) {
            if (signal.type === 'SELL') {
                return \`
                    <div style="font-size:11px;line-height:1.4;">
                        🔴 \${targetData.targets[0].label}: \${formatPrice(targetData.targets[0].value)}<br>
                        🔴 \${targetData.targets[1].label}: \${formatPrice(targetData.targets[1].value)}<br>
                        🔴 \${targetData.targets[2].label}: \${formatPrice(targetData.targets[2].value)}<br>
                        🛑 SL: \${formatPrice(targetData.stopLoss)}<br>
                        💎 R/R: 1:\${targetData.riskReward}
                    </div>
                \`;
            } else {
                return \`
                    <div style="font-size:11px;line-height:1.4;">
                        🟢 \${targetData.targets[0].label}: \${formatPrice(targetData.targets[0].value)}<br>
                        🟢 \${targetData.targets[1].label}: \${formatPrice(targetData.targets[1].value)}<br>
                        🟢 \${targetData.targets[2].label}: \${formatPrice(targetData.targets[2].value)}<br>
                        🛑 SL: \${formatPrice(targetData.stopLoss)}<br>
                        💎 R/R: 1:\${targetData.riskReward}
                    </div>
                \`;
            }
        }
        
        // Format Win Rate display
        // Format Win Rate display
        function formatWinRateDisplay(winRateData) {
            const details = winRateData.details;
            const count = winRateData.bullish > 0 ? winRateData.bullish : winRateData.bearish;
            
            return \`
                <div style="font-size:11px;line-height:1.5;">
                    📊 Win Rate<br>
                    <strong>\${winRateData.winRate}%</strong> \${winRateData.accuracy}<br>
                    ─────────<br>
                    RSI: \${details.rsi} StochRSI: \${details.stochRSI} BB: \${details.bb}<br>
                    MACD: \${details.macd} Vol: \${details.volume} Fib: \${details.fib}<br>
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
                searchGainers: document.getElementById('searchGainers')?.value || '',
                searchLosers: document.getElementById('searchLosers')?.value || '',
                searchVolume: document.getElementById('searchVolume')?.value || '',
                searchBuySignals: document.getElementById('searchBuySignals')?.value || '',
                searchSellSignals: document.getElementById('searchSellSignals')?.value || ''
            };
            
            // Save scroll positions to prevent jump during refresh
            const scrollPositions = {
                allMarkets: document.querySelector('#allMarkets .table-wrapper')?.scrollTop || 0,
                gainers: document.querySelector('#gainers .table-wrapper')?.scrollTop || 0,
                losers: document.querySelector('#losers .table-wrapper')?.scrollTop || 0,
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
            
            document.getElementById('gainersCount').textContent = data.stats.totalGainers || 0;
            document.getElementById('losersCount').textContent = data.stats.totalLosers || 0;
            document.getElementById('volumeCount').textContent = data.stats.totalVolumeAssets || 0;
            
            updateAllMarketsTable(data.tickers, previousMarketData ? previousMarketData.tickers : null);
            
            if (data.topGainers && data.topGainers.length > 0) {
                updateGainersSection(data.topGainers, previousMarketData ? previousMarketData.topGainers : null);
            }
            if (data.topLosers && data.topLosers.length > 0) {
                updateLosersSection(data.topLosers, previousMarketData ? previousMarketData.topLosers : null);
            }
            if (data.topVolume && data.topVolume.length > 0) {
                updateVolumeSection(data.topVolume, previousMarketData ? previousMarketData.topVolume : null);
            }
            updateSignalsSection(data.tickers, previousMarketData ? previousMarketData.tickers : null);
            
            // Restore search box values after refresh
            const searchBoxEl = document.getElementById('searchBox');
            const searchGainersEl = document.getElementById('searchGainers');
            const searchLosersEl = document.getElementById('searchLosers');
            const searchVolumeEl = document.getElementById('searchVolume');
            const searchBuySignalsEl = document.getElementById('searchBuySignals');
            const searchSellSignalsEl = document.getElementById('searchSellSignals');
            
            if (searchBoxEl) searchBoxEl.value = searchValues.searchBox;
            if (searchGainersEl) searchGainersEl.value = searchValues.searchGainers;
            if (searchLosersEl) searchLosersEl.value = searchValues.searchLosers;
            if (searchVolumeEl) searchVolumeEl.value = searchValues.searchVolume;
            if (searchBuySignalsEl) searchBuySignalsEl.value = searchValues.searchBuySignals;
            if (searchSellSignalsEl) searchSellSignalsEl.value = searchValues.searchSellSignals;
            
            // Re-apply filters if there were search values
            if (searchValues.searchBox) filterTable();
            if (searchValues.searchGainers) filterGainersTable();
            if (searchValues.searchLosers) filterLosersTable();
            if (searchValues.searchVolume) filterVolumeTable();
            if (searchValues.searchBuySignals) filterBuySignalsTable();
            if (searchValues.searchSellSignals) filterSellSignalsTable();
            
            previousMarketData = JSON.parse(JSON.stringify(data));
            
            // Restore scroll positions immediately after DOM update
            requestAnimationFrame(() => {
                const allMarketsWrapper = document.querySelector('#allMarkets .table-wrapper');
                const gainersWrapper = document.querySelector('#gainers .table-wrapper');
                const losersWrapper = document.querySelector('#losers .table-wrapper');
                const volumeWrapper = document.querySelector('#volume .table-wrapper');
                const buySignalsWrapper = document.querySelector('#buySignalsTable')?.closest('.table-wrapper');
                const sellSignalsWrapper = document.querySelector('#sellSignalsTable')?.closest('.table-wrapper');
                
                if (allMarketsWrapper) allMarketsWrapper.scrollTop = scrollPositions.allMarkets;
                if (gainersWrapper) gainersWrapper.scrollTop = scrollPositions.gainers;
                if (losersWrapper) losersWrapper.scrollTop = scrollPositions.losers;
                if (volumeWrapper) volumeWrapper.scrollTop = scrollPositions.volume;
                if (buySignalsWrapper) buySignalsWrapper.scrollTop = scrollPositions.buySignals;
                if (sellSignalsWrapper) sellSignalsWrapper.scrollTop = scrollPositions.sellSignals;
            });
        }
        
        // UPDATED: Hanya return ▲ atau ▼ berdasarkan 24h change
        function getPriceIndicator(ticker) {
            return ticker.priceChangePercent >= 0 ? '▲' : '▼';
        }
        
        // Format signals list vertically (8 indicators)
        function formatSignalsList(signal, ticker) {
            const ind = signal.indicators;
            const rsi = parseFloat(ind.rsi);
            const stochRSI = parseFloat(ind.stochRSI);
            const bbPosition = ind.bbPosition;
            const macd = parseFloat(ind.macd);
            const momentum = parseFloat(ind.momentum);
            const volumeRatio = parseFloat(ind.volumeRatio);
            const trend = ind.trend;
            
            const signalsList = [];
            
            // 1. RSI Signal
            if (rsi < 30) {
                signalsList.push(\`<div class="signal-item bullish">✅ RSI Oversold (\${rsi})</div>\`);
            } else if (rsi > 70) {
                signalsList.push(\`<div class="signal-item bearish">❌ RSI Overbought (\${rsi})</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">📊 RSI: \${rsi}</div>\`);
            }
            
            // 2. StochRSI Signal
            if (stochRSI < 20) {
                signalsList.push(\`<div class="signal-item bullish">✅ StochRSI Oversold (\${stochRSI.toFixed(0)})</div>\`);
            } else if (stochRSI > 80) {
                signalsList.push(\`<div class="signal-item bearish">❌ StochRSI Overbought (\${stochRSI.toFixed(0)})</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">🎯 StochRSI: \${stochRSI.toFixed(0)}</div>\`);
            }
            
            // 3. BB Signal
            if (bbPosition === 'OVERSOLD') {
                signalsList.push(\`<div class="signal-item bullish">✅ BB: Near Lower</div>\`);
            } else if (bbPosition === 'OVERBOUGHT') {
                signalsList.push(\`<div class="signal-item bearish">❌ BB: Near Upper</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">📉 BB: \${bbPosition}</div>\`);
            }
            
            // 4. MACD Signal
            if (macd > 0) {
                signalsList.push(\`<div class="signal-item bullish">✅ MACD: Bullish (+\${macd.toFixed(0)})</div>\`);
            } else if (macd < 0) {
                signalsList.push(\`<div class="signal-item bearish">❌ MACD: Bearish (\${macd.toFixed(0)})</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">📊 MACD: Neutral</div>\`);
            }
            
            // 5. Volume Signal
            if (ind.volumeSpike) {
                if (ind.priceUp) {
                    signalsList.push(\`<div class="signal-item bullish">🔥 Volume: \${volumeRatio.toFixed(1)}x Spike + Price Up</div>\`);
                } else if (ind.priceDown) {
                    signalsList.push(\`<div class="signal-item bearish">🔥 Volume: \${volumeRatio.toFixed(1)}x Spike + Price Down</div>\`);
                } else {
                    signalsList.push(\`<div class="signal-item neutral">🔥 Volume: \${volumeRatio.toFixed(1)}x Spike</div>\`);
                }
            } else {
                signalsList.push(\`<div class="signal-item neutral">📊 Volume: \${volumeRatio.toFixed(1)}x Avg</div>\`);
            }
            
            // 6. Momentum Signal
            if (momentum > 0) {
                signalsList.push(\`<div class="signal-item bullish">↗️ Momentum: +\${momentum.toFixed(1)}%</div>\`);
            } else if (momentum < 0) {
                signalsList.push(\`<div class="signal-item bearish">↘️ Momentum: \${momentum.toFixed(1)}%</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">➡️ Momentum: Flat</div>\`);
            }
            
            // 7. Fib Position Signal (simplified - we'll show in technical indicators)
            signalsList.push(\`<div class="signal-item neutral">📐 Fib: Check Technical</div>\`);
            
            // 8. Trend Signal
            if (trend === 'UPTREND') {
                signalsList.push(\`<div class="signal-item bullish">📈 Trend: Uptrend</div>\`);
            } else if (trend === 'DOWNTREND') {
                signalsList.push(\`<div class="signal-item bearish">📉 Trend: Downtrend</div>\`);
            } else {
                signalsList.push(\`<div class="signal-item neutral">⚪ Trend: Sideways</div>\`);
            }
            
            return \`<div class="signals-list">\${signalsList.join('')}</div>\`;
        }
        
        // Format technical indicators vertically (8 indicators + Fib levels)
        function formatTechnicalIndicators(signal, ticker, timeframe) {
            const ind = signal.indicators;
            const fib = calculateFibonacciRetracement(ticker.high, ticker.low, ticker.last, signal.type, timeframe);
            
            const techList = [];
            
            techList.push(\`<div class="tech-item">RSI (14): \${ind.rsi} \${parseFloat(ind.rsi) < 30 ? '✅ Oversold' : parseFloat(ind.rsi) > 70 ? '❌ Overbought' : ''}</div>\`);
            techList.push(\`<div class="tech-item">StochRSI (14): \${ind.stochRSI} \${parseFloat(ind.stochRSI) < 20 ? '✅ Oversold' : parseFloat(ind.stochRSI) > 80 ? '❌ Overbought' : ''}</div>\`);
            techList.push(\`<div class="tech-item">BB (20,2): \${ind.bbPosition === 'OVERSOLD' ? 'Near Lower' : ind.bbPosition === 'OVERBOUGHT' ? 'Near Upper' : ind.bbPosition}</div>\`);
            techList.push(\`<div class="tech-item">MACD (12,26,9): \${ind.macd} \${parseFloat(ind.macd) > 0 ? '📈 Bullish' : parseFloat(ind.macd) < 0 ? '📉 Bearish' : ''}</div>\`);
            techList.push(\`<div class="tech-item">Volume: \${ind.volumeRatio}x Avg \${ind.volumeSpike ? '🔥 Spike' : ''}</div>\`);
            techList.push(\`<div class="tech-item">Momentum: \${ind.momentum}% \${parseFloat(ind.momentum) > 0 ? '↗️' : parseFloat(ind.momentum) < 0 ? '↘️' : '➡️'}</div>\`);
            
            // Fibonacci levels
            if (signal.type === 'BUY') {
                techList.push(\`<div class="tech-item">Fib 23.6%: \${formatPrice(fib.level1)}</div>\`);
                techList.push(\`<div class="tech-item">Fib 38.2%: \${formatPrice(fib.level2)}</div>\`);
                techList.push(\`<div class="tech-item">Fib 61.8%: \${formatPrice(fib.level3)}</div>\`);
                techList.push(\`<div class="tech-item">Fib Position: Near Support</div>\`);
            } else {
                techList.push(\`<div class="tech-item">Fib 23.6%: \${formatPrice(fib.level1)}</div>\`);
                techList.push(\`<div class="tech-item">Fib 38.2%: \${formatPrice(fib.level2)}</div>\`);
                techList.push(\`<div class="tech-item">Fib 61.8%: \${formatPrice(fib.level3)}</div>\`);
                techList.push(\`<div class="tech-item">Fib Position: Near Resistance</div>\`);
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
                buyBody.innerHTML = '<tr><td colspan="13" style="text-align:center;color:#9ca3af;">No buy signals for this timeframe</td></tr>';
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
                        <td data-value="\${technicalIndicatorsText}" class="technical-cell">
                            \${technicalIndicatorsDisplay}
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
                sellBody.innerHTML = '<tr><td colspan="13" style="text-align:center;color:#9ca3af;">No sell signals for this timeframe</td></tr>';
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
                        <td data-value="\${technicalIndicatorsText}" class="technical-cell">
                            \${technicalIndicatorsDisplay}
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
        
        function updateGainersSection(gainers, previousGainers) {
            document.getElementById('gainersChartCount').textContent = gainers.length;
            const tbody = document.getElementById('gainersBody');
            
            const prevMap = {};
            if (previousGainers && Array.isArray(previousGainers)) {
                previousGainers.forEach(g => prevMap[g.pair] = g);
            }
            
            tbody.innerHTML = '';
            
            gainers.forEach((ticker, index) => {
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
                    <td data-value="\${ticker.priceChangePercent}" class="positive \${changeFlash}">
                        ▲ \${ticker.priceChangePercent.toFixed(2)}%
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
            reapplySortIfActive('gainersTable');
        }
        
        function updateLosersSection(losers, previousLosers) {
            document.getElementById('losersChartCount').textContent = losers.length;
            const tbody = document.getElementById('losersBody');
            
            const prevMap = {};
            if (previousLosers && Array.isArray(previousLosers)) {
                previousLosers.forEach(l => prevMap[l.pair] = l);
            }
            
            tbody.innerHTML = '';
            
            losers.forEach((ticker, index) => {
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
                    <td data-value="\${ticker.priceChangePercent}" class="negative \${changeFlash}">
                        ▼ \${Math.abs(ticker.priceChangePercent).toFixed(2)}%
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
            reapplySortIfActive('losersTable');
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
        
        function filterGainersTable() {
            const input = document.getElementById('searchGainers').value.toUpperCase();
            const tbody = document.getElementById('gainersBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[1];
                if (pairCell) {
                    const pairText = pairCell.textContent || pairCell.innerText;
                    row.style.display = pairText.toUpperCase().indexOf(input) > -1 ? '' : 'none';
                }
            }
        }
        
        function filterLosersTable() {
            const input = document.getElementById('searchLosers').value.toUpperCase();
            const tbody = document.getElementById('losersBody');
            const rows = tbody.getElementsByTagName('tr');
            
            for (let row of rows) {
                const pairCell = row.getElementsByTagName('td')[1];
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
