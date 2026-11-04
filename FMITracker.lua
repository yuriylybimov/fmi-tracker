-- FMI Tracker 0.1.0
-- Records, per character, what only the game knows and no scan can show:
--   as  auction sale      (mail invoice "seller"): gross price, AH cut, deposit
--   ab  auction purchase  (mail invoice "buyer"): price paid
--   vs  vendor sale, vb vendor purchase (bag change while a merchant is open)
--   rp  repair, tx flight, tr trainer (money spent right after the action)
-- and, per character, what it holds: FMITrackerDB.chars[name] = {bags, bank, mail = {[itemId] = count}, money, ...};
-- the account (warband) bank is FMITrackerDB.account. A key "v<itemId>" is a VARIANT (bonus ids, enchant, gems, suffix):
-- never priced like the plain item.
-- It never buys, sells, posts, cancels, opens or takes mail, and it does not scan the auction house.
-- Output: FMITrackerDB.log, one string per entry: "ts|kind|itemId|name|qty|a|b|c|character"
--   as: a = price (copper, all units), b = AH cut, c = deposit returned
--   ab: a = price paid (all units)
--   vs: a = copper received (all units)   vb: a = copper paid (all units)
--   rp / tx / tr: a = copper paid
-- The file is written by the game on /reload or logout. Money is in copper, time is server time (UTC epoch).

local VERSION = "0.1.0"
FMITrackerDB = FMITrackerDB or {}
local DB
local MAX_LOG = 20000          -- about 1.5 MB of saved variables at most; the oldest entries go first
local SEEN_DAYS = 45
local char = "?"
local f = CreateFrame("Frame")

local function now() return (GetServerTime and GetServerTime()) or time() end

local function charKey()
  local name, realm = UnitFullName("player")
  name = name or UnitName("player") or "?"
  if WOW_PROJECT_ID == 18 then                       -- Forever: the second value is the surname
    return (realm and realm ~= "") and (name .. " " .. realm) or name
  end
  return name .. "-" .. (GetNormalizedRealmName() or realm or "")
end

local function clean(s)
  s = tostring(s or "")
  s = s:gsub("[|\r\n]", " ")
  return s
end

local function trim()
  local log = DB.log
  if #log <= MAX_LOG then return end
  local keep, from = {}, #log - MAX_LOG + 1000
  for i = from, #log do keep[#keep + 1] = log[i] end
  DB.log = keep
end

local function Log(kind, itemId, name, qty, a, b, c)
  local log = DB.log
  log[#log + 1] = table.concat({
    now(), kind, itemId or 0, clean(name), qty or 0, math.floor(a or 0), math.floor(b or 0), math.floor(c or 0), char }, "|")
  if #log > MAX_LOG + 1000 then trim() end
end

local function itemName(id)
  local fn = C_Item and C_Item.GetItemNameByID
  if fn then local ok, n = pcall(fn, id); if ok and n then return n end end
  if GetItemInfo then local ok, n = pcall(GetItemInfo, id); if ok and n then return n end end
  return ""
end

local function itemIdOf(x)
  if not x then return nil end
  local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not fn then return nil end
  local ok, id = pcall(fn, x)
  if ok and type(id) == "number" then return id end
  return nil
end

-- ---------------------------------------------------------------- what the character holds
local function bagGroups()
  local out = { bags = {}, bank = {}, account = {} }
  local E = Enum and Enum.BagIndex
  if E then
    for name, id in pairs(E) do
      if type(id) == "number" then
        if name:find("^AccountBankTab") then out.account[#out.account + 1] = id
        elseif name:find("^CharacterBankTab") or name == "Bank" or name == "Reagentbank" or name:find("^BankBag") then out.bank[#out.bank + 1] = id
        elseif name == "Backpack" or name:find("^Bag_") or name == "ReagentBag" then out.bags[#out.bags + 1] = id end
      end
    end
  end
  local nb = NUM_BAG_SLOTS or 4
  if #out.bags == 0 then for id = 0, nb + 1 do out.bags[#out.bags + 1] = id end end
  if #out.bank == 0 then
    out.bank = { -1, -3 }
    for id = nb + 2, nb + 1 + (NUM_BANKBAGSLOTS or 7) do out.bank[#out.bank + 1] = id end
  end
  return out
end

local function isVariant(link)
  if not link then return false end
  local body = link:match("item:([^|]*)")
  if not body then return false end
  local f = {}
  for part in (body .. ":"):gmatch("([^:]*):") do f[#f + 1] = part end
  for i = 2, 7 do local v = tonumber(f[i]); if v and v ~= 0 then return true end end
  return (tonumber(f[13]) or 0) > 0
end

local function addTo(into, id, n, link)
  local key = isVariant(link) and ("v" .. id) or id
  into[key] = (into[key] or 0) + n
end

local function countBags(ids)
  local out, C = {}, C_Container
  if not C then return out end
  for _, bag in ipairs(ids) do
    local slots = C.GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local info = C.GetContainerItemInfo(bag, slot)
      if info and info.itemID then addTo(out, info.itemID, info.stackCount or 1, info.hyperlink) end
    end
  end
  return out
end

local bankOpen, bagTimer = false, false

local function ScanHoldings()
  local me = DB.chars[char]
  if not me then return end
  local g = bagGroups()
  local bags, money = countBags(g.bags), GetMoney() or 0
  -- During logout and reload the client answers with empty bags and 0 money: keep the last real reading instead.
  if not next(bags) and money == 0 and me.bagsAt then return end
  me.bags, me.bagsAt = bags, now()
  me.money, me.level = money, UnitLevel("player")
  if bankOpen then
    local bank = countBags(g.bank)
    if next(bank) or not me.bank then me.bank, me.bankAt = bank, now() end
    local account = countBags(g.account)
    if next(account) then DB.account, DB.accountAt = account, now() end
  end
end

local function ScanMailItems()
  local me = DB.chars[char]
  if not me or not GetInboxNumItems or not GetInboxItem then return end
  local out, num = {}, GetInboxNumItems() or 0
  for i = 1, num do
    for j = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
      local ok, _, id, _, count = pcall(GetInboxItem, i, j)
      if ok and id then
        local link = GetInboxItemLink and GetInboxItemLink(i, j)
        addTo(out, id, count or 1, link)
      end
    end
  end
  me.mail, me.mailAt = out, now()
end

local function ScheduleHoldings()
  if bagTimer then return end
  bagTimer = true
  local function run() bagTimer = false; if DB then ScanHoldings() end end
  if C_Timer and C_Timer.After then C_Timer.After(1, run) else run() end
end

-- ---------------------------------------------------------------- auction mail invoices
local lastPlain = false
local stats = { mails = 0, invoices = 0 }   -- this session, shown by /fmit

local function invoiceFor(i)
  lastPlain = false
  -- An invoice is available after the mail text has been read; reading it marks the mail as read, nothing else.
  local getText = GetInboxText
  if getText then
    local ok, _, _, _, isInvoice = pcall(getText, i)
    if ok and isInvoice == false then lastPlain = true; return nil end
  end
  local get = GetInboxInvoiceInfo or (C_Mail and C_Mail.GetInboxInvoiceInfo)
  if not get then return nil end
  local ok, invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count = pcall(get, i)
  if not ok or not invoiceType then return nil end
  return invoiceType, itemName, playerName, bid, buyout, deposit, consignment, count
end

local scanned = {}          -- mails already looked at in this session (reading a mail marks it as read: do it once)

local function ScanMail()
  if not GetInboxNumItems then return end
  local num = GetInboxNumItems() or 0
  local t = now()
  for i = 1, num do
    local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
    local minute = math.floor((t + (daysLeft or 0) * 86400) / 60)
    local sig = table.concat({ tostring(sender), tostring(subject), tostring(money), minute }, ":")
    local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, count
    if not scanned[sig] then
      invoiceType, itemName, playerName, bid, buyout, deposit, consignment, count = invoiceFor(i)
      -- a mail whose answer was empty for any other reason (data not loaded yet) is looked at again
      if invoiceType or lastPlain then scanned[sig] = true end
      stats.mails = stats.mails + 1
      if invoiceType then stats.invoices = stats.invoices + 1 end
    end
    if invoiceType and itemName then
      local price = (bid and bid > 0) and bid or (buyout or 0)
      local base = table.concat({ invoiceType, itemName, playerName or "", price, deposit or 0, consignment or 0, count or 0 }, ":")
      local key = base .. ":" .. minute
      -- the expiry estimate moves by a second or two between looks: a neighbouring minute is the same mail
      if not (DB.seen[key] or DB.seen[base .. ":" .. (minute - 1)] or DB.seen[base .. ":" .. (minute + 1)]) then
        DB.seen[key] = t
        local id = itemIdOf(GetInboxItemLink and GetInboxItemLink(i, 1)) or itemIdOf(itemName)
        if invoiceType == "seller" then
          Log("as", id, itemName, count or 0, price, consignment or 0, deposit or 0)
        elseif invoiceType == "buyer" then
          Log("ab", id, itemName, count or 0, price, 0, 0)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- vendors
local merchant = nil          -- {bags = {itemId = count}, at = time}

local function bagCounts()
  local counts = {}
  local C = C_Container
  if not C then return counts end
  local last = (NUM_BAG_SLOTS or 4) + 1                  -- the reagent bag slot where there is one
  for bag = 0, last do
    local slots = C.GetContainerNumSlots(bag) or 0
    for slot = 1, slots do
      local info = C.GetContainerItemInfo(bag, slot)
      if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

local function sellPriceOf(id)
  local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not fn then return 0 end
  local ok, a, b, c, d, e, f2, g, h, i2, j, price = pcall(fn, id)
  if ok and type(price) == "number" then return price end
  return 0
end

local pendingMoney = nil      -- {kind, money, until}
local lastMoney = nil

local function CheckMerchant()
  if not merchant then return end
  local counts = bagCounts()
  local sold, bought, nSold, nBought = {}, {}, 0, 0
  for id, c in pairs(merchant.bags) do
    local n = counts[id] or 0
    if n < c then sold[id] = c - n; nSold = nSold + 1 end
  end
  for id, n in pairs(counts) do
    local c = merchant.bags[id] or 0
    if n > c then bought[id] = n - c; nBought = nBought + 1 end
  end
  local money = GetMoney()
  local dm = money - (merchant.money or money)
  if nSold > 0 and nBought == 0 and dm > 0 then
    local weight, total = {}, 0
    for id, q in pairs(sold) do weight[id] = math.max(sellPriceOf(id), 1) * q; total = total + weight[id] end
    for id, q in pairs(sold) do
      Log("vs", id, itemName(id), q, dm * weight[id] / total, 0, 0)
    end
  elseif nBought > 0 and nSold == 0 and dm < 0 then
    local total = 0
    for id, q in pairs(bought) do total = total + q end
    for id, q in pairs(bought) do
      Log("vb", id, itemName(id), q, (-dm) * q / total, 0, 0)
    end
  end
  if nSold > 0 or nBought > 0 then
    merchant.bags, merchant.money = counts, money
  end
end

-- ---------------------------------------------------------------- repairs, flights, trainers: the money spent right after
local function Expect(kind)
  pendingMoney = { kind = kind, money = GetMoney(), expires = GetTime() + 3 }
end

local function OnMoney()
  local m = GetMoney()
  if pendingMoney then
    if GetTime() > pendingMoney.expires then
      pendingMoney = nil
    elseif m < pendingMoney.money then
      Log(pendingMoney.kind, 0, "", 1, pendingMoney.money - m, 0, 0)
      pendingMoney = nil
    end
  end
  if merchant then
    merchant.money = merchant.money or m
    if C_Timer and C_Timer.After then C_Timer.After(0.6, CheckMerchant) end
  end
  lastMoney = m
end

local function hook(name, kind)
  local fn = _G[name]
  if type(fn) == "function" then hooksecurefunc(name, function() Expect(kind) end) return true end
  return false
end

-- ---------------------------------------------------------------- events
local warned = false
local function safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not warned then
    warned = true
    print("|cffff8844FMI Tracker|r: " .. tostring(err) .. " (shown once)")
  end
end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MAIL_SHOW")
f:RegisterEvent("MAIL_INBOX_UPDATE")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("BANKFRAME_OPENED")
f:RegisterEvent("BANKFRAME_CLOSED")

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= "FMITracker" then return end
    FMITrackerDB = FMITrackerDB or {}
    DB = FMITrackerDB
    DB.version, DB.log, DB.seen, DB.chars = VERSION, DB.log or {}, DB.seen or {}, DB.chars or {}
    local t = now()
    for k, v in pairs(DB.seen) do if t - v > SEEN_DAYS * 86400 then DB.seen[k] = nil end end
  elseif not DB then
    return
  elseif event == "PLAYER_LOGIN" then
    char = charKey()
    local level = UnitLevel("player")
    DB.chars[char] = { level = level, class = select(2, UnitClass("player")), seen = now(), forever = WOW_PROJECT_ID == 18 or nil }
    hook("RepairAllItems", "rp")
    hook("TakeTaxiNode", "tx")
    hook("BuyTrainerService", "tr")
    if C_Trainer and C_Trainer.BuyProvidedService then hooksecurefunc(C_Trainer, "BuyProvidedService", function() Expect("tr") end) end
  elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
    safe(ScanMail)
    safe(ScanMailItems)
  elseif event == "PLAYER_ENTERING_WORLD" then
    safe(ScheduleHoldings)
  elseif event == "PLAYER_LOGOUT" then
    bagTimer = false
    safe(ScanHoldings)
  elseif event == "BANKFRAME_OPENED" then
    bankOpen = true
    safe(ScheduleHoldings)
  elseif event == "BANKFRAME_CLOSED" then
    safe(ScanHoldings)
    bankOpen = false
  elseif event == "MERCHANT_SHOW" then
    merchant = { bags = bagCounts(), money = GetMoney() }
  elseif event == "MERCHANT_CLOSED" then
    safe(CheckMerchant)
    merchant = nil
  elseif event == "BAG_UPDATE_DELAYED" then
    if merchant then safe(CheckMerchant) end
    safe(ScheduleHoldings)
  elseif event == "PLAYER_MONEY" then
    safe(OnMoney)
  end
end)

SLASH_FMITRACKER1 = "/fmit"
SlashCmdList["FMITRACKER"] = function(msg)
  if not DB then return end
  local n = #DB.log
  print("|cff66ccffFMI Tracker " .. VERSION .. "|r: " .. n .. " entries (written to the file on /reload or logout). Mails looked at: " .. stats.mails .. ", auction invoices found: " .. stats.invoices .. ".")
  for i = math.max(1, n - 4), n do print("  " .. DB.log[i]) end
end
