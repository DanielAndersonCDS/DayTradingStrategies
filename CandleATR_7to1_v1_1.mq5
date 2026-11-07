//+------------------------------------------------------------------+
//|  CandleATR_7to1_v1_1.mq5                                         |
//|  Candlestick patterns + ATR stops + fixed reward:risk            |
//|  v1.1: logs every skip reason, startup permission check,         |
//|        retries entry on later ticks if spread is wide at bar     |
//|        open, optional forced test trade to verify order plumbing |
//+------------------------------------------------------------------+
#property copyright "Personal use"
#property version   "1.10"

#include <Trade\Trade.mqh>

enum ENUM_PATTERN { PAT_ALL = 0, PAT_ENGULF = 1, PAT_PIN = 2, PAT_STAR = 3 };
enum ENUM_TREND   { TREND_OFF = 0, TREND_WITH = 1, TREND_AGAINST = 2 };

input group "Patterns"
input ENUM_PATTERN InpPattern   = PAT_ALL;     // Pattern
input double       InpMinCandle = 0.8;         // Min signal-candle range (ATR x)
input double       InpPinWick   = 0.6;         // Pin bar: min wick fraction of range
input double       InpPinBody   = 0.3;         // Pin bar: max body fraction of range
input ENUM_TREND   InpTrend     = TREND_OFF;   // Trend filter
input int          InpEmaLen    = 100;         // Trend EMA length

input group "Risk"
input int          InpAtrLen    = 14;          // ATR length
input double       InpRR        = 7.0;         // Reward : Risk
input double       InpRiskPct   = 1.0;         // Risk per trade, % of equity
input double       InpStopBuf   = 0.1;         // Stop buffer beyond pattern (ATR x)
input double       InpMinStop   = 1.0;         // Min stop distance (ATR x)
input double       InpMaxStop   = 4.0;         // Max stop distance (ATR x), skip if wider
input int          InpMaxBars   = 0;           // Time stop in bars (0 = off)
input double       InpDailyLoss = 3.0;         // Stop trading for the day after this % loss (0 = off)

input group "Filters (broker SERVER time)"
input bool         InpUseSession = false;      // Use session filter
input int          InpStartHour  = 10;         // Session start hour (server time)
input int          InpEndHour    = 19;         // Session end hour (server time)
input int          InpMaxSpread  = 0;          // Max spread in points (0 = off). Check your symbol first!

input group "Execution"
input long         InpMagic     = 770077;      // Magic number
input int          InpSlippage  = 30;          // Max slippage (points)

input group "Debug"
input bool         InpDebug     = true;        // Log every skip reason in the Experts tab
input bool         InpForceTest = false;       // Place ONE test buy on the next new bar (verifies orders work). Turn off after.

CTrade   trade;
int      hATR = INVALID_HANDLE;
int      hEMA = INVALID_HANDLE;
datetime lastBar = 0;

// signal waiting for entry (retried on ticks within the same bar)
int      pendSig = 0;
double   pendRiskDist = 0;
bool     spreadLogged = false;
bool     testDone = false;

void Dbg(const string s) { if(InpDebug) Print(s); }

//+------------------------------------------------------------------+
int OnInit()
{
   hATR = iATR(_Symbol, _Period, InpAtrLen);
   hEMA = iMA(_Symbol, _Period, InpEmaLen, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hEMA == INVALID_HANDLE)
   {
      Print("Indicator handle error");
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   lastBar = iTime(_Symbol, _Period, 0);   // wait for the NEXT new bar before trading

   // ---- startup diagnostics: the usual reasons "nothing trades" ----
   PrintFormat("[CandleATR] %s %s | Terminal AutoTrading: %s | EA allowed: %s | Account trade allowed: %s | EA allowed on account: %s",
      _Symbol, EnumToString(_Period),
      TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "ON" : "OFF  <-- press the AutoTrading button",
      MQLInfoInteger(MQL_TRADE_ALLOWED) ? "yes" : "NO  <-- tick 'Allow Algo Trading' in the EA's Common tab",
      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) ? "yes" : "NO",
      AccountInfoInteger(ACCOUNT_TRADE_EXPERT) ? "yes" : "NO");
   PrintFormat("[CandleATR] Symbol trade mode: %d (4 = full) | spread now: %d pts | stops level: %d pts | min lot: %.2f | step: %.2f",
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
      SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
}

//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
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
      int held = iBarShift(_Symbol, _Period, opened, false);
      if(held >= InpMaxBars)
         trade.PositionClose(tk);
   }
}

bool SessionOK()
{
   if(!InpUseSession) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
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
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT) +
             HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP);
   }
   double limit = AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyLoss / 100.0;
   return (pnl <= -limit);
}

//+------------------------------------------------------------------+
int Detect(const MqlRates &c0, const MqlRates &c1, const MqlRates &c2,
           double atr, double ema, double &patLow, double &patHigh)
{
   double body  = MathAbs(c0.close - c0.open);
   double rng   = c0.high - c0.low;
   double bodyP = MathAbs(c1.close - c1.open);
   double body2 = MathAbs(c2.close - c2.open);

   bool bullEng = c1.close < c1.open && c0.close > c0.open && c0.close >= c1.open && c0.open <= c1.close && body > bodyP;
   bool bearEng = c1.close > c1.open && c0.close < c0.open && c0.close <= c1.open && c0.open >= c1.close && body > bodyP;

   double lowW = MathMin(c0.open, c0.close) - c0.low;
   double upW  = c0.high - MathMax(c0.open, c0.close);
   bool bullPin = rng > 0 && lowW >= InpPinWick * rng && body <= InpPinBody * rng;
   bool bearPin = rng > 0 && upW  >= InpPinWick * rng && body <= InpPinBody * rng;

   bool bullStar = c2.close < c2.open && body2 >= 0.6 * atr && bodyP <= 0.5 * body2 &&
                   c0.close > c0.open && c0.close > (c2.open + c2.close) / 2.0;
   bool bearStar = c2.close > c2.open && body2 >= 0.6 * atr && bodyP <= 0.5 * body2 &&
                   c0.close < c0.open && c0.close < (c2.open + c2.close) / 2.0;

   bool useEng  = (InpPattern == PAT_ALL || InpPattern == PAT_ENGULF);
   bool usePin  = (InpPattern == PAT_ALL || InpPattern == PAT_PIN);
   bool useStar = (InpPattern == PAT_ALL || InpPattern == PAT_STAR);

   bool bigEnough = (rng >= InpMinCandle * atr);

   bool trendLongOK  = (InpTrend == TREND_OFF) ||
                       (InpTrend == TREND_WITH ? c0.close > ema : c0.close < ema);
   bool trendShortOK = (InpTrend == TREND_OFF) ||
                       (InpTrend == TREND_WITH ? c0.close < ema : c0.close > ema);

   bool rawPattern = (useEng && (bullEng || bearEng)) || (usePin && (bullPin || bearPin)) || (useStar && (bullStar || bearStar));
   if(rawPattern && !bigEnough)
      Dbg(StringFormat("Pattern found but candle too small: range %.5f < %.2f x ATR (%.5f)", rng, InpMinCandle, atr));

   bool longSig  = bigEnough && trendLongOK  && ((useEng && bullEng) || (usePin && bullPin) || (useStar && bullStar));
   bool shortSig = bigEnough && trendShortOK && ((useEng && bearEng) || (usePin && bearPin) || (useStar && bearStar));

   patLow  = c0.low;
   patHigh = c0.high;
   if(useEng && (bullEng || bearEng))
   {
      patLow  = MathMin(c0.low,  c1.low);
      patHigh = MathMax(c0.high, c1.high);
   }
   if(useStar && (bullStar || bearStar))
   {
      patLow  = MathMin(c0.low,  MathMin(c1.low,  c2.low));
      patHigh = MathMax(c0.high, MathMax(c1.high, c2.high));
   }

   if(longSig == shortSig) return 0;
   return longSig ? 1 : -1;
}

//+------------------------------------------------------------------+
double CalcLots(bool isBuy, double entry, double riskDist)
{
   double riskCash = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double sl = isBuy ? entry - riskDist : entry + riskDist;
   double profit = 0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, profit))
   {
      Print("Skipped: OrderCalcProfit failed, error ", GetLastError());
      return 0;
   }
   double lossPerLot = MathAbs(profit);
   if(lossPerLot <= 0) return 0;

   double lots = riskCash / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < vmin)
   {
      PrintFormat("Skipped: %.1f%% risk needs %.4f lots, below the minimum %.2f", InpRiskPct, lots, vmin);
      return 0;
   }
   lots = MathMin(lots, vmax);
   int dig = (int)MathMax(0.0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, dig);
}

//+------------------------------------------------------------------+
// Runs once per new bar: decides whether there is a signal.
void Evaluate()
{
   if(!SessionOK())     { Dbg("Skip: outside session hours (server time)"); return; }
   if(DailyLimitHit())  { Print("Skip: daily loss limit hit"); return; }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, _Period, 0, 5, r) < 5) { Dbg("Skip: not enough bars"); return; }

   double atrBuf[], emaBuf[];
   ArraySetAsSeries(atrBuf, true);
   ArraySetAsSeries(emaBuf, true);
   if(CopyBuffer(hATR, 0, 1, 1, atrBuf) < 1 || CopyBuffer(hEMA, 0, 1, 1, emaBuf) < 1)
   { Dbg("Skip: indicator data not ready"); return; }
   double atr = atrBuf[0];
   double ema = emaBuf[0];
   if(atr <= 0) return;

   int sig;
   double patLow, patHigh;
   if(InpForceTest && !testDone)
   {
      sig = 1; patLow = r[1].low; patHigh = r[1].high;
      Print("FORCE TEST: ignoring patterns, placing one buy");
   }
   else
      sig = Detect(r[1], r[2], r[3], atr, ema, patLow, patHigh);

   if(sig == 0) { Dbg("No signal on last closed candle"); return; }

   bool isBuy = (sig == 1);
   double dist     = isBuy ? r[1].close - patLow : patHigh - r[1].close;
   double riskDist = MathMax(dist + InpStopBuf * atr, InpMinStop * atr);
   if(InpForceTest && !testDone) riskDist = InpMinStop * atr;
   if(riskDist > InpMaxStop * atr)
   { Dbg(StringFormat("Skip: stop too wide (%.5f > %.1f x ATR)", riskDist, InpMaxStop)); return; }

   pendSig = sig;
   pendRiskDist = riskDist;
   spreadLogged = false;
   Dbg(StringFormat("SIGNAL %s, stop distance %.5f - waiting for entry", isBuy ? "BUY" : "SELL", riskDist));
}

//+------------------------------------------------------------------+
// Runs on ticks while a signal is pending. Retries if spread is wide.
void TryEnter()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("Skip: trading not allowed (AutoTrading button / EA 'Allow Algo Trading')");
      pendSig = 0;
      return;
   }
   if(!SpreadOK())
   {
      if(!spreadLogged)
      {
         Dbg(StringFormat("Entry waiting: spread %d pts > max %d", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpread));
         spreadLogged = true;
      }
      return;                       // keep pending, try again next tick
   }

   bool isBuy = (pendSig == 1);
   double riskDist = pendRiskDist;
   pendSig = 0;                     // one attempt only from here

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double entry = isBuy ? tick.ask : tick.bid;

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(riskDist <= minDist) { Dbg("Skip: stop inside broker stops level"); return; }

   double lots = CalcLots(isBuy, entry, riskDist);
   if(lots <= 0) return;

   double sl = NormalizeDouble(isBuy ? entry - riskDist : entry + riskDist, _Digits);
   double tp = NormalizeDouble(isBuy ? entry + riskDist * InpRR : entry - riskDist * InpRR, _Digits);

   double margin = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, entry, margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
      { Print("Skip: not enough free margin"); return; }

   bool ok = isBuy ? trade.Buy(lots, _Symbol, 0.0, sl, tp, "CandleATR")
                   : trade.Sell(lots, _Symbol, 0.0, sl, tp, "CandleATR");
   if(ok)
   {
      PrintFormat("ORDER SENT: %s %.2f lots, SL %.5f, TP %.5f, retcode %d", isBuy ? "BUY" : "SELL", lots, sl, tp, trade.ResultRetcode());
      if(InpForceTest) testDone = true;
   }
   else
      PrintFormat("Order failed: %d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 != lastBar)
   {
      lastBar = t0;
      pendSig = 0;
      ManageTimeStop();
      if(HasPosition()) return;
      Evaluate();
   }
   if(pendSig != 0) TryEnter();
}
//+------------------------------------------------------------------+
