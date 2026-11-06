# FMI Tracker

A small, read-only World of Warcraft addon for players who track their gold. It records, per character, what only the game knows and no auction scan can show, and writes it to one saved-variables file that a companion app (or your own spreadsheet script) can read.

**Status: alpha.** The logic is tested against a fake of the WoW API (`tests/`); it has not been proven in the game yet. Expect rough edges and please open an issue with what you see.

Works on Retail (Interface 120105) and WoW Forever (16001): both use the modern client API.

## What it records
- **Auction sales and purchases**, from the mail invoices ("Auction successful", "Auction won"): price, auction house cut, deposit. Needs the mailbox to be opened (you open it anyway to collect the gold). Each mail is recorded once.
- **Vendor sales and purchases**, from the change of your bags while a merchant window is open.
- **Repairs, flights, trainers**: the money spent right after the action.
- **Professions** of each character (skill line ids), so a reader can tell which crafts the player can make.
- **What each character holds**: bags (always), bank and shared bank (read while the bank is open, from the tabs you bought; kept across logins), mailbox attachments (when you open the mailbox). Items with bonus ids, enchants, gems or a suffix are kept as variants.

Not recorded (yet): lost deposits (expired or cancelled auctions), quest and loot money, trades between players, the guild bank.

## What it never does
It does not buy, sell, post, cancel, open or take mail, and it does not scan the auction house. Everything stays in `WTF/.../SavedVariables/FMITracker.lua` on your computer. Nothing is sent anywhere.

## Install
Copy the `FMITracker` folder into `World of Warcraft/_retail_/Interface/AddOns/` (or `_forever_`). Enable it on the character select screen. In the game `/fmit` shows how many entries are recorded.

The game writes the file only on `/reload`, logout or exit; that is a client rule, not a choice of the addon.

## Size
About 60 bytes per log line; the last 20,000 lines are kept (about 1.2 MB). Holdings are a few kilobytes per character.

## The file format
See [docs/FORMAT.md](docs/FORMAT.md). It is the whole contract with any reader.

## Development
`pip install -r requirements-dev.txt && python -m unittest discover -s tests -v` runs the addon in Lua (via `lupa`) against a small fake of the WoW API: mail invoices, vendors, repairs, holdings. Pull requests with tests for new behaviour are welcome.

## License
MIT.
