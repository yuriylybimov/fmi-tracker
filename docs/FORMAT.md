# The FMITrackerDB format

WoW writes it to `WTF/Account/<account>/SavedVariables/FMITracker.lua` on `/reload`, logout or exit. A reader needs a Lua *table literal* parser; the file is data, never run it as code.

```
FMITrackerDB = {
  version = "0.1.0",
  log   = { "ts|kind|itemId|name|qty|a|b|c|character", ... },        -- oldest first, at most 20,000 lines
  chars = { ["<character>"] = { bags = {[itemId] = count}, bank = {...}, mail = {...},
                                 money = copper, level = n, class = "WARRIOR", bagsAt = ts, bankAt = ts, mailAt = ts, seen = ts } },
  account = { [itemId] = count },       -- the shared (warband) bank, when it has been opened
  seen = { [dedupe key] = ts },         -- the addon's own bookkeeping, ignore
}
```

* `<character>`: `Name-Realm` on Retail, `Name Surname` in WoW Forever.
* A holdings key is the item id, or the string `"v<itemId>"` for a variant (bonus ids, enchant, gems or suffix): never treat it as the plain item.
* `ts` is server time (UTC epoch seconds). Money is copper.

## Log lines

| kind | meaning | qty | a | b | c |
|---|---|---|---|---|---|
| `as` | auction sale (seller invoice) | units | price for all units | AH cut | deposit returned |
| `ab` | auction purchase (buyer invoice) | units | price paid for all units | 0 | 0 |
| `vs` | vendor sale | units | copper received | 0 | 0 |
| `vb` | vendor purchase | units | copper paid | 0 | 0 |
| `rp` / `tx` / `tr` | repair / flight / trainer | 1 | copper paid | 0 | 0 |

* `itemId` is 0 when the game gave no id (a sale mail has the item *name* only); resolve the name yourself, and only when it belongs to exactly one item.
* `qty` 0 means the game gave no quantity: do not guess one.
* The sale's unit price after the cut is `(a - b) / qty`.
