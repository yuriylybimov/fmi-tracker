-- FMI Tracker 0.8.0
-- Records, per character, what only the game knows and no scan can show:
--   as  auction sale      (mail invoice "seller"): gross price, AH cut, deposit
--   ab  auction purchase  (mail invoice "buyer"): price paid
--   vs  vendor sale, vb vendor purchase (bag change while a merchant is open)
--   rp  repair, tx flight, tr class trainer, tp profession trainer (money spent right after the action)
-- and, per character, what it holds: FMITrackerDB.chars[name] = {bags, bank, mail = {[itemId] = count}, money, ...};
-- the account (warband) bank is FMITrackerDB.account. A key "v<itemId>" is a VARIANT (bonus ids, enchant, gems, suffix):
-- never priced like the plain item.
-- It never buys, sells, posts, cancels, opens or takes mail, and it does not scan the auction house.
-- Output: FMITrackerDB.log, one string per entry: "ts|kind|itemId|name|qty|a|b|c|character"
--   as: a = price (copper, all units), b = AH cut, c = deposit returned
--   ab: a = price paid (all units)
--   vs: a = copper received (all units)   vb: a = copper paid (all units)
--   rp / tx / tr / tp: a = copper paid (tr before 0.3.0 is any trainer)
-- The file is written by the game on /reload or logout. Money is in copper, time is server time (UTC epoch).
-- 0.4.0: after a mailbox or a merchant closes with new entries, a small plate offers to save them for the app; its button
-- reloads the interface (the only way the game writes the file). Never in combat or in an instance. /fmit save, /fmit prompt.
-- 0.5.0: reads FMITrackerAppData (the addon FMITracker_Data, written by the Market Intelligence app into the AddOns folder)
-- and adds market price, demand, your last sale / purchase and the Watch mark to item tooltips. /fmit tooltip off|on.
-- 0.6.0: remembers the auction prices the game shows you while the auction house is open (search results and an item's
-- lots; it never searches by itself) and puts them in the tooltip at once: "FMI AH now", no /reload needed.
-- 0.7.0: quieter saving: by default no plate pops up; a small "Save for the app (N)" button sits under the mailbox or the
-- merchant window while something is unsaved. /fmit reminder button|popup|off (popup at most every 30 min).

local VERSION = "0.8.0"
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

local newN = 0                 -- entries logged since the game last wrote the file (this session)
local afterLog                 -- set below: refreshes the save button
local function Log(kind, itemId, name, qty, a, b, c)
  newN = newN + 1
  if afterLog then afterLog() end
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

-- a profession trainer (IsTradeskillTrainer) or a class / riding one; asked at the purchase, while the trainer is open
local function trainerKind()
  if IsTradeskillTrainer and IsTradeskillTrainer() then return "tp" end
  return "tr"
end

local function hook(name, kind)
  local fn = _G[name]
  if type(fn) == "function" then hooksecurefunc(name, function() Expect(kind) end) return true end
  return false
end

-- ---------------------------------------------------------------- saving for the app
-- The game writes FMITracker.lua only on /reload, logout or exit; an addon cannot write it in any other way. So after a
-- mailbox or a merchant closes with new entries, a small plate offers a one-click save: its button calls ReloadUI() (a
-- click is the player's own action). Never in combat or in an instance (it waits and comes back after); "Later" waits
-- until there is something new again; the plate hides by itself after 45 s. /fmit prompt off switches it off.
local prompt, promptShown, snoozedAt, pending = nil, false, 0, false
local function quietPlace()
  if InCombatLockdown and InCombatLockdown() then return true end
  if IsInInstance then local inside = IsInInstance(); if inside then return true end end
  return false
end
local function HidePrompt()
  promptShown = false
  if prompt then prompt:Hide() end
end
local function SaveNow() ReloadUI() end
local function SavePrompt()
  if prompt then return prompt end
  local p = CreateFrame("Frame", "FMITrackerSavePrompt", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  p:SetSize(320, 78)
  p:SetPoint("TOP", UIParent, "TOP", 0, -110)
  p:SetFrameStrata("DIALOG")
  if p.SetBackdrop then
    p:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    p:SetBackdropColor(0.06, 0.05, 0.04, 0.95)
    p:SetBackdropBorderColor(0.80, 0.50, 0.20, 0.9)
  end
  p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.text:SetPoint("TOPLEFT", 12, -10)
  p.text:SetPoint("TOPRIGHT", -12, -10)
  p.text:SetJustifyH("LEFT")
  local save = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  save:SetSize(150, 22)
  save:SetPoint("BOTTOMLEFT", 12, 10)
  save:SetText("Save for the app")
  save:SetScript("OnClick", SaveNow)
  local later = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  later:SetSize(80, 22)
  later:SetPoint("LEFT", save, "RIGHT", 8, 0)
  later:SetText("Later")
  later:SetScript("OnClick", function() FMITracker.later() end)
  p:Hide()
  prompt = p
  return p
end
local snoozeUntil = 0
local function saveMode() return (DB and DB.opt and DB.opt.save) or "button" end
local function OfferSave()
  if not DB or saveMode() ~= "popup" then return end
  if newN < 1 or newN <= snoozedAt or now() < snoozeUntil then return end
  if quietPlace() then pending = true; return end
  pending = false
  local p = SavePrompt()
  p.text:SetText(("|cff66ccffFMI Tracker|r: %d new %s not saved for the app yet. Saving reloads the interface (a few seconds).")
    :format(newN, newN == 1 and "entry" or "entries"))
  p:Show()
  promptShown = true
  local shownAt = newN
  if C_Timer and C_Timer.After then C_Timer.After(45, function() if promptShown and newN == shownAt then HidePrompt() end end) end
end
-- for other addons and the tests: how many entries wait for the next write, and whether the plate is up
-- The quiet way (default): a small button under the mailbox or the merchant window, only while one is open and
-- something is unsaved. Nothing pops up.
local saveBtn, btnShown, openHost = nil, false, nil
local function UpdateSaveButton()
  local host = (openHost == "mail" and MailFrame) or (openHost == "merchant" and MerchantFrame) or nil
  if host and host.IsShown and host:IsShown() == false then openHost, host = nil, nil end   -- the window is gone
  local want = DB and saveMode() == "button" and openHost and newN > 0
  if not want then
    if saveBtn then saveBtn:Hide() end
    btnShown = false
    return
  end
  if not saveBtn then
    saveBtn = CreateFrame("Button", "FMITrackerSaveButton", UIParent, "UIPanelButtonTemplate")
    saveBtn:SetSize(176, 22)
    saveBtn:SetFrameStrata("HIGH")
    saveBtn:SetScript("OnClick", SaveNow)
    saveBtn:SetScript("OnEnter", function(self)
      if not GameTooltip then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("FMI Tracker")
      GameTooltip:AddLine("Writes the new entries for the Market Intelligence app now. The game writes them only on a reload or logout, so this reloads the interface (a few seconds). Logging out saves them too.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  end
  saveBtn:ClearAllPoints()
  if host then saveBtn:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", 0, -2) else saveBtn:SetPoint("TOP", UIParent, "TOP", 0, -110) end
  saveBtn:SetText(("Save for the app (%d)"):format(newN))
  saveBtn:Show()
  btnShown = true
end
afterLog = function() if openHost then UpdateSaveButton() end end
local function later() snoozedAt = newN; snoozeUntil = now() + 1800; HidePrompt() end
FMITracker = { version = VERSION, unsaved = function() return newN end, promptShown = function() return promptShown end,
               buttonShown = function() return btnShown end, offer = OfferSave, save = SaveNow, later = later }

-- ---------------------------------------------------------------- events
local warned = false
local function safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and not warned then
    warned = true
    print("|cffff8844FMI Tracker|r: " .. tostring(err) .. " (shown once)")
  end
end

-- ---------------------------------------------------------------- live auction prices you see (0.6.0)
-- While the auction house is open the game hands addons what it shows the player: the browse / search list (lowest
-- price and quantity per item) and the lots of one item. FMI Tracker keeps the newest reading per plain item in
-- FMITrackerDB.live[itemId] = {lowest copper per unit, quantity listed, time}. It never sends a search itself.
-- Variants (suffix, pet species) are not kept. The oldest readings go first past MAX_LIVE.
local MAX_LIVE = 3000
local liveN = 0
local function trimLive()
  local all = {}
  for id, v in pairs(DB.live) do all[#all + 1] = { id, v[3] or 0 } end
  table.sort(all, function(a, b) return a[2] > b[2] end)
  for i = MAX_LIVE + 1, #all do DB.live[all[i][1]] = nil end
  liveN = math.min(#all, MAX_LIVE)
end
local function Seen(itemId, unit, qty)
  if not DB or not itemId or not unit or unit <= 0 then return end
  if not DB.live[itemId] then liveN = liveN + 1 end
  DB.live[itemId] = { math.floor(unit), math.floor(qty or 0), now() }
  if liveN > MAX_LIVE + 200 then trimLive() end
end
local function plainKey(key)
  return type(key) == "table" and key.itemID and (key.itemSuffix or 0) == 0 and (key.battlePetSpeciesID or 0) == 0
end
local function ReadBrowse(results)
  local AH = C_AuctionHouse
  results = results or (AH and AH.GetBrowseResults and AH.GetBrowseResults())
  for _, r in ipairs(results or {}) do
    if plainKey(r.itemKey) and r.minPrice then Seen(r.itemKey.itemID, r.minPrice, r.totalQuantity) end
  end
end
local function ReadCommodity(itemId)
  local AH = C_AuctionHouse
  if not (AH and itemId and AH.GetNumCommoditySearchResults) then return end
  local n = AH.GetNumCommoditySearchResults(itemId) or 0
  if n < 1 then return end
  local first = AH.GetCommoditySearchResultInfo(itemId, 1)
  local qty = AH.GetCommoditySearchResultsQuantity and AH.GetCommoditySearchResultsQuantity(itemId)
  if not qty then qty = 0; for i = 1, n do local r = AH.GetCommoditySearchResultInfo(itemId, i); qty = qty + ((r and r.quantity) or 0) end end
  if first and first.unitPrice then Seen(itemId, first.unitPrice, qty) end
end
local function ReadItem(itemKey)
  local AH = C_AuctionHouse
  if not (AH and plainKey(itemKey) and AH.GetNumItemSearchResults) then return end
  local n, low, qty = AH.GetNumItemSearchResults(itemKey) or 0, nil, 0
  for i = 1, n do
    local r = AH.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and (r.quantity or 0) > 0 then
      local unit = r.buyoutAmount / r.quantity
      if not low or unit < low then low = unit end
      qty = qty + r.quantity
    end
  end
  if low then Seen(itemKey.itemID, low, qty) end
end

-- ---------------------------------------------------------------- tooltip lines from the app (0.5.0)
-- FMITrackerAppData comes from the addon FMITracker_Data that the Market Intelligence app writes into the AddOns folder
-- (read by the game at login or /reload). items[id] = {market, min, units, tier, perDay}; sold/bought[id] = {unit, ts}.
local TIER = { [3] = "sells fast", [2] = "sells steadily", [1] = "sells slowly", [0] = "not selling" }
-- Money with the game's coin icons (GetCoinTextureString does not exist on every client): 2s 9c, 1g 10s; zero units left out.
local ICON = { g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t", s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
               c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" }
local function coins(c)
  c = math.floor((tonumber(c) or 0) + 0.5)
  local g, si, co = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out = {}
  if g > 0 then out[#out + 1] = g .. ICON.g end
  if si > 0 then out[#out + 1] = si .. ICON.s end
  if co > 0 or #out == 0 then out[#out + 1] = co .. ICON.c end
  return table.concat(out, " ")
end
local function agoText(ts)
  local d = now() - (tonumber(ts) or 0)
  if d < 3600 then return math.max(1, math.floor(d / 60)) .. " min ago" end
  if d < 172800 then return math.floor(d / 3600) .. " h ago" end
  return math.floor(d / 86400) .. " d ago"
end
local function pct(v)
  v = tonumber(v)
  if not v then return nil end
  local t = (v > 0 and "+" or "") .. v .. "%"
  if v >= 3 then return "|cff4fd27a" .. t .. "|r" end
  if v <= -3 then return "|cfff07a6a" .. t .. "|r" end
  return t
end
-- The FMI block of one item: a list of {left, right, kind}. The first line is the header "FMI · <house>" with the age of
-- the app's scan (kind "head", or "stale" when older than 6 h). A variant (bonus ids, enchant, suffix) gets no price of
-- the plain item. Nothing at all when there is nothing to say.
local function TooltipLines(itemId, link)
  if not itemId then return {} end
  if DB and DB.opt and DB.opt.tooltip == false then return {} end
  local A = type(FMITrackerAppData) == "table" and FMITrackerAppData or {}
  local variant = isVariant(link)
  local it = (not variant) and A.items and A.items[itemId]
  local lv = (not variant) and DB and DB.live and DB.live[itemId]
  if lv and not (now() - lv[3] < 6 * 3600 and (not A.at or lv[3] >= A.at)) then lv = nil end
  local s, b, w = A.sold and A.sold[itemId], A.bought and A.bought[itemId], A.watch and A.watch[itemId]
  if not (it or lv or s or b or w) then return {} end
  local out = {}
  local stale = it and A.at and now() - A.at > 6 * 3600
  out[1] = { "FMI" .. (A.house and (" · " .. A.house) or ""), (it and A.at) and ("scan " .. agoText(A.at)) or nil, stale and "stale" or "head" }
  if lv then
    out[#out + 1] = { "  AH now", coins(lv[1]) .. " · " .. agoText(lv[3]) .. ((lv[2] or 0) > 0 and (" · " .. lv[2] .. " listed") or "") }
  end
  if it then
    local market, min, units, tier, perDay, change = it[1], it[2], it[3], it[4], it[5], it[6]
    if market or min then out[#out + 1] = { "  Market", coins(market or min) } end
    if market and min and min < market * 0.9 then out[#out + 1] = { "  Lowest lot", coins(min) } end
    if units and units > 0 then out[#out + 1] = { "  Listed", tostring(units) } end
    if change then out[#out + 1] = { "  24h", pct(change) } end
    if tier and TIER[tier] then
      out[#out + 1] = { "  Demand", TIER[tier] .. ((perDay and perDay > 0) and (" · ~" .. math.floor(perDay + 0.5) .. "/day") or "") }
    end
  end
  if s then out[#out + 1] = { "  Your last sale", coins(s[1]) .. " · " .. agoText(s[2]) } end
  if b then out[#out + 1] = { "  Your last buy", coins(b[1]) .. " · " .. agoText(b[2]) } end
  if w then out[#out + 1] = { "  On your Watch list" } end
  return out
end
local function AddLines(tt, itemId, link)
  for _, l in ipairs(TooltipLines(itemId, link)) do
    if l[3] == "head" or l[3] == "stale" then
      local o = l[3] == "stale"
      tt:AddDoubleLine(l[1], l[2] or " ", 0.86, 0.62, 0.36, o and 1 or 0.6, o and 0.6 or 0.6, o and 0.25 or 0.6)
    elseif l[2] then tt:AddDoubleLine(l[1], l[2], 0.78, 0.78, 0.78, 1, 1, 1)
    else tt:AddLine(l[1], 0.86, 0.62, 0.36) end
  end
end
local hooked = false
local function HookTooltips()
  if hooked then return end
  hooked = true
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
      if tt ~= GameTooltip and tt ~= ItemRefTooltip then return end
      local link
      if tt.GetItem then local _, l = tt:GetItem(); link = l end
      safe(AddLines, tt, (data and data.id) or itemIdOf(link), link)
    end)
  elseif GameTooltip and GameTooltip.HookScript then
    for _, tt in ipairs({ GameTooltip, ItemRefTooltip }) do
      if tt then tt:HookScript("OnTooltipSetItem", function(self) local _, link = self:GetItem(); safe(AddLines, self, itemIdOf(link), link) end) end
    end
  end
end
FMITracker.tooltipLines = TooltipLines
FMITracker.live = function(itemId) return DB and DB.live and DB.live[itemId] end

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("MAIL_SHOW")
f:RegisterEvent("MAIL_INBOX_UPDATE")
f:RegisterEvent("MAIL_CLOSED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
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
for _, e in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED",
                     "ITEM_SEARCH_RESULTS_UPDATED" }) do pcall(f.RegisterEvent, f, e) end   -- the modern auction house only

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= "FMITracker" then return end
    FMITrackerDB = FMITrackerDB or {}
    DB = FMITrackerDB
    DB.version, DB.log, DB.seen, DB.chars = VERSION, DB.log or {}, DB.seen or {}, DB.chars or {}
    DB.opt = DB.opt or {}
    if DB.opt.save == nil then DB.opt.save = (DB.opt.prompt == false) and "off" or "button" end   -- 0.7.0: quiet by default
    DB.live = DB.live or {}
    for _ in pairs(DB.live) do liveN = liveN + 1 end
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
    if type(BuyTrainerService) == "function" then hooksecurefunc("BuyTrainerService", function() Expect(trainerKind()) end) end
    if C_Trainer and C_Trainer.BuyProvidedService then hooksecurefunc(C_Trainer, "BuyProvidedService", function() Expect(trainerKind()) end) end
    safe(HookTooltips)
  elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
    openHost = "mail"
    safe(ScanMail)
    safe(ScanMailItems)
    safe(UpdateSaveButton)
  elseif event == "MAIL_CLOSED" then
    openHost = nil
    safe(UpdateSaveButton)
    safe(OfferSave)
  elseif event == "PLAYER_REGEN_ENABLED" then
    if pending then safe(OfferSave) end
  elseif event == "PLAYER_ENTERING_WORLD" then
    safe(ScheduleHoldings)
    if pending then safe(OfferSave) end
  elseif event == "PLAYER_LOGOUT" then
    bagTimer = false
    safe(ScanHoldings)
    DB.savedAt = now()                                 -- the game writes the file right after this event
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
    openHost = "merchant"
    safe(UpdateSaveButton)
    Dbg("merchant opened")
  elseif event == "MERCHANT_CLOSED" then
    safe(CheckMerchant)
    Dbg("merchant closed")
    merchant = nil
    openHost = nil
    safe(UpdateSaveButton)
    safe(OfferSave)
  elseif event == "BAG_UPDATE_DELAYED" then
    if merchant then safe(CheckMerchant) end
    safe(ScheduleHoldings)
  elseif event == "PLAYER_MONEY" then
    safe(OnMoney)
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    safe(ReadBrowse)
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    safe(ReadBrowse, arg1)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    safe(ReadCommodity, arg1)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    safe(ReadItem, arg1)
  end
end)

SLASH_FMITRACKER1 = "/fmit"
SlashCmdList["FMITRACKER"] = function(msg)
  if not DB then return end
  msg = tostring(msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "save" then SaveNow(); return end
  if msg == "tooltip off" or msg == "tooltip on" then
    DB.opt.tooltip = (msg == "tooltip on")
    print("|cff66ccffFMI Tracker|r: the tooltip lines are " .. (DB.opt.tooltip and "on" or "off") .. ".")
    return
  end
  local m = msg:match("^reminder (%a+)$") or ({ ["prompt off"] = "off", ["prompt on"] = "popup" })[msg]
  if m == "button" or m == "popup" or m == "off" then
    DB.opt.save = m
    if m ~= "popup" then HidePrompt() end
    safe(UpdateSaveButton)
    print("|cff66ccffFMI Tracker|r: save reminder: " .. ({ button = "a button under the mailbox and merchant windows", popup = "a plate after the mailbox or a merchant (at most every 30 min)", off = "off (logout and /fmit save still save)" })[m] .. ".")
    return
  end
  print("|cff66ccffFMI Tracker|r: " .. newN .. " new since the last save. /fmit save writes them now (reloads the interface); /fmit reminder button|popup|off; /fmit tooltip off|on.")
  local A = FMITrackerAppData
  if type(A) == "table" and A.items then
    local n = 0
    for _ in pairs(A.items) do n = n + 1 end
    print("  App data: " .. tostring(A.house or "?") .. " " .. tostring(A.region or "") .. ", " .. n .. " items, prices " .. agoText(A.at or 0) .. ".")
  else
    print("  No app data yet: start the Market Intelligence app, then /reload (the addon FMITracker_Data must be enabled).")
  end
  local n = #DB.log
  print("|cff66ccffFMI Tracker " .. VERSION .. "|r: " .. n .. " entries (written to the file on /reload or logout). Mails looked at: " .. stats.mails .. ", auction invoices found: " .. stats.invoices .. ".")
  for i = math.max(1, n - 4), n do print("  " .. DB.log[i]) end
end
