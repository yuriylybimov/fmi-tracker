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

    def test_closing_the_mailbox_with_new_entries_offers_a_save_and_the_button_reloads(self):
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
        self.lua.execute('_combat = true')
        self.sale()
        self.g.fire('MAIL_CLOSED')
        self.assertFalse(self.shown())
        self.lua.execute('_combat = false')
        self.g.fire('PLAYER_REGEN_ENABLED')
        self.assertTrue(self.shown())
        self.lua.execute('FMITracker.later(); _instance = true')
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
        self.assertFalse(self.lua.eval('FMITrackerDB.opt.prompt'))
        self.lua.execute('SlashCmdList["FMITRACKER"]("save")')
        self.assertEqual(self.lua.eval('_reloads'), 1)

    def test_the_time_of_the_write_is_kept(self):
        self.lua.execute('_t = 1234567')
        self.g.fire('PLAYER_LOGOUT')
        self.assertEqual(self.lua.eval('FMITrackerDB.savedAt'), 1234567)


if __name__ == '__main__':
    unittest.main()
