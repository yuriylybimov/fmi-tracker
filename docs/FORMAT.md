# The FMITrackerDB format

WoW writes it to `WTF/Account/<account>/SavedVariables/FMITracker.lua` on `/reload`, logout or exit. A reader needs a Lua *table literal* parser; the file is data, never run it as code.

```
FMITrackerDB = {
  version = "0.1.0",
  log   = { "ts|kind|itemId|name|qty|a|b|c|character", ... },        -- oldest first, at most 20,000 lines
  chars = { ["<character>"] = { bags = {[itemId] = count}, bank = {...}, mail = {...},
                                 money = copper, level = n, class = "WARRIOR", bagsAt = ts, bankAt = ts, mailAt = ts, seen = ts,
                                 prof = {[skillLineId] = skillLevel}, profNames = {["English skill name"] = level}, profAt = ts } },
  account = { [itemId] = count },       -- the shared (warband) bank, when it has been opened
  seen = { [dedupe key] = ts }, seenN = { [dedupe key] = n },   -- the addon's own bookkeeping, ignore
  savedAt = ts,                         -- 0.4.0: when the game last wrote this file (set at logout / reload)
  opt = { save = "button" | "popup" | "off", tooltip = true },   -- 0.7.0 / 0.5.0: how saving is offered; the tooltip lines
  live = { [itemId] = { copper, quantity, ts } },   -- 0.6.0: the newest auction price the player saw (lowest per unit), 3000 items at most
  de = { "ts|itemId|quality|itemLevel|classID|salvager|materials|character", ... },   -- 0.13.0: your disenchants, oldest first, 5000 at most
}
```

`de` (0.13.0): one line per Disenchant the character cast (spell 13262). `materials` is `id:qty,id:qty` (what the loot
window held, summed per item). `salvager` is `1` when the Arcane Salvager buff (aura 1283701) was on at the start and the
end of the cast, `0` when it was off both times, `?` when it changed during the cast: treat `?` as unknown. The item is the
bag item clicked while the spell asked for a target, else the one armour or weapon item that left the bags; when that is
not certain, nothing is written.

* `<character>`: `Name-Realm` on Retail, `Name Surname` in WoW Forever.
* A holdings key is the item id, or the string `"v<itemId>"` for a variant (bonus ids, enchant, gems or suffix): never treat it as the plain item.
* `ts` is server time (UTC epoch seconds). Money is copper.
* `bank` is read only while the bank window is open (0.2.0: from the purchased bank tabs). `bankAt` says when; a missing `bank` means "never seen", not "empty". A new login keeps it.

## Log lines

| kind | meaning | qty | a | b | c |
|---|---|---|---|---|---|
| `as` | auction sale (seller invoice) | units | price for all units | AH cut | deposit returned |
| `ab` | auction purchase (buyer invoice) | units | price paid for all units | 0 | 0 |
| `vs` | vendor sale | units | copper received | 0 | 0 |
| `vb` | vendor purchase | units | copper paid | 0 | 0 |
| `rp` / `tx` / `tr` | repair / flight / trainer | 1 | copper paid | 0 | 0 |
| `ae` / `ac` (0.14.0) | auction back unsold: expired / cancelled (the mail with the item) | units | 0 | 0 | when the mail was sent (estimated from its days left; an auction house mail lasts 30 days) |

* `itemId` is 0 when the game gave no id (a sale mail has the item *name* only); resolve the name yourself, and only when it belongs to exactly one item.
* `qty` 0 means the game gave no quantity: do not guess one.
* The sale's unit price after the cut is `(a - b) / qty`.

`prof` holds the professions from `GetProfessions`/`GetProfessionInfo`, keyed by skill line id (171 Alchemy, 164 Blacksmithing, 185 Cooking, 333 Enchanting, 202 Engineering, 129 First Aid, 356 Fishing, 182 Herbalism, 773 Inscription, 755 Jewelcrafting, 165 Leatherworking, 186 Mining, 393 Skinning, 197 Tailoring). `profNames` is the fallback for a client without that call (English skill names from the skill list). An empty reading, as at logout, never replaces a known list. A reader treats a missing `profAt` as "not recorded", which is different from "no profession".
