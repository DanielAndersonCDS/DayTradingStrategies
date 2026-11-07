//+------------------------------------------------------------------+
//|  MSOsc_7to1.mq5                                                  |
//|  Market structure (CHoCH / BoS) + trend-filtered momentum        |
//|  oscillator + divergence. Rebuilt from the public description of |
//|  "Market Structure Oscillator [BigBeluga]". NOT the original     |
//|  source code.                                                    |
//|  Signals use the last CLOSED candle, orders go in at the next    |
//|  open, one position at a time. TEST ON A DEMO ACCOUNT FIRST.     |
//+------------------------------------------------------------------+
#property copyright "Personal use"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_MODE { MODE_CHOCH_BOS = 0, MODE_CHOCH = 1, MODE_BOS = 2, MODE_DIV = 3, MODE_ALL = 4 };

input group "Signals"
input ENUM_MODE InpMode        = MODE_CHOCH_BOS; // Entry signal
input int       InpMsLeft      = 8;              // Market structure pivot left
input int       InpMsRight     = 8;              // Market structure pivot right
input int       InpMomLen      = 20;             // Momentum length
input int       InpSmooth      = 5;              // Smoothing length
input int       InpDivLeft     = 5;              // Divergence pivot left
input int       InpDivRight    = 5;              // Divergence pivot right
input double    InpMinStrength = 0.0;            // Min momentum strength for breaks (0 = off)

input group "Risk"
input int       InpAtrLen      = 14;             // ATR length
input double    InpRR          = 7.0;            // Reward : Risk
input double    InpRiskPct     = 1.0;            // Risk per trade, % of equity
input double    InpStopBuf     = 0.1;            // Stop buffer beyond swing (ATR x)
input double    InpMinStop     = 1.0;            // Min stop distance (ATR x)
input double    InpMaxStop     = 4.0;            // Max stop distance (ATR x), skip if wider
input int       InpMaxBars     = 0;              // Time stop in bars (0 = off)
input double    InpDailyLoss   = 3.0;            // Stop trading for the day after this % loss (0 = off)

input group "Filters (broker SERVER time)"
input bool      InpUseSession  = false;          // Use session filter
input int       InpStartHour   = 10;             // Session start hour (server time)
input int       InpEndHour     = 19;             // Session end hour (server time)
input int       InpMaxSpread   = 80;             // Max spread in points (0 = off)

input group "Execution"
input long      InpMagic       = 880088;         // Magic number
input int       InpSlippage    = 30;             // Max slippage (points)
input int       InpWarmBars    = 1500;           // Bars of history used to warm up the engine

CTrade   trade;
datetime lastBar    = 0;
datetime lastPushed = 0;

//--- engine data (oldest bar = index 0)
double gH[], gL[], gC[], gOsc[];
int    gN = 0;

//--- engine state
int    trend = 0, bosCnt = 0;
double shP = 0, slP = 0;
bool   shValid = false, slValid = false, shBroken = true, slBroken = true;
double atrVal = 0, atrSum = 0;
bool   atrReady = false;
double emaVal = 0;
bool   emaInit = false;
bool   phValid = false, plValid = false;
double prevPhOsc = 0, prevPhPx = 0, prevPlOsc = 0, prevPlPx = 0;

//--- output of the last processed bar
int    sigDir = 0;
double sigRef = 0, sigAtr = 0, sigClose = 0;

//+------------------------------------------------------------------+
bool IsPivotHigh(const double &a[], int k, int L, int R)
{
   for(int j = 1; j <= L; j++) if(a[k - j] >= a[k]) return false;
   for(int j = 1; j <= R; j++) if(a[k + j] >  a[k]) return false;
   return true;
}

bool IsPivotLow(const double &a[], int k, int L, int R)
{
   for(int j = 1; j <= L; j++) if(a[k - j] <= a[k]) return false;
   for(int j = 1; j <= R; j++) if(a[k + j] <  a[k]) return false;
   return true;
}

double StdDevPop(const double &a[], int endIdx, int len)
{
   double s = 0;
   for(int j = endIdx - len + 1; j <= endIdx; j++) s += a[j];
   double m = s / len, v = 0;
   for(int j = endIdx - len + 1; j <= endIdx; j++) v += (a[j] - m) * (a[j] - m);
   v /= len;
   return (v > 0) ? MathSqrt(v) : 0.0;
}

//+------------------------------------------------------------------+
//| Feed one CLOSED candle into the engine.                          |
//+------------------------------------------------------------------+
void Push(double h, double l, double c)
{
   int i = gN;
   gN++;
   ArrayResize(gH,   gN, 4096);
   ArrayResize(gL,   gN, 4096);
   ArrayResize(gC,   gN, 4096);
   ArrayResize(gOsc, gN, 4096);
   gH[i] = h; gL[i] = l; gC[i] = c;

   sigDir = 0; sigRef = 0; sigAtr = 0; sigClose = c;

   //--- ATR (Wilder)
   double tr = (i == 0) ? (h - l) : MathMax(h - l, MathMax(MathAbs(h - gC[i - 1]), MathAbs(l - gC[i - 1])));
   if(!atrReady)
   {
      atrSum += tr;
      if(i + 1 == InpAtrLen) { atrVal = atrSum / InpAtrLen; atrReady = true; }
   }
   else
      atrVal = (atrVal * (InpAtrLen - 1) + tr) / InpAtrLen;

   //--- 1. structural pivots (confirmed InpMsRight bars late)
   int k = i - InpMsRight;
   if(k >= InpMsLeft)
   {
      if(IsPivotHigh(gH, k, InpMsLeft, InpMsRight)) { shP = gH[k]; shValid = true; shBroken = false; }
      if(IsPivotLow (gL, k, InpMsLeft, InpMsRight)) { slP = gL[k]; slValid = true; slBroken = false; }
   }

   //--- breaks
   bool brkUp = shValid && !shBroken && c > shP;
   bool brkDn = slValid && !slBroken && c < slP;
   if(brkUp && brkDn) { brkUp = false; brkDn = false; }

   bool chochUp = false, bosUp = false, chochDn = false, bosDn = false;
   double refUp = 0, refDn = 0;
   if(brkUp)
   {
      chochUp = (trend != 1);
      bosUp   = (trend == 1);
      bosCnt  = bosUp ? bosCnt + 1 : 1;
      refUp   = slValid ? slP : 0;
      trend   = 1;
      shBroken = true;
   }
   if(brkDn)
   {
      chochDn = (trend != -1);
      bosDn   = (trend == -1);
      bosCnt  = bosDn ? bosCnt + 1 : 1;
      refDn   = shValid ? shP : 0;
      trend   = -1;
      slBroken = true;
   }

   //--- 2. oscillator: ROC / volatility -> sigmoid -> EMA -> forced by structure
   double raw = 0;
   if(i >= InpMomLen)
   {
      double sd = StdDevPop(gC, i, InpMomLen);
      if(sd > 0) raw = (c - gC[i - InpMomLen]) / sd;
   }
   double sg = 100.0 / (1.0 + MathExp(-raw));
   if(!emaInit) { emaVal = sg; emaInit = true; }
   else         { double al = 2.0 / (InpSmooth + 1.0); emaVal = al * sg + (1.0 - al) * emaVal; }
   double osc = emaVal;
   if(trend ==  1) osc = MathMax(osc, 50.0);
   if(trend == -1) osc = MathMin(osc, 50.0);
   gOsc[i] = osc;

   //--- 3. divergence
   bool bullDiv = false, bearDiv = false;
   double divHigh = 0, divLow = 0;
   int kd = i - InpDivRight;
   if(kd >= InpDivLeft)
   {
      if(IsPivotHigh(gOsc, kd, InpDivLeft, InpDivRight))
      {
         double px = gH[kd];
         if(phValid && px > prevPhPx && gOsc[kd] < prevPhOsc) { bearDiv = true; divHigh = px; }
         phValid = true; prevPhOsc = gOsc[kd]; prevPhPx = px;
      }
      if(IsPivotLow(gOsc, kd, InpDivLeft, InpDivRight))
      {
         double px = gL[kd];
         if(plValid && px < prevPlPx && gOsc[kd] > prevPlOsc) { bullDiv = true; divLow = px; }
         plValid = true; prevPlOsc = gOsc[kd]; prevPlPx = px;
      }
   }

   //--- signals
   bool useChoch = (InpMode == MODE_CHOCH_BOS || InpMode == MODE_CHOCH || InpMode == MODE_ALL);
   bool useBos   = (InpMode == MODE_CHOCH_BOS || InpMode == MODE_BOS   || InpMode == MODE_ALL);
   bool useDiv   = (InpMode == MODE_DIV || InpMode == MODE_ALL);

   bool longBrk  = ((useChoch && chochUp) || (useBos && bosUp)) && osc >= 50.0 + InpMinStrength;
   bool shortBrk = ((useChoch && chochDn) || (useBos && bosDn)) && osc <= 50.0 - InpMinStrength;
   bool longDiv  = useDiv && bullDiv;
   bool shortDiv = useDiv && bearDiv;
   bool longSig  = longBrk  || longDiv;
   bool shortSig = shortBrk || shortDiv;
   if(longSig == shortSig) return;            // none, or conflicting

   if(longSig)
   {
      sigDir = 1;
      sigRef = (longBrk && refUp > 0) ? refUp : (longDiv ? divLow : 0);
   }
   else
   {
      sigDir = -1;
      sigRef = (shortBrk && refDn > 0) ? refDn : (shortDiv ? divHigh : 0);
   }
   sigAtr = atrReady ? atrVal : 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   //--- warm up the engine with history (no trading)
   MqlRates hist[];
   int got = CopyRates(_Symbol, _Period, 1, InpWarmBars, hist);
   if(got < 200)
   {
      Print("Not enough history to warm up: ", got);
      return INIT_FAILED;
   }
   for(int j = 0; j < got; j++)
   {
      Push(hist[j].high, hist[j].low, hist[j].close);
      lastPushed = hist[j].time;
   }
   lastBar = iTime(_Symbol, _Period, 0);   // trade from the NEXT new bar on
   return INIT_SUCCEEDED;
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

void ManageTimeStop()
{
   if(InpMaxBars <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(iBarShift(_Symbol, _Period, opened, false) >= InpMaxBars)
         trade.PositionClose(tk);
   }
}

bool SessionOK()
{
   if(!InpUseSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour) return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
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
void OnTick()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == lastBar) return;
   lastBar = t0;

   //--- feed every closed candle we have not processed yet
   datetime t1 = iTime(_Symbol, _Period, 1);
   if(t1 <= lastPushed) return;
   MqlRates nb[];
   int got = CopyRates(_Symbol, _Period, lastPushed + 1, t1, nb);
   if(got <= 0) return;
   int pushedNow = 0;
   for(int j = 0; j < got; j++)
   {
      if(nb[j].time <= lastPushed) continue;
      Push(nb[j].high, nb[j].low, nb[j].close);
      lastPushed = nb[j].time;
      pushedNow++;
   }
   if(pushedNow == 0 || lastPushed != t1) return;

   ManageTimeStop();
   if(sigDir == 0 || sigAtr <= 0 || sigRef <= 0) return;
   if(HasPosition()) return;
   if(!SessionOK() || !SpreadOK() || DailyLimitHit()) return;

   bool   isBuy = (sigDir == 1);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double entry = isBuy ? tick.ask : tick.bid;

   double dist     = isBuy ? sigClose - sigRef : sigRef - sigClose;
   double riskDist = MathMax(dist + InpStopBuf * sigAtr, InpMinStop * sigAtr);
   if(riskDist > InpMaxStop * sigAtr) return;                       // stop too wide, skip
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(riskDist <= minDist) return;

   double lots = CalcLots(isBuy, entry, riskDist);
   if(lots <= 0) return;

   double sl = NormalizeDouble(isBuy ? entry - riskDist : entry + riskDist, _Digits);
   double tp = NormalizeDouble(isBuy ? entry + riskDist * InpRR : entry - riskDist * InpRR, _Digits);

   double margin = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9) return;

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "MSOsc")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "MSOsc");
   if(!ok)
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
