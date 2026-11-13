"""Runs FMITracker.lua in Lua (lupa) against a tiny fake of the WoW API and prints the log it writes.
Not a replacement for the game: it checks the logic of the addon (mail invoices, vendor diffs, expenses, dedupe)."""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / 'FMITracker.lua').read_text(encoding='utf-8')

PRELUDE = r'''
WOW_PROJECT_ID = 18
NUM_BAG_SLOTS = 4
_t = 1000000
_events, _scripts, _hooks = {}, {}, {}
_money = 100000
_bags = {}          -- itemId -> count (all in bag 0)
_mail = {}          -- list of {sender, subject, money, daysLeft, invoice = {...}, link}
_timers = {}
function GetServerTime() return _t end
function GetTime() return _t end
function UnitFullName() return "Orakh", "Gorehowl" end
function UnitFactionGroup() return "Horde", "Horde" end
function UnitName() return "Orakh" end
function GetNormalizedRealmName() return "Realm" end
function UnitLevel() return 12 end
function UnitClass() return "Warrior", "WARRIOR" end
function GetMoney() return _money end
_said = {}
function print(...) local t = {} for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end _said[#_said + 1] = table.concat(t, ' ') end
AUCTION_WON_MAIL_SUBJECT = "Auction won: %s"
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
C_Timer = { After = function(sec, fn) table.insert(_timers, fn) end }
C_Item = {
  GetItemInfoInstant = function(x) if type(x) == "number" then return x end
    if x == "Copper Ore" then return 2770 end
    if type(x) == "string" and x:find("item:2589") then return 2589 end
    return nil end,
  GetItemNameByID = function(id) return ({[2770]="Copper Ore",[2589]="Linen Cloth"})[id] end,
  GetItemInfo = function(id) return "n", "l", 1, 1, 1, "c", "s", 20, "", 0, ({[2770]=10,[2589]=13})[id] or 0 end,
}
C_Container = {
  GetContainerNumSlots = function(bag) if bag == 0 then return 40 end if _bank[bag] then return 40 end return 0 end,
  GetContainerItemInfo = function(bag, slot)
    local src = bag == 0 and _bags or _bank[bag]
    local i = 0
    for id, n in pairs(src or {}) do i = i + 1; if i == slot then return { itemID = id, stackCount = n, hyperlink = _links[id] } end end
    return nil
  end,
}
function GetInboxNumItems() return #_mail, #_mail end
function GetInboxHeaderInfo(i) local m = _mail[i]; return "p", "s", m.sender, m.subject, m.money, 0, m.daysLeft end
function GetInboxText(i) if _mail[i].hide then return nil end return "", "", false, (_mail[i].invoice ~= nil) and not _mail[i].flagfalse end
function GetInboxInvoiceInfo(i)
  local v = _mail[i].invoice; if not v or _mail[i].hide then return nil end
  return v.type, v.name, v.player, v.bid, v.buyout, v.deposit, v.cut, 0, 0, 0, v.count
end
function GetInboxItemLink(i, n) return _mail[i].link end
Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5, CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, AccountBankTab_1 = 12, Keyring = -2 } }
_bank = {}          -- bagId -> {itemId -> count} while the bank is open
_links = {}
function GetInboxItem(i, j) local m = _mail[i]; if m.att and j == 1 then return "n", m.att[1], "t", m.att[2] end end
function GetRepairAllCost() return 0 end
function RepairAllItems() end
function TakeTaxiNode() end
function BuyTrainerService() end
-- any widget: unknown methods do nothing (CreateFontString gives another widget); OnEvent of the addon frame is kept
_reloads, _combat, _instance = 0, false, false
function ReloadUI() _reloads = _reloads + 1 end
function InCombatLockdown() return _combat end
function IsInInstance() return _instance, _instance and "party" or "none" end
UIParent = {}
local function widget()
  return setmetatable({}, { __index = function(t, k)
    if k == "CreateFontString" then return function() return widget() end end
    return function() end end })
end
function CreateFrame()
  local o = widget()
  o.RegisterEvent = function(self, e) _events[e] = true end
  o.SetScript = function(self, name, fn) if name == "OnEvent" then _scripts[name] = fn else rawset(self, "_" .. name, fn) end end
  return o
end
function hooksecurefunc(a, b, c)
  local t, name, fn = _G, a, b
  if type(a) == "table" then t, name, fn = a, b, c end
  _hooks[name] = fn; local orig = t[name]; t[name] = function(...) local r = orig(...); fn(...); return r end
end
SlashCmdList = {}
function fire(ev, a) _scripts.OnEvent(nil, ev, a) end
function run_timers() local t = _timers; _timers = {}; for _, fn in ipairs(t) do fn() end end
function setmoney(m) _money = m; fire("PLAYER_MONEY"); run_timers() end
'''

def boot():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    g = lua.globals()
    lua.execute('FMITrackerDB = nil')
    lua.execute(SRC.replace('local ADDON = ...', ''))
    g.fire('ADDON_LOADED', 'FMITracker')
    g.fire('PLAYER_LOGIN')
    return lua, g

def log(lua):
    return [str(x) for x in lua.eval('(function() local o = {} for i, v in ipairs(FMITrackerDB.log) do o[#o+1] = v end return o end)()').values()] if False else \
        [lua.eval('FMITrackerDB.log[%d]' % (i + 1)) for i in range(int(lua.eval('#FMITrackerDB.log')))]
