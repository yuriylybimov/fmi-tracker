"""Runs the addon (FMITracker.lua) in Lua against a fake of the WoW API: the logic of the addon, not the game."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import run_tracker as R
except ImportError:                                  # lupa is optional (pip install lupa)
    R = None


@unittest.skipIf(R is None, 'lupa is not installed')
class Addon(unittest.TestCase):
    def setUp(self):
        self.lua, self.g = R.boot()

    def rows(self):
        return [r.split('|') for r in R.log(self.lua)]

    def test_auction_invoices_are_logged_once_even_when_the_mail_is_looked_at_again(self):
        self.lua.execute('_mail = {{sender="AH", subject="s", money=7600, daysLeft=29.5, invoice={type="seller",name="Copper Ore",player="B",bid=8000,buyout=8000,deposit=300,cut=400,count=20}},'
                         '{sender="AH", subject="w", money=0, daysLeft=29.9, link="|Hitem:2589::|h", invoice={type="buyer",name="Linen Cloth",player="S",bid=5000,buyout=5000,deposit=0,cut=0,count=50}},'
                         '{sender="Friend", subject="hi", money=0, daysLeft=20}}')
        for ev in ('MAIL_SHOW', 'MAIL_INBOX_UPDATE', 'MAIL_SHOW'):
            self.g.fire(ev)
        self.lua.execute('_t = _t + 5; _mail[1].daysLeft = 29.499')
        self.g.fire('MAIL_INBOX_UPDATE')
        rows = self.rows()
        self.assertEqual([(r[1], r[2], r[4], r[5], r[6], r[7]) for r in rows], [('as', '2770', '20', '8000', '400', '300'), ('ab', '2589', '50', '5000', '0', '0')])
        self.assertEqual(rows[0][8], 'Orakh Gorehowl')                       # Forever: the character is "Name Surname"

    def test_vendor_sale_purchase_repair_flight_and_unrelated_money(self):
        self.lua.execute('_bags = {[2770]=30}')
        self.g.fire('MERCHANT_SHOW')
        self.lua.execute('_bags = {[2770]=20}; _money = _money + 100')
        self.g.fire('BAG_UPDATE_DELAYED')
        self.lua.execute('_bags = {[2770]=20,[2589]=5}; _money = _money - 65')
        self.g.fire('BAG_UPDATE_DELAYED')
        self.g.run_timers()
        self.g.fire('MERCHANT_CLOSED')
        self.g.fire('MERCHANT_SHOW')
        self.lua.execute('RepairAllItems()')
        self.g.setmoney(self.lua.eval('_money - 250'))
        self.g.fire('MERCHANT_CLOSED')
        self.lua.execute('TakeTaxiNode(3)')
        self.g.setmoney(self.lua.eval('_money - 120'))
        self.g.setmoney(self.lua.eval('_money - 999'))                          # not tied to any action: not recorded
        self.assertEqual([(r[1], r[2], r[4], r[5]) for r in self.rows()],
                         [('vs', '2770', '10', '100'), ('vb', '2589', '5', '65'), ('rp', '0', '1', '250'), ('tx', '0', '1', '120')])

    def test_profession_and_class_trainers_are_told_apart(self):
        self.lua.execute('BuyTrainerService(1)')
        self.g.setmoney(self.lua.eval('_money - 500'))
        self.lua.execute('function IsTradeskillTrainer() return true end; BuyTrainerService(2)')
        self.g.setmoney(self.lua.eval('_money - 90'))
        self.assertEqual([(r[1], r[5]) for r in self.rows()], [('tr', '500'), ('tp', '90')])

    def test_holdings_bank_account_bank_mail_and_variants(self):
        self.lua.execute('_bags = {[2770]=30,[19019]=1}; _links[19019] = "|Hitem:19019::::::::60::::2:6652:1472|h"')
        self.g.fire('PLAYER_ENTERING_WORLD')
        self.g.run_timers()
        self.lua.execute('_bank = {[6]={[765]=100},[12]={[2447]=40}}')
        self.g.fire('BANKFRAME_OPENED')
        self.g.run_timers()
        self.g.fire('BANKFRAME_CLOSED')
        self.lua.execute('_mail = {{sender="AH", subject="x", money=0, daysLeft=20, att={2589, 7}}}')
        self.g.fire('MAIL_SHOW')
        get = lambda path: self.lua.eval('FMITrackerDB.%s' % path)
        self.assertEqual((get('chars["Orakh Gorehowl"].bags[2770]'), get('chars["Orakh Gorehowl"].bags.v19019'), get('chars["Orakh Gorehowl"].bank[765]'),
                          get('chars["Orakh Gorehowl"].mail[2589]'), get('account[2447]')), (30, 1, 100, 7, 40))


    def test_empty_reading_at_logout_keeps_the_last_real_holdings(self):
        self.lua.execute('_bags = {[2770]=30}')
        self.g.fire('PLAYER_ENTERING_WORLD')
        self.g.run_timers()
        self.lua.execute('_bags = {}; _money = 0')                              # what the client answers during logout / reload
        self.g.fire('PLAYER_LOGOUT')
        get = lambda path: self.lua.eval('FMITrackerDB.%s' % path)
        self.assertEqual((get('chars["Orakh Gorehowl"].bags[2770]'), get('chars["Orakh Gorehowl"].money') > 0), (30, True))

    def test_mail_without_invoice_data_yet_is_looked_at_again(self):
        self.lua.execute('_mail = {{sender="AH", subject="s", money=7600, daysLeft=29.5, invoice=nil, hide=true}}')
        self.g.fire('MAIL_SHOW')
        self.assertEqual(self.rows(), [])
        self.lua.execute('_mail[1].invoice = {type="seller",name="Copper Ore",player="B",bid=8000,buyout=8000,deposit=300,cut=400,count=20}; _mail[1].hide = nil')
        self.g.fire('MAIL_INBOX_UPDATE')
        self.assertEqual([r[1] for r in self.rows()], ['as'])


    def test_invoice_is_read_even_when_the_text_says_it_is_not_one(self):
        self.lua.execute('_mail = {{sender="Auction House", subject="Auction won: Linen Cloth", money=0, daysLeft=29.5, flagfalse=true, link="|Hitem:2589::|h",'
                         ' invoice={type="buyer",name="Linen Cloth",player="S",bid=100,buyout=100,deposit=0,cut=0,count=1}}}')
        self.g.fire('MAIL_SHOW')
        self.assertEqual([(r[1], r[2], r[4], r[5]) for r in self.rows()], [('ab', '2589', '1', '100')])

    def test_mail_subject_is_the_fallback_when_there_is_no_invoice_data(self):
        self.lua.execute('_mail = {{sender="Auction House", subject="Auction won: Linen Cloth", money=0, daysLeft=29.5, att={2589, 5}},'
                         '{sender="Auction House", subject="Auction successful: Copper Ore", money=7600, daysLeft=29.5}}')
        self.g.fire('MAIL_SHOW')
        self.g.fire('MAIL_INBOX_UPDATE')
        self.assertEqual([(r[1], r[2], r[3], r[4], r[5]) for r in self.rows()], [('ab', '2589', 'Linen Cloth', '5', '0'), ('as', '2770', 'Copper Ore', '0', '7600')])

    def test_professions_are_recorded_by_skill_line_and_survive_an_empty_reading(self):
        self.lua.execute('function GetProfessions() return 3, nil, nil, 5, 2 end '
                         'function GetProfessionInfo(i) return "n", "i", i * 10, 300, 0, 0, ({[2]=185,[3]=171,[5]=356})[i] end')
        self.g.fire('PLAYER_ENTERING_WORLD'); self.g.run_timers()
        self.assertEqual(self.lua.eval('FMITrackerDB.chars["Orakh Gorehowl"] and 1 or 0') + self.lua.eval('FMITrackerDB.chars[next(FMITrackerDB.chars)].prof[171]'), 1 + 30)
        self.lua.execute('function GetProfessions() return nil end')
        self.g.fire('PLAYER_LOGOUT')
        self.assertEqual(self.lua.eval('FMITrackerDB.chars[next(FMITrackerDB.chars)].prof[185]'), 20)

    def test_professions_fall_back_to_skill_names(self):
        self.lua.execute('function GetNumSkillLines() return 2 end '
                         'function GetSkillLineInfo(i) if i == 1 then return "Professions", true end return "Cooking", false, 0, 75 end')
        self.g.fire('PLAYER_ENTERING_WORLD'); self.g.run_timers()
        self.assertEqual(self.lua.eval('FMITrackerDB.chars[next(FMITrackerDB.chars)].profNames.Cooking'), 75)

    get = lambda self, path: self.lua.eval('FMITrackerDB.%s' % path)

    def test_bank_tabs_are_asked_from_the_game_like_bagbrother_does(self):
        # Forever / modern client: purchased tabs from C_Bank.FetchPurchasedBankTabData, the tab id is the container id
        self.lua.execute('Enum.BankType = {Character = 0, Account = 2}; '
                         'C_Bank = {FetchPurchasedBankTabData = function(t) if t == 0 then return {{ID = 6}, {ID = 7}} end return {} end}; '
                         '_bank = {[6] = {[2840] = 200}, [7] = {[2835] = 40}}')
        self.g.fire('BANKFRAME_OPENED')
        self.assertEqual((self.get('chars["Orakh Gorehowl"].bank[2840]'), self.get('chars["Orakh Gorehowl"].bank[2835]')), (200, 40))

    def test_bank_survives_closing_the_window_and_a_new_login(self):
        self.lua.execute('_bank = {[6] = {[2840] = 225}}')
        self.g.fire('BANKFRAME_OPENED')
        self.lua.execute('_bank = {}')                       # after closing the client gives no bank answer
        self.g.fire('BANKFRAME_CLOSED')
        self.g.fire('BAG_UPDATE_DELAYED'); self.g.run_timers()
        self.g.fire('PLAYER_LOGIN')                          # /reload or a new login
        self.g.fire('PLAYER_ENTERING_WORLD'); self.g.run_timers()
        self.assertEqual(self.get('chars["Orakh Gorehowl"].bank[2840]'), 225)

    def test_a_deposit_while_the_bank_is_open_is_seen(self):
        self.lua.execute('_bank = {[6] = {[2840] = 200}}')
        self.g.fire('BANKFRAME_OPENED')
        self.lua.execute('_bank = {[6] = {[2840] = 210}}')
        self.g.fire('PLAYERBANKSLOTS_CHANGED'); self.g.run_timers()
        self.assertEqual(self.get('chars["Orakh Gorehowl"].bank[2840]'), 210)

    def test_two_identical_sales_are_two_entries_and_rereading_adds_none(self):
        sale = '{sender="AH", subject="Auction successful: Rough Stone", money=614, daysLeft=29.5, invoice={type="seller",name="Rough Stone",player="",bid=646,buyout=646,deposit=100,cut=32,count=38}}'
        self.lua.execute('_mail = {%s, %s}' % (sale, sale))
        for ev in ('MAIL_SHOW', 'MAIL_INBOX_UPDATE', 'MAIL_SHOW'):
            self.g.fire(ev)
        self.assertEqual([r[1] for r in self.rows()], ['as', 'as'])
        self.lua.execute('table.remove(_mail, 1)')            # the player takes one: still two entries, no new one
        self.g.fire('MAIL_INBOX_UPDATE')
        self.lua.execute('_t = _t + 3')
        self.g.fire('MAIL_SHOW')
        self.assertEqual(len(self.rows()), 2)

    def test_a_third_identical_sale_arriving_later_is_added(self):
        sale = '{sender="AH", subject="Auction successful: Rough Stone", money=614, daysLeft=29.5, invoice={type="seller",name="Rough Stone",player="",bid=646,buyout=646,deposit=100,cut=32,count=38}}'
        self.lua.execute('_mail = {%s}' % sale)
        self.g.fire('MAIL_SHOW')
        self.lua.execute('table.insert(_mail, %s)' % sale)
        self.g.fire('MAIL_INBOX_UPDATE')
        self.assertEqual(len(self.rows()), 2)

    def test_old_dedupe_keys_from_0_1_0_still_count_as_logged(self):
        self.lua.execute('_mail = {{sender="AH", subject="s", money=7600, daysLeft=29.5, invoice={type="seller",name="Copper Ore",player="B",bid=8000,buyout=8000,deposit=300,cut=400,count=20}}}')
        minute = '%d' % ((1000000 + 29.5 * 86400) // 60)
        self.lua.execute('FMITrackerDB.seen["seller:Copper Ore:B:8000:300:400:20:%s"] = _t; FMITrackerDB.seenN = nil' % minute)
        self.g.fire('MAIL_SHOW')
        self.assertEqual(self.rows(), [])


    # ------------------------------------------------------------ the save reminder (0.4.0)
    def sale(self):
        self.lua.execute('_mail = {{sender="AH", subject="s", money=7600, daysLeft=29.5, invoice={type="seller",name="Copper Ore",player="B",bid=8000,buyout=8000,deposit=300,cut=400,count=20}}}')
        self.g.fire('MAIL_SHOW')

    def shown(self):
        return bool(self.lua.eval('FMITracker.promptShown()'))

    def popup(self):
        self.lua.execute('SlashCmdList["FMITRACKER"]("reminder popup")')

    def test_closing_the_mailbox_with_new_entries_offers_a_save_and_the_button_reloads(self):
        self.popup()
        self.g.fire('MAIL_SHOW')
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())                                  # nothing new: no plate
        self.sale()
        self.g.fire('MAIL_CLOSED')
        self.assertTrue(self.shown())
        self.assertEqual(self.lua.eval('FMITracker.unsaved()'), 1)
        self.lua.execute('FMITracker.save()')
        self.assertEqual(self.lua.eval('_reloads'), 1)

    def test_never_in_combat_or_an_instance_it_comes_back_after(self):
        self.popup()
        self.lua.execute('_combat = true')
        self.sale()
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())
        self.lua.execute('_combat = false')
        self.g.fire('PLAYER_REGEN_ENABLED')
        self.assertTrue(self.shown())
        self.lua.execute('FMITracker.later(); _instance = true; _t = _t + 1801')
        self.lua.execute('_bags = {[2770]=30}')
        self.g.fire('MERCHANT_SHOW')
        self.lua.execute('_bags = {[2770]=10}')
        self.g.setmoney(self.lua.eval('_money') + 2000)
        self.g.fire('MERCHANT_CLOSED')
        self.assertFalse(self.shown())                                  # in an instance
        self.lua.execute('_instance = false')
        self.g.fire('PLAYER_ENTERING_WORLD')
        self.assertTrue(self.shown())

    def test_later_waits_for_something_new_and_the_reminder_can_be_switched_off(self):
        self.popup()
        self.sale()
        self.g.fire('MAIL_CLOSED')
        self.lua.execute('FMITracker.later()')
        self.assertFalse(self.shown())
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())                                  # nothing new since "Later"
        self.lua.execute('SlashCmdList["FMITRACKER"]("prompt off")')
        self.lua.execute('_mail[2] = {sender="AH", subject="s2", money=500, daysLeft=29.4, invoice={type="seller",name="Copper Ore",player="C",bid=600,buyout=600,deposit=10,cut=30,count=1}}')
        self.g.fire('MAIL_SHOW')
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())
        self.assertEqual(self.lua.eval('FMITrackerDB.opt.save'), 'off')
        self.lua.execute('SlashCmdList["FMITRACKER"]("save")')
        self.assertEqual(self.lua.eval('_reloads'), 1)

    def test_the_time_of_the_write_is_kept(self):
        self.lua.execute('_t = 1234567')
        self.g.fire('PLAYER_LOGOUT')
        self.assertEqual(self.lua.eval('FMITrackerDB.savedAt'), 1234567)

    # ------------------------------------------------------------ tooltip lines from the app (0.5.0)
    def lines(self, item_id, link=None):
        """The FMI block as plain tuples: coin icons read as g/s/c, colour codes dropped, the line kind left out."""
        import re
        def plain(v):
            v = re.sub(r'\|TInterface\\MoneyFrame\\UI-(Gold|Silver|Copper)Icon[^|]*\|t', lambda m: m.group(1)[0].lower(), v)
            return re.sub(r'\|c[0-9a-fA-F]{8}|\|r', '', v)
        t = self.lua.eval('FMITracker.tooltipLines')(item_id, link)
        return [tuple(plain(v) for v in (l[1], l[2]) if v is not None) for l in t.values()]

    def app_data(self, at_offset=0):
        self.lua.execute('_t = 2000000; FMITrackerAppData = {["v"] = 1, ["house"] = "Horde #113", ["region"] = "EU", ["at"] = %d, '
                         '["items"] = {[2770] = {12550, 11000, 300, 3, 41.5}, [2589] = {50, 49, 12, 0}}, ["watch"] = {[2770] = true}, '
                         '["sold"] = {[2770] = {11900, 2000000 - 7200}}, ["bought"] = {[2589] = {45, 2000000 - 600}}}' % (2000000 - at_offset))

    def test_market_lowest_demand_own_trades_and_the_watch_mark(self):
        self.app_data()
        self.assertEqual(self.lines(2770), [('FMI min (1 min ago, 300 listed)', '1g 10s'), ('FMI real price', '1g 25s 50c'),
                                            ('FMI demand', 'sells fast · ~42/day'), ('FMI your last sale (2 h ago)', '1g 19s')])
        self.assertEqual(self.lines(2589), [('FMI min (1 min ago, 12 listed)', '49c'), ('FMI demand', 'not selling'), ('FMI your last buy (10 min ago)', '45c')])
        self.assertEqual(self.lines(999), [])
        self.lua.execute('FMITrackerAppData["items"][2770][6] = -6; FMITrackerAppData["items"][2589][6] = 1')
        self.assertIn(('FMI 24h', '-6%'), self.lines(2770))
        self.assertIn(('FMI 24h', '+1%'), self.lines(2589))

    def test_a_variant_gets_no_price_of_the_plain_item(self):
        self.app_data()
        got = self.lines(2770, '|cffffffff|Hitem:2770::::::1234:::::|h[Copper Ore]|h|r')
        self.assertFalse([l for l in got if l[0].startswith('FMI min')])
        self.assertIn(('FMI your last sale (2 h ago)', '1g 19s'), got)          # own trades still shown

    def test_old_prices_say_so_and_the_lines_can_be_switched_off(self):
        self.app_data(at_offset=8 * 3600)
        self.assertEqual(self.lines(2770)[0], ('FMI min (8 h ago, 300 listed)', '1g 10s'))
        self.assertIn('|cffff9a3d8 h ago|r', self.lua.eval('FMITracker.tooltipLines')(2770, None)[1][1])     # orange
        self.lua.execute('SlashCmdList["FMITRACKER"]("tooltip off")')
        self.assertEqual(self.lines(2770), [])

    def test_without_app_data_nothing_is_added(self):
        self.lua.execute('FMITrackerAppData = nil')
        self.assertEqual(self.lines(2770), [])

    # ------------------------------------------------------------ live auction prices you see (0.6.0)
    AH = ('C_AuctionHouse = {'
          ' GetBrowseResults = function() return _browse end,'
          ' GetNumCommoditySearchResults = function(id) return #(_comm[id] or {}) end,'
          ' GetCommoditySearchResultInfo = function(id, i) return _comm[id][i] end,'
          ' GetNumItemSearchResults = function(k) return #(_items[k.itemID] or {}) end,'
          ' GetItemSearchResultInfo = function(k, i) return _items[k.itemID][i] end }')

    def live(self, item_id):
        v = self.lua.eval('FMITracker.live')(item_id)
        return None if v is None else (v[1], v[2], v[3])

    def test_browse_commodity_and_item_results_are_kept_variants_are_not(self):
        self.lua.execute(self.AH)
        self.lua.execute('_t = 3000000; _browse = {{itemKey = {itemID = 2770, itemLevel = 10, itemSuffix = 0, battlePetSpeciesID = 0}, minPrice = 120, totalQuantity = 340},'
                         '{itemKey = {itemID = 15000, itemLevel = 30, itemSuffix = 1234, battlePetSpeciesID = 0}, minPrice = 999, totalQuantity = 1}}')
        self.g.fire('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
        self.assertEqual(self.live(2770), (120, 340, 3000000))
        self.assertIsNone(self.live(15000))                                 # a suffix variant
        self.lua.execute('_t = 3000060; _comm = {[2770] = {{unitPrice = 118, quantity = 20}, {unitPrice = 125, quantity = 300}}}')
        self.g.fire('COMMODITY_SEARCH_RESULTS_UPDATED', 2770)
        self.assertEqual(self.live(2770), (118, 320, 3000060))
        self.lua.execute('_items = {[2589] = {{buyoutAmount = 600, quantity = 10}, {buyoutAmount = 55, quantity = 1}, {bidAmount = 1, quantity = 1}}}')
        self.lua.execute('_key = {itemID = 2589, itemLevel = 5, itemSuffix = 0, battlePetSpeciesID = 0}')
        self.g.fire('ITEM_SEARCH_RESULTS_UPDATED', self.lua.eval('_key'))
        self.assertEqual(self.live(2589), (55, 11, 3000060))                 # the lowest per unit; a bid-only lot left out

    def test_the_live_price_leads_the_tooltip_and_needs_no_app_data(self):
        self.lua.execute(self.AH)
        self.lua.execute('FMITrackerAppData = nil; _t = 3000000; _browse = {{itemKey = {itemID = 2770, itemSuffix = 0, battlePetSpeciesID = 0}, minPrice = 12550, totalQuantity = 340}}')
        self.g.fire('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
        self.lua.execute('_t = 3000120')
        self.assertEqual(self.lines(2770), [('FMI last seen (2 min ago, 340 listed)', '1g 25s 50c')])
        self.app_data()                                                       # older app data: the live line leads
        self.lua.execute('_t = 3000120')
        self.assertEqual(self.lines(2770)[0], ('FMI last seen (2 min ago, 340 listed)', '1g 25s 50c'))
        self.lua.execute('FMITrackerAppData["at"] = 3000100')                 # newer app data: both lines, what you saw first
        self.assertEqual(self.lines(2770)[:3], [('FMI last seen (2 min ago, 340 listed)', '1g 25s 50c'),
                                                ('FMI min (1 min ago, 300 listed)', '1g 10s'), ('FMI real price', '1g 25s 50c')])

    def test_live_prices_survive_a_reload_and_old_ones_hide(self):
        self.lua.execute(self.AH)
        self.lua.execute('_t = 3000000; _browse = {{itemKey = {itemID = 2770, itemSuffix = 0, battlePetSpeciesID = 0}, minPrice = 120, totalQuantity = 5}}')
        self.g.fire('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
        self.g.fire('ADDON_LOADED', 'FMITracker')                             # the saved table is read again after a reload
        self.assertEqual(self.live(2770), (120, 5, 3000000))
        self.lua.execute('FMITrackerAppData = nil; _t = 3000000 + 7 * 3600')
        self.assertEqual(self.lines(2770), [('FMI last seen (7 h ago, 5 listed)', '1s 20c')])
        self.lua.execute('_t = 3000000 + 25 * 3600')
        self.assertEqual(self.lines(2770), [])                                # older than a day: hidden

    # ------------------------------------------------------------ quiet saving (0.7.0)
    def btn(self):
        return bool(self.lua.eval('FMITracker.buttonShown()'))

    def test_by_default_a_button_under_the_open_window_and_no_plate(self):
        self.assertEqual(self.lua.eval('FMITrackerDB.opt.save'), 'button')
        self.g.fire('MAIL_SHOW')
        self.assertFalse(self.btn())                                    # nothing unsaved yet
        self.sale()
        self.assertTrue(self.btn())
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.btn())
        self.assertFalse(self.shown())                                  # no plate pops up
        self.lua.execute('_bags = {[2770]=30}')
        self.g.fire('MERCHANT_SHOW')
        self.assertTrue(self.btn())                                     # the mail entry is still unsaved
        self.g.fire('MERCHANT_CLOSED')
        self.assertFalse(self.btn())

    def test_the_popup_after_later_waits_30_minutes_and_off_shows_nothing(self):
        self.popup()
        self.sale()
        self.g.fire('MAIL_CLOSED')
        self.assertTrue(self.shown())
        self.lua.execute('FMITracker.later()')
        self.lua.execute('_mail[2] = {sender="AH", subject="s2", money=500, daysLeft=29.4, invoice={type="seller",name="Copper Ore",player="C",bid=600,buyout=600,deposit=10,cut=30,count=1}}')
        self.g.fire('MAIL_SHOW')
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())                                  # something new, but within 30 min
        self.lua.execute('_t = _t + 1801')
        self.g.fire('MAIL_SHOW')
        self.g.fire('MAIL_CLOSED')
        self.assertTrue(self.shown())
        self.lua.execute('SlashCmdList["FMITRACKER"]("reminder off")')
        self.assertFalse(self.shown())
        self.g.fire('MAIL_SHOW')
        self.assertFalse(self.btn())

    def test_an_old_switch_off_stays_off(self):
        self.lua.execute('FMITrackerDB.opt = {prompt = false}; FMITrackerDB.opt.save = nil')
        self.g.fire('ADDON_LOADED', 'FMITracker')
        self.assertEqual(self.lua.eval('FMITrackerDB.opt.save'), 'off')


if __name__ == '__main__':
    unittest.main()
