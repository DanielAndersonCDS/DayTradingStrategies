//+------------------------------------------------------------------+
//| SR_Box_EA.mq5                                                    |
//| 1H S/R box: reversal on touch, fakeout/breakout after 1H close   |
//| Run on M15 or M5. Backtest in the Strategy Tester.               |
//+------------------------------------------------------------------+
#property copyright "SR Box EA"
#property version   "1.00"
#include <Trade/Trade.mqh>

enum ENUM_ENTRY_MODE { ENTRY_EDGE = 0, ENTRY_CENTER = 1 };

input group "S/R detection (H1)"
input int             PivotLeft      = 5;       // H1 pivot bars left
input int             PivotRight     = 5;       // H1 pivot bars right
input group "Box"
input double          BoxPips        = 100.0;   // Box height (pips)
input double          PipSizeOverride= 0.0;     // Pip size (0 = auto: point x 10)
input ENUM_ENTRY_MODE EntryMode      = ENTRY_EDGE; // Reversal entry at box edge or center
input group "Risk"
input double          SLBufferPips   = 0.0;     // SL buffer (pips)
input double          RewardRisk     = 7.0;     // Reward : Risk (7 = 7:1)
input double          RiskPercent    = 5.0;     // Risk per trade (% of equity)
input group "Fakeout logic"
input bool            TradeBreakouts = true;    // Trade breakouts (stop orders)
input int             ExpireHours    = 8;       // Pending BO/FO order expiry (hours)
input bool            RetradeAfterTP = false;   // Re-trade same level after a TP
input group "General"
input ulong           MagicNumber    = 55501;

// Side 0 = resistance (sell reversal / buy breakout)
// Side 1 = support    (buy reversal / sell breakout)
// State: 0 armed, 2 pierced (waiting H1 close), 3 BO/FO order live, 4 done until new pivot
CTrade   trade;
double   g_pip, g_half, g_buf;
double   g_lvl[2];
int      g_st[2];
double   g_ext[2];
datetime g_lastBar = 0;
datetime g_lastH1  = 0;

//+------------------------------------------------------------------+
string P(int s) { return (s == 0) ? "R_" : "S_"; }
double Nrm(double p) { return NormalizeDouble(p, _Digits); }
double Top(int s) { return g_lvl[s] + g_half; }
double Bot(int s) { return g_lvl[s] - g_half; }

double EntryPrice(int s)
{
   if(s == 0) return (EntryMode == ENTRY_EDGE) ? Bot(0) : g_lvl[0];
   return (EntryMode == ENTRY_EDGE) ? Top(1) : g_lvl[1];
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(Period() >= PERIOD_H1)
   {
      Print("Attach this EA to a chart below H1 (M15 or M5).");
      return INIT_FAILED;
   }
   g_pip  = (PipSizeOverride > 0.0) ? PipSizeOverride : _Point * 10.0;
   g_half = BoxPips * g_pip / 2.0;
   g_buf  = SLBufferPips * g_pip;
   ArrayInitialize(g_lvl, 0.0);
   ArrayInitialize(g_ext, 0.0);
   g_st[0] = 0;
   g_st[1] = 0;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, "SRBOX_R");
   ObjectDelete(0, "SRBOX_S");
}

//+------------------------------------------------------------------+
//| Helpers: positions / pending orders owned by this EA             |
//+------------------------------------------------------------------+
bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         return true;
   }
   return false;
}

bool HasPending(string tag)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber &&
         OrderGetString(ORDER_COMMENT) == tag)
         return true;
   }
   return false;
}

int PendingCount()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == (long)MagicNumber)
         n++;
   }
   return n;
}

void DeletePending(string tag)   // tag "" = all of ours
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)MagicNumber) continue;
      if(tag != "" && OrderGetString(ORDER_COMMENT) != tag) continue;
      trade.OrderDelete(t);
   }
}

//+------------------------------------------------------------------+
//| Position sizing: risk % of equity at the stop distance           |
//+------------------------------------------------------------------+
double CalcLots(double entry, double sl)
{
   double dist     = MathAbs(entry - sl);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(dist <= 0.0 || tickSize <= 0.0 || tickVal <= 0.0) return 0.0;

   double risk  = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
   double lots  = risk / (dist / tickSize * tickVal);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   int d = 0;
   double st = step;
   while(st < 1.0 && d < 8) { st *= 10.0; d++; }
   return NormalizeDouble(lots, d);
}

//+------------------------------------------------------------------+
//| Pivots on H1 (confirmed after PivotRight closed bars)            |
//+------------------------------------------------------------------+
void NewLevel(int s, double price)
{
   DeletePending(P(s) + "rev");
   g_lvl[s] = price;
   g_st[s]  = 0;
   g_ext[s] = 0.0;
}

void UpdatePivots()
{
   int c = PivotRight + 1;
   if(iBars(_Symbol, PERIOD_H1) < c + PivotLeft + 2) return;

   double h = iHigh(_Symbol, PERIOD_H1, c);
   double l = iLow(_Symbol, PERIOD_H1, c);
   bool isHigh = true, isLow = true;

   for(int k = 1; k <= PivotRight; k++)
   {
      if(iHigh(_Symbol, PERIOD_H1, c - k) >= h) isHigh = false;
      if(iLow(_Symbol, PERIOD_H1, c - k)  <= l) isLow  = false;
   }
   for(int k = 1; k <= PivotLeft; k++)
   {
      if(iHigh(_Symbol, PERIOD_H1, c + k) > h) isHigh = false;
      if(iLow(_Symbol, PERIOD_H1, c + k)  < l) isLow  = false;
   }

   if(isHigh && h != g_lvl[0] && (g_st[0] == 0 || g_st[0] == 4)) NewLevel(0, h);
   if(isLow  && l != g_lvl[1] && (g_st[1] == 0 || g_st[1] == 4)) NewLevel(1, l);
}

//+------------------------------------------------------------------+
//| Pierce = price trades through the far edge of the box            |
//+------------------------------------------------------------------+
void DetectPierce(int s)
{
   if(g_lvl[s] <= 0.0) return;
   double h = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double l = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(s == 0)
   {
      if(g_st[0] == 0 && h > Top(0))
      {
         g_st[0] = 2;
         g_ext[0] = h;
         DeletePending("R_rev");
      }
      else if(g_st[0] == 2)
         g_ext[0] = MathMax(g_ext[0], h);
   }
   else
   {
      if(g_st[1] == 0 && l < Bot(1))
      {
         g_st[1] = 2;
         g_ext[1] = l;
         DeletePending("S_rev");
      }
      else if(g_st[1] == 2)
         g_ext[1] = MathMin(g_ext[1], l);
   }
}

//+------------------------------------------------------------------+
//| New H1 bar: decide BO vs no-BO from the closed 1H candle         |
//+------------------------------------------------------------------+
void EvalH1(int s)
{
   if(g_st[s] != 2) return;
   if(HasPosition()) { g_st[s] = 4; return; }

   double c1 = iClose(_Symbol, PERIOD_H1, 1);
   double hi = iHigh(_Symbol, PERIOD_H1, 1);
   double lo = iLow(_Symbol, PERIOD_H1, 1);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   datetime exp = TimeCurrent() + (datetime)(ExpireHours * 3600);
   bool ok = false;

   if(s == 0)
   {
      if(c1 > Top(0) && TradeBreakouts)
      {
         // BREAKOUT -> buy stop
         double px = MathMax(hi, ask + stopLvl) + _Point;
         double sl = g_lvl[0] - g_buf;
         double tp = px + RewardRisk * (px - sl);
         double lots = CalcLots(px, sl);
         if(lots > 0.0)
            ok = trade.BuyStop(lots, Nrm(px), _Symbol, Nrm(sl), Nrm(tp),
                               ORDER_TIME_SPECIFIED, exp, "R_bo");
      }
      else if(c1 <= Top(0))
      {
         // NO BREAKOUT -> sell limit at resistance (market if already inside box)
         double e  = EntryPrice(0);
         double sl = MathMax(g_ext[0], Top(0)) + g_buf;
         if(bid < e - stopLvl)
         {
            double tp = e - RewardRisk * (sl - e);
            double lots = CalcLots(e, sl);
            if(lots > 0.0)
               ok = trade.SellLimit(lots, Nrm(e), _Symbol, Nrm(sl), Nrm(tp),
                                    ORDER_TIME_SPECIFIED, exp, "R_fo");
         }
         else if(sl - bid > stopLvl)
         {
            double tp = bid - RewardRisk * (sl - bid);
            double lots = CalcLots(bid, sl);
            if(lots > 0.0)
               ok = trade.Sell(lots, _Symbol, 0.0, Nrm(sl), Nrm(tp), "R_fo");
         }
      }
   }
   else
   {
      if(c1 < Bot(1) && TradeBreakouts)
      {
         // BREAKOUT -> sell stop
         double px = MathMin(lo, bid - stopLvl) - _Point;
         double sl = g_lvl[1] + g_buf;
         double tp = px - RewardRisk * (sl - px);
         double lots = CalcLots(px, sl);
         if(lots > 0.0)
            ok = trade.SellStop(lots, Nrm(px), _Symbol, Nrm(sl), Nrm(tp),
                                ORDER_TIME_SPECIFIED, exp, "S_bo");
      }
      else if(c1 >= Bot(1))
      {
         // NO BREAKOUT -> buy limit at support (market if already inside box)
         double e  = EntryPrice(1);
         double sl = MathMin(g_ext[1], Bot(1)) - g_buf;
         if(ask > e + stopLvl)
         {
            double tp = e + RewardRisk * (e - sl);
            double lots = CalcLots(e, sl);
            if(lots > 0.0)
               ok = trade.BuyLimit(lots, Nrm(e), _Symbol, Nrm(sl), Nrm(tp),
                                   ORDER_TIME_SPECIFIED, exp, "S_fo");
         }
         else if(ask - sl > stopLvl)
         {
            double tp = ask + RewardRisk * (ask - sl);
            double lots = CalcLots(ask, sl);
            if(lots > 0.0)
               ok = trade.Buy(lots, _Symbol, 0.0, Nrm(sl), Nrm(tp), "S_fo");
         }
      }
   }
   g_st[s] = ok ? 3 : 4;
}

//+------------------------------------------------------------------+
//| Reversal order: touch of the box -> trade at S/R                 |
//+------------------------------------------------------------------+
void PlaceReversal(int s)
{
   if(g_st[s] != 0 || g_lvl[s] <= 0.0) return;
   if(HasPosition() || HasPending(P(s) + "rev")) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double e = EntryPrice(s);

   if(s == 0)
   {
      if(e - bid <= stopLvl) return;          // price already at/inside the box
      double sl = Top(0) + g_buf;
      double tp = e - RewardRisk * (sl - e);
      double lots = CalcLots(e, sl);
      if(lots > 0.0)
         trade.SellLimit(lots, Nrm(e), _Symbol, Nrm(sl), Nrm(tp), ORDER_TIME_GTC, 0, "R_rev");
   }
   else
   {
      if(ask - e <= stopLvl) return;
      double sl = Bot(1) - g_buf;
      double tp = e + RewardRisk * (e - sl);
      double lots = CalcLots(e, sl);
      if(lots > 0.0)
         trade.BuyLimit(lots, Nrm(e), _Symbol, Nrm(sl), Nrm(tp), ORDER_TIME_GTC, 0, "S_rev");
   }
}

void CleanupState3(int s)
{
   if(g_st[s] == 3 && !HasPosition() &&
      !HasPending(P(s) + "bo") && !HasPending(P(s) + "fo"))
      g_st[s] = 4;
}

//+------------------------------------------------------------------+
void DrawZones()
{
   datetime t1 = TimeCurrent() - 3 * 86400;
   datetime t2 = TimeCurrent() + 86400;
   for(int s = 0; s < 2; s++)
   {
      string name = (s == 0) ? "SRBOX_R" : "SRBOX_S";
      if(g_lvl[s] <= 0.0) continue;
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, Top(s), t2, Bot(s));
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, Top(s));
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, Bot(s));
      ObjectSetInteger(0, name, OBJPROP_COLOR, (s == 0) ? clrFireBrick : clrSeaGreen);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // one position at a time: once something is open, drop all pending orders
   if(HasPosition() && PendingCount() > 0) DeletePending("");

   datetime bt = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bt == g_lastBar) return;
   g_lastBar = bt;

   datetime h1 = iTime(_Symbol, PERIOD_H1, 0);
   bool newH1 = false;
   if(g_lastH1 == 0) g_lastH1 = h1;
   else if(h1 != g_lastH1) { newH1 = true; g_lastH1 = h1; }

   for(int s = 0; s < 2; s++)
   {
      DetectPierce(s);
      if(newH1) EvalH1(s);
   }
   if(newH1) UpdatePivots();
   for(int s = 0; s < 2; s++)
   {
      PlaceReversal(s);
      CleanupState3(s);
   }
   DrawZones();
}

//+------------------------------------------------------------------+
//| Update level state when one of our trades closes                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;

   long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
   ulong  pid    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

   string cm = "";
   if(HistorySelectByPosition(pid))
   {
      for(int i = 0; i < HistoryDealsTotal(); i++)
      {
         ulong d = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            cm = HistoryDealGetString(d, DEAL_COMMENT);
            break;
         }
      }
   }
   if(StringLen(cm) < 2) return;

   int s = (StringGetCharacter(cm, 0) == 'R') ? 0 : 1;
   bool isRev = (StringFind(cm, "_rev") >= 0);

   if(isRev)
   {
      if(reason == DEAL_REASON_TP && !RetradeAfterTP && g_st[s] == 0)
         g_st[s] = 4;
   }
   else
      g_st[s] = 4;
}
//+------------------------------------------------------------------+