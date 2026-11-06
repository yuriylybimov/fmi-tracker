-- FMI Tracker 0.2.0
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

local VERSION = "0.2.0"
local unpack = unpack or table.unpack
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

local function Dbg(msg)
  -- a short rolling diagnostic trail, kept in the saved file so a missing entry can be explained afterwards
  if not DB then return end
  local d = DB.dbg or {}
  DB.dbg = d
  d[#d + 1] = now() .. "|" .. tostring(msg)
  while #d > 80 do table.remove(d, 1) end
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
  -- returns the items and the number of slots the client answered for (0 slots = the client gave no reading)
  local out, C, total = {}, C_Container, 0
  if not C then return out, 0 end
  for _, bag in ipairs(ids) do
    local slots = C.GetContainerNumSlots(bag) or 0
    total = total + slots
    for slot = 1, slots do
      local info = C.GetContainerItemInfo(bag, slot)
      if info and info.itemID then addTo(out, info.itemID, info.stackCount or 1, info.hyperlink) end
    end
  end
  return out, total
end

-- The bank of the modern client (WoW Forever, Retail): tabs the player bought, asked from the game as BagBrother does
-- (C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character / .Account), each tab is a container with its own bag id).
-- Older clients: the fixed bank containers from bagGroups().
local function bankBagIds()
  local out = { char = {}, account = {} }
  local CB, BT = C_Bank, Enum and Enum.BankType
  if CB and CB.FetchPurchasedBankTabData and BT then
    for key, kind in pairs({ char = BT.Character, account = BT.Account }) do
      if kind ~= nil then
        local ok, tabs = pcall(CB.FetchPurchasedBankTabData, kind)
        if ok and type(tabs) == "table" then
          for _, tab in pairs(tabs) do
            if type(tab) == "table" and tab.ID then out[key][#out[key] + 1] = tab.ID end
          end
        end
      end
    end
  end
  if #out.char == 0 then
    local g = bagGroups()
    out.char = g.bank
    if #out.account == 0 then out.account = g.account end
  end
  return out
end

local bankOpen, bagTimer = false, false

-- Professions: skill line ids from GetProfessions (the same ids on every client language). Where that call does not exist,
-- the English skill names from the skill list are kept as a fallback. An empty answer never replaces a known list (logout).
local function packed(...) return select("#", ...), { ... } end
local function ScanProfessions()
  local me = DB.chars[char]
  if not me then return end
  local found, names = {}, {}
  if GetProfessions and GetProfessionInfo then
    local n, list = packed(GetProfessions())
    for i = 1, n do
      local idx = list[i]
      if idx then
        local _, _, level, _, _, _, line = GetProfessionInfo(idx)
        if line then found[line] = level or 0 end
      end
    end
  end
  if not next(found) and GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, header, _, level = GetSkillLineInfo(i)
      if name and not header then names[name] = level or 0 end
    end
  end
  if next(found) or next(names) or not me.prof then
    me.prof, me.profNames, me.profAt = found, names, now()
  end
end


-- Read only while the bank window is open: the client answers for the bank then and not after it closes.
-- A reading with no slots at all is "no answer" and never replaces what is known; an empty bank with slots is real.
local function ScanBank()
  local me = DB.chars[char]
  if not me or not bankOpen then return end
  local ids = bankBagIds()
  local bank, slots = countBags(ids.char)
  if slots > 0 then me.bank, me.bankAt = bank, now() end
  local account, aslots = countBags(ids.account)
  if aslots > 0 then DB.account, DB.accountAt = account, now() end
end

local function ScanHoldings()
  local me = DB.chars[char]
  if not me then return end
  pcall(ScanProfessions)
  local g = bagGroups()
  local bags, money = countBags(g.bags), GetMoney() or 0
  -- During logout and reload the client answers with empty bags and 0 money: keep the last real reading instead.
  if not next(bags) and money == 0 and me.bagsAt then return end
  me.bags, me.bagsAt = bags, now()
  me.money, me.level = money, UnitLevel("player")
  if bankOpen then ScanBank() end
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
local stats = { mails = 0, invoices = 0 }   -- this session, shown by /fmit

local function invoiceFor(i)
  -- Reading the mail text loads the invoice (and marks the mail as read, nothing else). The "is an invoice" flag of the text is not
  -- trusted: on the Retail client an "Auction won" mail reports false and still has its invoice.
  if GetInboxText then pcall(GetInboxText, i) end
  local get = GetInboxInvoiceInfo or (C_Mail and C_Mail.GetInboxInvoiceInfo)
  if not get then return nil end
  local ok, invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count = pcall(get, i)
  Dbg("invoice ok=" .. tostring(ok) .. " type=" .. tostring(invoiceType) .. " item=" .. tostring(itemName) .. " bid=" .. tostring(bid) ..
      " buyout=" .. tostring(buyout) .. " deposit=" .. tostring(deposit) .. " cut=" .. tostring(consignment) .. " count=" .. tostring(count))
  if not ok or not invoiceType then return nil end
  return invoiceType, itemName, playerName, bid, buyout, deposit, consignment, count
end

-- Without invoice data the subject still says what happened: "Auction won: X" / "Auction successful: X".
local function prefixOf(fmt)
  if type(fmt) ~= "string" then return nil end
  local p = fmt:gsub("%%s", "")
  p = p:gsub("^%s+", ""):gsub("%s+$", "")
  return p ~= "" and p or nil
end

local function fromSubject(i, subject, money)
  if type(subject) ~= "string" then return nil end
  local won, sold = prefixOf(AUCTION_WON_MAIL_SUBJECT), prefixOf(AUCTION_SOLD_MAIL_SUBJECT)
  local name
  if won and subject:sub(1, #won) == won then
    name = subject:sub(#won + 1):gsub("^%s+", "")
    local ok, _, itemId, _, n = pcall(GetInboxItem, i, 1)
    return "buyer", name, "", 0, 0, 0, 0, (ok and n) or 0, ok and itemId or nil
  elseif sold and subject:sub(1, #sold) == sold then
    name = subject:sub(#sold + 1):gsub("^%s+", "")
    return "seller", name, "", 0, money or 0, 0, 0, 0, nil
  end
  return nil
end

-- What each mail said, per session. Identical mails (same sender, subject, money, expiry minute) are told apart by their
-- order in the inbox ("#1", "#2"), so two equal sales are two entries. A mail that told nothing gets three looks at most.
local looked = {}

local function pack(...) return { n = select("#", ...), ... } end

local function ScanMail()
  if not GetInboxNumItems then return end
  local num = GetInboxNumItems() or 0
  local t = now()
  local order, here = {}, {}
  DB.seenN = DB.seenN or {}
  for i = 1, num do
    local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
    local minute = math.floor((t + (daysLeft or 0) * 86400) / 60)
    local sig0 = table.concat({ tostring(sender), tostring(subject), tostring(money), minute }, ":")
    order[sig0] = (order[sig0] or 0) + 1
    local sig = sig0 .. "#" .. order[sig0]
    local r = looked[sig]
    if type(r) ~= "table" and (r or 0) < 3 then
      local res = pack(invoiceFor(i))
      if not res[1] then res = pack(fromSubject(i, subject, money)) end
      stats.mails = stats.mails + 1
      if res[1] then stats.invoices = stats.invoices + 1; looked[sig] = res else looked[sig] = (r or 0) + 1 end
      Dbg("mail " .. tostring(sender) .. " / " .. tostring(subject) .. " money=" .. tostring(money) .. " -> " .. tostring(res[1]))
      r = looked[sig]
    end
    if type(r) == "table" and r[1] and r[2] then
      local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, count, itemId = unpack(r, 1, 9)
      local price = (bid and bid > 0) and bid or (buyout or 0)
      local base = table.concat({ invoiceType, itemName, playerName or "", price, deposit or 0, consignment or 0, count or 0 }, ":")
      -- the expiry estimate moves by a second or two between looks: a neighbouring minute is the same group of mails
      local key = base .. ":" .. minute
      if not DB.seen[key] then
        if DB.seen[base .. ":" .. (minute - 1)] then key = base .. ":" .. (minute - 1)
        elseif DB.seen[base .. ":" .. (minute + 1)] then key = base .. ":" .. (minute + 1) end
      end
      here[key] = (here[key] or 0) + 1
      local logged = DB.seenN[key] or (DB.seen[key] and 1 or 0)
      if here[key] > logged then              -- one more identical mail than recorded so far: a new sale or purchase
        DB.seen[key], DB.seenN[key] = t, here[key]
        local id = itemId or itemIdOf(GetInboxItemLink and GetInboxItemLink(i, 1)) or itemIdOf(itemName)
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
  if nSold > 0 or nBought > 0 then Dbg("merchant sold=" .. nSold .. " bought=" .. nBought .. " money change=" .. dm) end
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
f:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
pcall(f.RegisterEvent, f, "BANK_TABS_CHANGED")       -- not on every client

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= "FMITracker" then return end
    FMITrackerDB = FMITrackerDB or {}
    DB = FMITrackerDB
    DB.version, DB.log, DB.seen, DB.chars = VERSION, DB.log or {}, DB.seen or {}, DB.chars or {}
    local t = now()
    DB.seenN = DB.seenN or {}
    for k, v in pairs(DB.seen) do if t - v > SEEN_DAYS * 86400 then DB.seen[k], DB.seenN[k] = nil, nil end end
  elseif not DB then
    return
  elseif event == "PLAYER_LOGIN" then
    char = charKey()
    local level = UnitLevel("player")
    -- update the character, never replace it: bank and mail are only read when opened and must survive a new login
    local me = DB.chars[char] or {}
    DB.chars[char] = me
    me.level, me.class, me.seen, me.forever = level, select(2, UnitClass("player")), now(), (WOW_PROJECT_ID == 18) or nil
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
    safe(ScanBank)
    safe(ScheduleHoldings)
  elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "BANK_TABS_CHANGED" then
    if bankOpen then safe(ScheduleHoldings) end
  elseif event == "BANKFRAME_CLOSED" then
    bankOpen = false                                   -- the last reading taken while it was open stands
  elseif event == "MERCHANT_SHOW" then
    merchant = { bags = bagCounts(), money = GetMoney() }
    Dbg("merchant opened")
  elseif event == "MERCHANT_CLOSED" then
    safe(CheckMerchant)
    Dbg("merchant closed")
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
