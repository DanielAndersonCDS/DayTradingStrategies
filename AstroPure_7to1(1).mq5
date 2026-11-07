//+------------------------------------------------------------------+
//|  AstroPure_7to1.mq5                                              |
//|  ONLY the rules stated in the video (Norman Winski interview):   |
//|   1. Time matters more than price: turns come at the right time. |
//|   2. Currencies, stocks, bonds, grains and PRECIOUS METALS turn  |
//|      within a day of a new Moon or full Moon.                    |
//|   3. Mercury turning retrograde/direct is another turn window.   |
//|   4. A setup is needed: the market must have moved sharply up or |
//|      sharply down. Sideways = no trade.                          |
//|   5. Market running up -> look to SELL. Going down -> look to BUY|
//|  No candlestick patterns, no moving averages, no oscillators.    |
//|  Stop size, lookback and the 7:1 target are NOT from the video.  |
//|  TEST ON A DEMO ACCOUNT FIRST.                                   |
//+------------------------------------------------------------------+
#property copyright "Personal use"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_ASTRO { ASTRO_OFF = 0, ASTRO_MOON = 1, ASTRO_MERCURY = 2, ASTRO_EITHER = 3 };

input group "Astrology timing (from the video)"
input ENUM_ASTRO InpAstro      = ASTRO_MOON;  // Moon / Mercury / Either (Off = CONTROL: no astro timing)
input double     InpWindowDays = 1.0;         // "Within a day" of the event
input double     InpCtrlShift  = 0.0;         // CONTROL TEST: shift the astro calendar by N days (7.4 for the Moon, 30 for Mercury)

input group "Setup: market moved sharply (from the video, thresholds are mine)"
input int        InpMoveBars   = 24;          // Look back this many bars (H1: 24 = 1 day, H4: 6, D1: 5)
input double     InpMoveATR    = 3.0;         // Net move must be at least this many ATR, otherwise sideways = no trade

input group "Risk management (yours, not from the video)"
input int        InpAtrLen     = 14;          // ATR length
input double     InpStopATR    = 1.5;         // Stop distance in ATR
input double     InpRR         = 7.0;         // Reward : Risk
input double     InpRiskPct    = 1.0;         // Risk per trade, % of equity
input double     InpDailyLoss  = 3.0;         // Stop trading for the day after this % loss (0 = off)
input int        InpMaxSpread  = 80;          // Max spread in points (0 = off)

input group "Break-even / trailing stop (in R, 1R = initial risk)"
input double     InpBeTriggerR = 0.0;         // Move SL once profit reaches this many R (0 = off)
input double     InpBeLockR    = 0.0;         // SL goes to entry + this many R
input double     InpTrailStepR = 1.0;         // Then lock +1 step per extra step of profit (0 = break-even only)

input group "Execution"
input long       InpMagic      = 550055;      // Magic number
input int        InpSlippage   = 30;          // Max slippage (points)

CTrade   trade;
int      hATR = INVALID_HANDLE;
datetime lastBar = 0;
bool     gInit = false, gPrevInWin = false, gTraded = true;

//+------------------------------------------------------------------+
//| Astronomy (low-precision Keplerian elements, Schlyter formulas). |
//| d = days since 2000 Jan 0.0 (UT). Checked against known new /    |
//| full Moons (< 0.1 deg) and Mercury stations (about 1 day).       |
//+------------------------------------------------------------------+
double Rad(double x)     { return x * M_PI / 180.0; }
double NormDeg(double x) { x = MathMod(x, 360.0); if(x < 0) x += 360.0; return x; }

double Kepler(double mDeg, double e)
{
   double m  = Rad(mDeg);
   double ea = m + e * MathSin(m) * (1.0 + e * MathCos(m));
   for(int k = 0; k < 5; k++)
      ea = ea - (ea - e * MathSin(ea) - m) / (1.0 - e * MathCos(ea));
   return ea;
}

// Sun: geocentric ecliptic position, longitude (deg), mean anomaly (deg) and perihelion arg (deg)
void SunPos(double d, double &xs, double &ys, double &lonDeg, double &ms, double &ws)
{
   ws = 282.9404 + 4.70935e-5 * d;
   double e = 0.016709 - 1.151e-9 * d;
   ms = 356.0470 + 0.9856002585 * d;
   double ea = Kepler(ms, e);
   double xv = MathCos(ea) - e;
   double yv = MathSqrt(1.0 - e * e) * MathSin(ea);
   double r  = MathSqrt(xv * xv + yv * yv);
   double lon = MathArctan2(yv, xv) + Rad(ws);
   xs = r * MathCos(lon);
   ys = r * MathSin(lon);
   lonDeg = NormDeg(lon * 180.0 / M_PI);
}

// Moon - Sun elongation in degrees: 0 = new Moon, 180 = full Moon
double MoonElong(double d)
{
   double xs, ys, sunLon, ms, ws;
   SunPos(d, xs, ys, sunLon, ms, ws);
   double nn = 125.1228 - 0.0529538083 * d;
   double w  = 318.0634 + 0.1643573223 * d;
   double e  = 0.054900;
   double mm = 115.3654 + 13.0649929509 * d;
   double ea = Kepler(mm, e);
   double xv = 60.2666 * (MathCos(ea) - e);
   double yv = 60.2666 * MathSqrt(1.0 - e * e) * MathSin(ea);
   double vw = MathArctan2(yv, xv) + Rad(w);
   double r  = MathSqrt(xv * xv + yv * yv);
   double inc = Rad(5.1454);
   double xh = r * (MathCos(Rad(nn)) * MathCos(vw) - MathSin(Rad(nn)) * MathSin(vw) * MathCos(inc));
   double yh = r * (MathSin(Rad(nn)) * MathCos(vw) + MathCos(Rad(nn)) * MathSin(vw) * MathCos(inc));
   double lon = MathArctan2(yh, xh) * 180.0 / M_PI;

   double Ls = ws + ms, Lm = nn + w + mm;
   double D = Lm - Ls, F = Lm - nn, Mm = mm, Ms = ms;
   lon += -1.274 * MathSin(Rad(Mm - 2 * D)) + 0.658 * MathSin(Rad(2 * D)) - 0.186 * MathSin(Rad(Ms))
          - 0.059 * MathSin(Rad(2 * Mm - 2 * D)) - 0.057 * MathSin(Rad(Mm - 2 * D + Ms)) + 0.053 * MathSin(Rad(Mm + 2 * D))
          + 0.046 * MathSin(Rad(2 * D - Ms)) + 0.041 * MathSin(Rad(Mm - Ms)) - 0.035 * MathSin(Rad(D))
          - 0.031 * MathSin(Rad(Mm + Ms)) - 0.015 * MathSin(Rad(2 * F - 2 * D)) + 0.011 * MathSin(Rad(Mm - 4 * D));
   return NormDeg(lon - sunLon);
}

// Mercury geocentric ecliptic longitude in degrees
double MercLon(double d)
{
   double xs, ys, sunLon, ms, ws;
   SunPos(d, xs, ys, sunLon, ms, ws);
   double nn  = Rad(48.3313 + 3.24587e-5 * d);
   double inc = Rad(7.0047 + 5.0e-8 * d);
   double w   = Rad(29.1241 + 1.01444e-5 * d);
   double a   = 0.387098;
   double e   = 0.205635 + 5.59e-10 * d;
   double mm  = 168.6562 + 4.0923344368 * d;
   double ea  = Kepler(mm, e);
   double xv  = a * (MathCos(ea) - e);
   double yv  = a * MathSqrt(1.0 - e * e) * MathSin(ea);
   double vw  = MathArctan2(yv, xv) + w;
   double r   = MathSqrt(xv * xv + yv * yv);
   double xh  = r * (MathCos(nn) * MathCos(vw) - MathSin(nn) * MathSin(vw) * MathCos(inc));
   double yh  = r * (MathSin(nn) * MathCos(vw) + MathCos(nn) * MathSin(vw) * MathCos(inc));
   return MathArctan2(yh + ys, xh + xs) * 180.0 / M_PI;
}

bool MercRetro(double d)       // centered difference: longitude decreasing = retrograde
{
   double diff = MercLon(d + 0.5) - MercLon(d - 0.5);
   double x = MathMod(diff + 540.0, 360.0);
   if(x < 0) x += 360.0;
   return (x - 180.0) < 0;
}

// is time t inside a Moon / Mercury-station window?
bool AstroWindow(datetime t)
{
   if(InpAstro == ASTRO_OFF) return true;
   double d = (double)t / 86400.0 + 2440587.5 - 2451543.5 + InpCtrlShift;
   bool moonNear = false, mercNear = false;
   if(InpAstro == ASTRO_MOON || InpAstro == ASTRO_EITHER)
   {
      double e  = MoonElong(d);
      double dn = MathMin(e, 360.0 - e) / 12.19;     // days from new Moon (12.19 deg/day relative motion)
      double df = MathAbs(e - 180.0) / 12.19;        // days from full Moon
      moonNear = (MathMin(dn, df) <= InpWindowDays);
   }
   if(InpAstro == ASTRO_MERCURY || InpAstro == ASTRO_EITHER)
      mercNear = (MercRetro(d - InpWindowDays) != MercRetro(d + InpWindowDays));   // a station falls inside the window
   return (moonNear || mercNear);
}

//+------------------------------------------------------------------+
int OnInit()
{
   hATR = iATR(_Symbol, _Period, InpAtrLen);
   if(hATR == INVALID_HANDLE) { Print("ATR handle error"); return INIT_FAILED; }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastBar = iTime(_Symbol, _Period, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return true;
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread);
}

bool DailyLimitHit()
{
   if(InpDailyLoss <= 0) return false;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(!HistorySelect(dayStart, TimeCurrent())) return false;
   double pnl = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_SWAP);
   }
   return (pnl <= -AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLoss / 100.0);
}

double CalcLots(bool isBuy, double entry, double riskDist)
{
   double riskCash = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double sl = isBuy ? entry - riskDist : entry + riskDist;
   double profit = 0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, profit)) return 0;
   double lossPerLot = MathAbs(profit);
   if(lossPerLot <= 0) return 0;
   double lots = riskCash / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < vmin) return 0;
   lots = MathMin(lots, vmax);
   int dig = (int)MathMax(0.0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, dig);
}

//+------------------------------------------------------------------+
//| Break-even / ladder: 1R is recovered from the take profit.       |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(InpBeTriggerR <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(tp <= 0) continue;
      double risk = MathAbs(tp - open) / InpRR;
      if(risk <= 0) continue;

      double px    = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profR = (isBuy ? px - open : open - px) / risk;
      if(profR < InpBeTriggerR) continue;

      double steps = (InpTrailStepR > 0) ? MathFloor((profR - InpBeTriggerR) / InpTrailStepR) * InpTrailStepR : 0.0;
      double newSL = NormalizeDouble(isBuy ? open + (InpBeLockR + steps) * risk : open - (InpBeLockR + steps) * risk, _Digits);

      bool better = isBuy ? (newSL > sl + _Point) : (sl <= 0 || newSL < sl - _Point);
      if(!better) continue;
      double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(isBuy  && px - newSL <= minDist) continue;
      if(!isBuy && newSL - px <= minDist) continue;
      trade.PositionModify(tk, newSL, tp);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageTrailing();

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBar) return;
   lastBar = t0;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = InpMoveBars + 3;
   if(CopyRates(_Symbol, _Period, 0, need, r) < need) return;      // r[1] = last closed bar

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) < 1) return;
   double atr = atrBuf[0];
   if(atr <= 0) return;

   //--- window bookkeeping: one trade per astro window, never start mid-window
   bool inWin = AstroWindow(r[1].time);
   if(!gInit) { gInit = true; gPrevInWin = inWin; gTraded = true; return; }
   if(inWin && !gPrevInWin) gTraded = false;
   gPrevInWin = inWin;
   if(!inWin || gTraded) return;

   if(HasPosition()) return;
   if(!SpreadOK() || DailyLimitHit()) return;

   //--- setup: the market must have moved sharply, otherwise "all bets are off"
   double disp = (r[1].close - r[1 + InpMoveBars].close) / atr;
   if(MathAbs(disp) < InpMoveATR) return;

   bool isBuy = (disp < 0);                 // went down -> buy, went up -> sell

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double entry    = isBuy ? tick.ask : tick.bid;
   double riskDist = InpStopATR * atr;
   double minDist  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(riskDist <= minDist) return;

   double lots = CalcLots(isBuy, entry, riskDist);
   if(lots <= 0) return;

   double sl = NormalizeDouble(isBuy ? entry - riskDist : entry + riskDist, _Digits);
   double tp = NormalizeDouble(isBuy ? entry + riskDist * InpRR : entry - riskDist * InpRR, _Digits);

   double margin = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9) return;

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "AstroPure")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "AstroPure");
   if(ok) gTraded = true;
   else   PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
