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


if __name__ == '__main__':
    unittest.main()
