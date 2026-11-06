# Changelog

## 0.2.0 (6 Nov 2026)
- **Bank on WoW Forever and modern Retail:** the bank is read from the tabs the player bought (`C_Bank.FetchPurchasedBankTabData`, the way BagBrother does), while the bank window is open: on opening and on every change of its slots. Before, it was read when the window closed, when the client may no longer answer. Older clients keep the fixed bank containers.
- **A new login no longer wipes the character:** level, class and the login time are updated; bags, bank, mail and professions are kept. Before, the bank disappeared after every login until the bank was opened again.
- **Identical auction mails are counted, not merged:** two equal sales (same item, price, deposit, cut, quantity, expiry minute) are two entries. Taking one mail or reading the inbox again adds nothing. Keys written by 0.1.0 still count as recorded.
- Tests: 6 new (bank tabs, bank after closing and a new login, deposit while open, identical sales, a later identical sale, old keys).

## 0.1.0 (unreleased)
- First version. Auction mail invoices (sales and purchases), vendor sales and purchases, repairs, flights, trainers and the holdings of each character (bags, bank, mailbox attachments, shared bank), written to `FMITrackerDB`.
- Tested only against a fake of the WoW API (`tests/`), not yet in the game.
