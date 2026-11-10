# Changelog

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
