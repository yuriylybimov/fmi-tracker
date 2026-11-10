# Changelog

## 0.9.0 (10 Nov 2026)
- Tooltip prices named by what they are:
  - **FMI last seen (7 min ago, 267 listed)**: the cheapest lot you saw yourself on the auction house (was "FMI AH now"); now shown for 24 h, also when the app's data is newer.
  - **FMI min (13 min ago, 426 listed)**: the cheapest lot of the whole auction house in the app's latest snapshot (was "FMI lowest lot", shown only when far under the market).
  - **FMI real price**: the price at 15% of the listed units, cheapest first, so a few bait lots cannot fake it (was "FMI market"); shown only when at least 3% above the min.

## 0.8.2 (10 Nov 2026)
- The "FMI: on your Watch list" line is gone from the tooltip (the app still sends the list; nothing shows it in the game for now).

## 0.8.1 (10 Nov 2026)
- Tooltip lines in the style of the other auction addons (AuctionDB): no header and no auction-house name; each line says what it is with the time and the quantity in brackets, value on the right: **FMI market (23 min ago, 500 listed)**, FMI lowest lot, FMI 24h, FMI demand, **FMI AH now (3 min ago, 450 listed)**, **FMI your last sale (2 d ago)**, FMI your last buy, FMI: on your Watch list. One label colour (bronze), white values; the age turns orange past 6 h.

## 0.8.0 (10 Nov 2026)
- **One FMI block in the tooltip** with a header **FMI · <auction house>** and the age of the app's scan on the right ("scan 40 min ago"; orange when older than 6 h). Under it, indented: AH now (live, when newer), Market, Lowest lot (when more than 10% under), Listed (units on the AH), 24h (the market price against the app's snapshot a day before, green / red from 3%), Demand, Your last sale / buy, On your Watch list.
- Money with the game's coin icons (the client of WoW Forever has no `GetCoinTextureString`, so 0.5.0 showed "2s 9c"); zero units left out (1g 10s, not 1g 10s 0c).
- The separate "prices from N h ago" line is gone: the header says it.

## 0.7.0 (10 Nov 2026)
- **Quieter saving:** the plate no longer pops up by default. Instead a small **Save for the app (N)** button sits under the mailbox or the merchant window, only while one of them is open and something is unsaved; its tooltip says what it does. Logging out still saves everything.
- `/fmit reminder button` (default), `/fmit reminder popup` (the plate, now at most once per 30 minutes after "Later"), `/fmit reminder off`. The old `/fmit prompt off|on` still works. Whoever switched the plate off in 0.4.0 stays off.
- Tests: 3 new (button by default, popup snooze and off, an old switch-off kept).

## 0.6.0 (10 Nov 2026)
- **Live auction prices, no /reload:** while the auction house is open, FMI Tracker keeps what the game already shows you: the browse / search list (lowest price, quantity listed), the lots of a commodity and the lots of one item (lowest buyout per unit, bid-only lots left out). The tooltip shows it at once as **FMI AH now: price · N min ago · N listed**, above the app's lines, when it is newer than the app data and under 6 h old. It never sends a search itself.
- Kept in `FMITrackerDB.live[itemId] = {copper per unit, quantity, time}` (the newest 3000 items), so it survives a reload. Variants (suffix, pet species) are not kept.
- Tests: 3 new (browse / commodity / item results and variants, the tooltip line against app data, after a reload and when old).

## 0.5.0 (10 Nov 2026)
- **Tooltip lines from the app:** the Market Intelligence app writes a small addon `FMITracker_Data` (`Data.lua`, the table `FMITrackerAppData`) into the game's AddOns folder every 10 minutes when its data changed, the way the TSM desktop app feeds its helper addon. FMI Tracker reads it (the game loads it at login or `/reload`) and adds to item tooltips: **FMI market** (market price; the lowest lot too when it is more than 10% under it), **FMI demand** (sells fast / steadily / slowly / not selling, about N a day, once the app has 48 h of turnover), **FMI your last sale / last buy** (per unit, how long ago) and **on your Watch list**. Prices older than 6 h add a grey note. A variant (bonus ids, enchant, suffix) never gets the price of the plain item.
- `/fmit tooltip off|on`; `/fmit` also says which app data is loaded (house, items, age).
- `FMITracker.tooltipLines(itemId, link)` for other addons.
- The addon list: category "Auction & Economy" and a coin icon; the app's `FMITracker_Data` has the same category and a name starting with `FMITracker`, so it is listed under FMI Tracker (like QuestieDB under Questie), and loads only with it.
- Tests: 4 new (lines, variants, old prices and switching off, no app data).

## 0.4.0 (10 Nov 2026)
- **Save reminder:** the game writes the file only on `/reload`, logout or exit. When a mailbox or a merchant window closes and something new was recorded, a small plate offers "N new entries not saved for the app yet" with **Save for the app** (reloads the interface; a click, so the player's own action) and **Later** (waits until there is something new again). It never shows in combat or in an instance (it comes back after), and hides by itself after 45 s.
- `/fmit save` writes the file now (reloads the interface); `/fmit prompt off|on` switches the reminder (kept in `FMITrackerDB.opt.prompt`); `/fmit` also says how many entries wait.
- `FMITrackerDB.savedAt`: the time of the last write (set at `PLAYER_LOGOUT`, which also fires on `/reload`).
- A global `FMITracker` table for other addons: `unsaved()`, `promptShown()`, `offer()`, `save()`, `later()`.
- Tests: 4 new (plate after the mailbox, combat and instances, Later and switching off, the time of the write).

## 0.3.0 (9 Nov 2026)
- **Profession trainers apart:** money paid to a profession trainer is logged as `tp`, to a class or riding trainer as `tr` (`IsTradeskillTrainer()` at the purchase). Entries written before keep `tr` for any trainer.
- Test: 1 new (class and profession trainer).

## 0.2.0 (6 Nov 2026)
- **Bank on WoW Forever and modern Retail:** the bank is read from the tabs the player bought (`C_Bank.FetchPurchasedBankTabData`, the way BagBrother does), while the bank window is open: on opening and on every change of its slots. Before, it was read when the window closed, when the client may no longer answer. Older clients keep the fixed bank containers.
- **A new login no longer wipes the character:** level, class and the login time are updated; bags, bank, mail and professions are kept. Before, the bank disappeared after every login until the bank was opened again.
- **Identical auction mails are counted, not merged:** two equal sales (same item, price, deposit, cut, quantity, expiry minute) are two entries. Taking one mail or reading the inbox again adds nothing. Keys written by 0.1.0 still count as recorded.
- Tests: 6 new (bank tabs, bank after closing and a new login, deposit while open, identical sales, a later identical sale, old keys).

## 0.1.0 (unreleased)
- First version. Auction mail invoices (sales and purchases), vendor sales and purchases, repairs, flights, trainers and the holdings of each character (bags, bank, mailbox attachments, shared bank), written to `FMITrackerDB`.
- Tested only against a fake of the WoW API (`tests/`), not yet in the game.
