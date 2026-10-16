"""
Generate SSCMPS-Migration-v1.xlsx — the workbook the Treasurer fills
and returns for import.

Pre-populated with members and loans already extracted from the
Treasurer's source files. Cells flagged amber in the Notes column
need the Treasurer's attention. Empty cells in required columns must
be supplied before import.

Run:  python generate_migration_template.py
Out:  SSCMPS-Migration-v1.xlsx
"""

import re
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

# ---------------------------------------------------------------- helpers
def norm_phone(raw):
    if raw is None or raw == '':
        return ''
    s = re.sub(r'\D', '', str(raw))
    if not s:
        return ''
    if len(s) == 10:
        s = '0' + s
    return s

HDR_FILL  = PatternFill("solid", fgColor="D9E1F2")
FLAG_FILL = PatternFill("solid", fgColor="FFF2CC")
HDR_FONT  = Font(bold=True)
TITLE_FONT = Font(bold=True, size=14)

# ---------------------------------------------------------------- data
# (reg, first, middle, last, email, phone, admission, first_contrib,
#  standing, savings, status, notes)
MEMBERS = [
    ("0001","Mohammed","Yusuf","Gana","mygddoko721@gmail.com","8082365356","1999-03-01","1999-03-01",30000,2113966,"Active",""),
    ("0002","Salam","Gabriel","Rahim","gabriel08054760054@gmail.com","8034726643","1999-03-01","1999-03-01",20000,1496405,"Active",""),
    ("0003","Enoch","Ndabenu","Gana","drenochgana@gmail.com","8059281250","1999-03-01","1999-03-01",40000,2191512,"Active","Source had savings '21`91512' — interpreted as 2191512. Verify."),
    ("0004","Elijah","Baba","Santali","elijahsantali@yahoo.com","8052318505","1999-03-01","1999-03-01",60000,2643082,"Active",""),
    ("0005","Abd-Elfatai","","Mohammed","abdelfataimohammed@yahoo.com","8054886929","1999-03-01","1999-03-01",20000,662517,"Active",""),
    ("0006","Mubo","Deborah","Solomon","mubosolomon@gmail.com","8077265769","1999-03-01","1999-03-01",10000,204005,"Active",""),
    ("0007","James","Bake","Kolo","jamesbakolo@gmail.com","7037769990","1999-03-01","1999-03-01",100000,3346312.5,"Active",""),
    ("0008","Olusola","","Emmanuel","sola2015.oe@gmail.com","8075339985","1999-03-01","1999-03-01",30000,4099109,"Active",""),
    ("0009","Jiman","","Chado","jimanchado7@gmail.com","8032297209","1999-04-01","1999-04-01",20000,2022643,"Active",""),
    ("0010","Obadiah","","Jiya","jiyaobadiah@gmail.com","8077265769","2000-01-01","2000-01-01",10000,1123199.5,"Active","Phone same as 0006 — verify."),
    ("0011","Amos","Ndarubu","Tsado","amosesndarubu@gmail.com","0803 292 0909","2000-01-01","2000-01-01",30000,1992904,"Active",""),
    ("0012","Victoria","Tani","Gana","vic66gana@gmail.com","8051072108","2002-01-01","2002-01-01",10000,1387946,"Active",""),
    ("0013","Paul","","Gana","ganapaul09@gmail.com","8057747916","2002-01-01","2002-01-01",20000,1447420,"Active",""),
    ("0014","Helen","James","Kolo","Helenbake04@gmail.com","7033774666","2002-01-01","2002-01-01",100000,2399300,"Active",""),
    ("0015","Silas","Ndalati","Jiya","silasjiya01@gmail.com","7055139838","2002-01-01","2002-01-01",20000,979742,"Active",""),
    ("0016","Juliana","Simon","Enock","julianashalom3@gmail.com","8058466073","2002-01-01","2002-01-01",20000,2297600,"Active",""),
    ("0017","Gideon","","Tsado","tsadogideon@gmail.com","8033611607","2003-01-01","2003-01-01",10000,1024635,"Active",""),
    ("0018","Shaba","Alhaji","Mohammed","shabamohammed354@gmail.com","7035868087","2003-01-01","2003-01-01",10000,959750,"Active",""),
    ("0019","Mamman","Zaccheaus","N.","zacksmamman36@gmail.com","7030565736","2003-01-01","2003-01-01",15000,1890190,"Active",""),
    ("0020","Victoria","","Karimu","victoriakarimu@gmail.com","8051105839","2003-01-01","2003-01-01",20000,3905614,"Active",""),
    ("0021","Christy","Nnadzwa","Yisa","christytsado1967@gmail.com","7031145051","2003-07-01","2003-07-01",10000,1260888,"Active",""),
    ("0022","ASUP","","ASUP","Info@asupnigerpoly@gmail.com","8031526602","2004-07-01","2004-07-01",50000,3701606.5,"Active","Email malformed. Institutional account — confirm correct address."),
    ("0023","Daniel","O","Adewara","adewaraolanrewaju@gmail.com","8053306371","2005-01-01","2005-01-01",50000,3175420,"Active",""),
    ("0024","Oladele","","Campbell","","","2005-01-01","2005-01-01",20000,1175261,"Active","MISSING email and phone."),
    ("0025","Garba","Musa","Doko","yagarba724@gmail.com","8033560813","2010-01-01","2010-01-01",20000,2768800,"Active",""),
    ("0026","Sarah","Kiatswa","Jiya","jiyasarahk@gmail.com","8054173593","2010-01-01","2010-01-01",10000,960585,"Active",""),
    ("0027","Hassan","","Ndafatima","hassannda01@gmail.com","8059199226","2010-01-01","2010-01-01",20000,951010,"Active",""),
    ("0028","John","Jiya","Ahmed","ahmedjohn290@gmail.com","7033587268","2010-01-01","2010-01-01",20000,382650,"Active",""),
    ("0029","Lucy","Fatima","Olusola","lucyemma366@gmail.com","8131593008","2010-01-01","2010-01-01",20000,2404825,"Active",""),
    ("0030","Na'omi","","Sallah","naomisallah5@gmail.com","8065686857","2010-01-01","2010-01-01",20000,412250,"Active","Source had trailing '.' on email — stripped."),
    ("0031","Joshua","Gana","Gara","joshuagara2@gmail.com","8036028243","2010-01-01","2010-01-01",60000,4500410,"Active",""),
    ("0032","Peter","","Bake","bakepeters@gmail.com","7063887148","2011-01-01","2011-01-01",20000,1441355,"Active",""),
    ("0033","Ezekiel","Tsado","Saba","ezekieltsadosaba@gmail.com","8051286441","2011-01-01","2011-01-01",10000,1474050,"Active",""),
    ("0034","Faith","","Jiya","kakawoyeyisa555@gmail.com","8065311382","2011-01-01","2011-01-01",20000,1454550,"Active",""),
    ("0035","Haruna","Nma Alh","Salihu","harunasalihu68@gmail.com","8059282012","2011-01-01","2011-01-01",20000,2275500,"Active",""),
    ("0036","Talatu","Saidu","Bosso","talatusaidu@yahoo.com","8069464395","2011-01-01","2011-01-01",30000,1730055,"Active",""),
    ("0037","David","","Adams","davidadsaguma@gmail.com","8053283445","2011-01-01","2011-01-01",50000,366777.25,"Active",""),
    ("0038","Abubakar","A.","Nagya","abubakarnagya4@gmail.com","8126144818","2016-01-01","2016-01-01",30000,424366,"Active",""),
    ("0039","Usman","D.","Mohammed","usmandanladimohammed@mail.com","7030888048","2016-01-01","2016-01-01",10000,370300,"Active","Email domain 'mail.com' — verify, likely gmail.com."),
    ("0040","Maryam","","Sulaiman","suleimanmaryam30@gail.com","8054133195","2016-01-01","2016-01-01",20000,877650,"Active","Email domain 'gail.com' — likely gmail.com."),
    ("0041","David","Yisa","Gana","Davidganay35@gmail.com","8120144640","2016-01-01","2016-01-01",10000,311500,"Active",""),
    ("0042","James","Tsado","Gana","","","2016-01-01","2016-01-01",10000,664400,"Active","MISSING email and phone."),
    ("0043","Oliver","","Moses","bestquantz2024@gmail.com","8057461915","2016-01-01","2016-01-01",20000,911800,"Active",""),
    ("0044","Peter","Jiya","Nmadu","pjnmadu@gmail.com","8057461915","2016-01-01","2016-01-01",20000,47500,"Active","Phone same as 0043 — verify."),
    ("0045","Jiya","Adama","Enoch","adamajiya@gmail.com","8064511076","2016-01-01","2016-01-01",20000,2220000,"Active",""),
    ("0046","Abdullahi","","Muhammad","lddabdul862@gmail.com","8039677801","2016-01-01","2016-01-01",20000,2157500,"Active",""),
    ("0047","Agnes","N.","Oyetunji","agnesoyetunji@gmail.com","9117699838","2016-01-01","2016-01-01",20000,1104875,"Active","Phone is 10 digits — normalized to 09117699838. Verify."),
    ("0048","Rachael","Nnadzwa","Majin","rachealmajin@gmail.com","8060989804","2016-01-01","2016-01-01",20000,1126810,"Active",""),
    ("0049","Mohammed","Nura","Adamu","nuramaijamaa@gmail.com","8066027919","2016-01-01","2016-01-01",10000,898200,"Active",""),
    ("0050","Ruth","Aduwa","Santali","ruthsantali19@gmail.com","8058445676","2020-01-01","2020-01-01",10000,455500,"Active",""),
    ("0051","Fatima","Talatu","Mohammed","fatitalatu@gmail.com","7032646693","2020-01-01","2020-01-01",20000,819500,"Active",""),
    ("0052","Habiba","","Ibrahim","habibsalam141@gmail.com","8138546764","2022-01-01","2022-01-01",20000,1434800,"Active",""),
    ("0053","Deborah","Teni","Bake","tsadodebby@gmail.com","7069623908","2022-01-01","2022-01-01",20000,463000,"Active",""),
    ("0054","Ibrahim","","Mohammed","bmkhaleeel@gmail.com","8135711660","2022-01-01","2022-01-01",15000,953895,"Active",""),
    ("0055","Shehu","Isa","Danlami","shehuisahdanlami@gmail.com","8066664694","2022-01-01","2022-01-01",150000,4448090,"Active","Standing contribution 150,000 — verify (unusually high)."),
    ("0056","Salamatu","A","Abdulkadir","salamatu4kasim@gmail.com","8077215601","2022-01-01","2022-01-01",10000,390000,"Active",""),
    ("0057","Nicodemus","","Ishaku","nicodemusishaku2016@gmail.com","8163406464","2022-01-01","2022-01-01",10000,509000,"Active",""),
    ("0058","Balarabe","Musa","Muhammad","balamah100@gmail.com","8067570013","2022-01-01","2022-01-01",20000,740250,"Active",""),
    ("0059","Ibrahim","Umar","Kontagora","ibrosoftuk@yahoo.com","8051302033","2022-07-01","2022-07-01",26090000,500000,"Active","Standing contribution '26090000' — likely typo. Verify."),
    ("0060","Mantau","Alhaji","Mamman","hammadshattima@gmail.com","8035968318","2022-07-01","2022-07-01",30000,251500,"Active",""),
    ("0061","Jatau","Elkana","Ayuba","elkanahayubaj@gmail.com","8050794704","2026-01-01","2026-01-01",50000,160000,"Active",""),
    ("0062","Danladi","Grace","Gajere","shandygracee@gmail.com","8135709330","2026-01-01","2026-01-01",20000,100000,"Active",""),
    ("0063","Kolo","Olusayo","Oyeronke","sayosunday123@gmail.com","8060163525","2026-01-01","2026-01-01",30000,270000,"Active",""),
    ("0064","Ismaila","Batengi","Abubakar","batengi111@gmail.com","8037355290","2026-01-01","2026-01-01",20000,127500,"Active",""),
    ("0065","Emmanuel","Gana","Legbo","emmanuellegbo@gmail.com","8035916868","2026-01-01","2026-01-01",15000,82500,"Active",""),
    ("0066","Ibrahim","Abubakar","Abdullahi","danmaihura16@gmail.com","8058020930","2026-01-01","2026-01-01",50000,337500,"Active",""),
    ("0067","Sunday","Makun","Christopher","Krismakun@gmail.com","8035965607","2026-01-01","2026-01-01",100000,600000,"Active",""),
    ("0068","Gussoro","Talatu","Rose","rosetalatu055@gmail.com","8024951903","2026-01-01","2026-01-01",30000,217500,"Active",""),
    ("0069","James","Umar","Jibrin","jamesjibrin070@gmail.com","7068005790","2026-01-01","2026-01-01",10000,37500,"Active","Source had space in email — removed."),
    ("0070","Gana","Amina Baba","Jibrin","aminababajibril0@gmail.com","8167612886","2026-01-01","2026-01-01",20000,180000,"Active",""),
    ("0071","Winnifred","W","Tsado","winifredtsado3@gmail.com","8063681565","2026-01-01","2026-01-01",10000,69000,"Active",""),
    ("0072","Jacob","Yisa","Tsado","jacobyisa2@gmail.com","7039760670","2026-01-01","2026-01-01",10000,37500,"Active",""),
    ("0073","Sulieman","D","Abdullahi","abdullahisuleimand73@gmail.com","8030755934","2026-02-01","2026-02-01",10000,80000,"Active",""),
    ("0074","Thompson","","Idike","thompsonidike@gmail.com","8036845278","2026-03-01","2026-03-01",10000,70000,"Active",""),
]

# (reg, ref, product, principal, disb, term, total_repay, repaid, outstanding,
#  monthly, paid, remaining, status, notes)
LOANS = [
    ("0001","LOAN/LT/001","Long-Term",1000000,"2026-09-08",24,1050000,0,1050000,43750,0,24,"Active",""),
    ("0002","LOAN/LT/002","Long-Term",3000000,"2022-09-08",24,3303900,2237000,1066900,137670,18,6,"Active",""),
    ("0003","LOAN/LT/003","Long-Term",1200000,"2026-09-01",24,1260000,0,1260000,110000,0,24,"Active",""),
    ("0004","LOAN/LT/004","Long-Term",4000000,"2023-02-10",24,4324650,2727400,1597250,180200,15,9,"Active",""),
    ("0007","LOAN/LT/005","Long-Term",5500000,"2023-08-03",24,5775000,3920000,1856000,240625,16,8,"Active",""),
    ("0009","LOAN/LT/006","Long-Term",3500000,"2024-05-06",24,3840000,1983600,1856400,123600,16,8,"Active",""),
    ("0011","LOAN/LT/007","Long-Term",2500000,"2024-10-10",24,2716300,2488500,113300,113200,22,2,"Active",""),
    ("0012","LOAN/LT/008","Long-Term",2500000,"2023-08-03",24,2818500,2350000,468500,117438,20,4,"Active",""),
    ("0013","LOAN/LT/009","Long-Term",3000000,"2026-02-11",24,3365850,700500,2665350,140244,5,19,"Active",""),
    ("0015","LOAN/LT/010","Long-Term",1500000,"2024-03-04",24,1646250,1293200,353050,68600,20,4,"Active",""),
    ("0016","LOAN/LT/011","Long-Term",3000000,"2025-08-04",24,3253650,1959000,1294650,136000,14,10,"Active",""),
    ("0017","LOAN/LT/012","Long-Term",3000000,"2026-06-06",24,3432900,186400,3296500,1430377,2,22,"Active","Monthly instalment 1,430,377 looks wrong — likely typo. Verify."),
    ("0018","LOAN/LT/013","Long-Term",1000000,"2026-04-06",24,1061250,195000,866250,44219,5,19,"Active",""),
    ("0023","LOAN/LT/014","Long-Term",2500000,"2026-02-11",24,2625000,659000,1966000,109375,6,18,"Active",""),
    ("0024","LOAN/LT/015","Long-Term",1200000,"2024-02-02",24,1260000,988900,271100,52500,19,5,"Active",""),
    ("0025","LOAN/LT/016","Long-Term",2000000,"2026-03-10",24,2100000,599000,1501000,87500,6,18,"Active",""),
    ("0032","LOAN/LT/017","Long-Term",2500000,"2025-09-01",24,2766600,1043000,1723600,115275,9,15,"Active",""),
    ("0034","LOAN/LT/018","Long-Term",1200000,"2025-03-26",24,1260000,877500,382500,52500,17,7,"Active",""),
    ("0035","LOAN/LT/019","Long-Term",2000000,"2026-03-30",24,2100000,261500,1838500,87500,3,21,"Active",""),
    ("0039","LOAN/LT/020","Long-Term",300000,"2026-08-14",24,315000,12200,302800,13125,1,23,"Active",""),
    ("0040","LOAN/LT/021","Long-Term",1200000,"2023-02-02",24,1307100,1236000,71100,54500,22,2,"Active",""),
    ("0047","LOAN/LT/022","Long-Term",2000000,"2026-07-01",24,2213850,184000,2029850,92244,2,22,"Active",""),
    ("0048","LOAN/LT/023","Long-Term",2000000,"2025-03-26",24,2237250,837971,1399279,93219,9,15,"Active",""),
    ("0049","LOAN/LT/024","Long-Term",500000,"2025-01-27",24,525000,415625,109375,21875,19,5,"Active",""),
    ("0050","LOAN/LT/025","Long-Term",500000,"2026-03-30",24,525000,65000,460000,21875,3,21,"Active",""),
    ("0052","LOAN/LT/026","Long-Term",2000000,"2025-10-08",24,2211450,736160,1475290,92145,8,16,"Active",""),
    ("0053","LOAN/LT/027","Long-Term",500000,"2025-09-01",24,547500,206000,341500,22813,9,15,"Active",""),
    ("0002","LOAN/EM/001","Emergency",250000,"2024-07-10",10,275000,220000,55000,27500,8,2,"Active",""),
    ("0012","LOAN/EM/002","Emergency",500000,"2026-09-01",10,550000,0,550000,55000,0,10,"Active",""),
    ("0028","LOAN/EM/003","Emergency",150000,"2026-08-14",10,165000,24000,141000,16500,1,9,"Active",""),
    ("0033","LOAN/EM/004","Emergency",200000,"2026-01-09",10,220000,131000,89000,22000,6,4,"Active","Monthly instalment missing in source — inferred from pattern."),
    ("0036","LOAN/EM/005","Emergency",400000,"2026-10-02",10,440000,0,440000,44000,0,10,"Active",""),
    ("0038","LOAN/EM/006","Emergency",200000,"2026-09-11",10,220000,21000,199000,22000,1,9,"Active",""),
    ("0041","LOAN/EM/007","Emergency",60000,"2026-08-14",10,66000,19000,47000,6600,1,9,"Active",""),
    ("0043","LOAN/EM/008","Emergency",300000,"2026-08-12",10,330000,32000,298000,33000,1,9,"Active",""),
    ("0002","LOAN/ST/001","Short-Term",300000,"2026-04-15",10,350000,180000,170000,35000,5,5,"Active","Disbursement date estimated — Treasurer to confirm."),
]

# ---------------------------------------------------------------- workbook
wb = Workbook()

def write_sheet(name, headers, rows, flag_col_name, notes_in_last=True):
    ws = wb.create_sheet(name)
    ws.append(headers)
    for c in range(1, len(headers) + 1):
        cell = ws.cell(row=1, column=c)
        cell.fill = HDR_FILL
        cell.font = HDR_FONT
        cell.alignment = Alignment(vertical="center", wrap_text=True)
    for r in rows:
        ws.append(r)
    # flag notes column
    if flag_col_name in headers:
        idx = headers.index(flag_col_name) + 1
        for row_i in range(2, ws.max_row + 1):
            if ws.cell(row=row_i, column=idx).value:
                ws.cell(row=row_i, column=idx).fill = FLAG_FILL
    # auto-width
    for i, h in enumerate(headers, start=1):
        max_len = len(str(h))
        for row_i in range(2, ws.max_row + 1):
            v = ws.cell(row=row_i, column=i).value
            if v is not None:
                max_len = max(max_len, len(str(v)))
        ws.column_dimensions[get_column_letter(i)].width = min(max_len + 2, 45)
    ws.freeze_panes = "A2"
    return ws

# ---- Instructions -----------------------------------------------------------
ws = wb.active
ws.title = "Instructions"
INSTR = [
    "SSCMPS MEMBER MIGRATION WORKBOOK — v1",
    "Niger State Polytechnic Senior Staff Cooperative & Multipurpose Society Ltd.",
    "",
    "For completion by the Treasurer before migration to the digital system.",
    "",
    "STATUS OF THIS WORKBOOK",
    "• Members sheet  — pre-filled from your earlier submission.",
    "• Loans sheet    — pre-filled from your earlier submission.",
    "• Cells highlighted AMBER in the Notes column need your review.",
    "• Cells highlighted AMBER that are EMPTY need your input.",
    "",
    "WHAT TO DO",
    "1. Review every amber-highlighted cell in the Members sheet.",
    "   Correct anything wrong, fill anything missing.",
    "2. Review every amber-highlighted cell in the Loans sheet.",
    "   Confirm the loans are still active as of cutover day.",
    "3. Complete the Self-check sheet.",
    "4. Return the workbook.",
    "",
    "DATE FORMAT",
    "All dates YYYY-MM-DD (year first). Example: 2026-10-03 = 3rd October 2026.",
    "Do NOT use DD/MM/YYYY or MM/DD/YYYY.",
    "",
    "AMOUNT FORMAT",
    "Naira, no commas or symbols. Example: 145000 (not ₦145,000).",
    "",
    "MEMBERS SHEET — 12 columns",
    "registration_number — Cooperative member number. 4 digits, zero-padded.",
    "first_name / middle_name / last_name — as they appear in the manual register.",
    "email — REQUIRED. This is where the login invitation is sent.",
    "phone — 11-digit Nigerian format, e.g. 08031234567.",
    "admission_date — Date the member joined.",
    "first_contribution_date — Date of the member's very first contribution.",
    "standing_contribution_amount — Current monthly contribution (min 10000).",
    "savings_balance — Current savings as at cutover day. Must match the manual ledger.",
    "status — One of: Active, Suspended, Terminated, Exited.",
    "notes — Anything for the Secretary to know. Not imported.",
    "",
    "LOANS SHEET — 14 columns",
    "One row per ACTIVE loan. Fully paid loans are excluded.",
    "registration_number — Must match a row on the Members sheet exactly.",
    "loan_reference_manual — Reference from the manual ledger.",
    "product_type — One of: Long-Term, Short-Term, Emergency, Essential Commodity.",
    "principal_amount — Original amount disbursed.",
    "disbursement_date — When the loan was given to the member.",
    "term_months — Original agreed term.",
    "total_repayable — Principal + interest + any application fee. Exact.",
    "total_repaid — Amount already paid by cutover day.",
    "outstanding_balance — Must equal total_repayable - total_repaid.",
    "monthly_instalment — Agreed monthly amount.",
    "instalments_paid — Number of instalments already paid.",
    "instalments_remaining — Must equal term_months - instalments_paid.",
    "status — Active or Defaulted.",
    "notes — Anything for the Secretary to know.",
    "",
    "WHAT HAPPENS AFTER YOU SEND THIS",
    "1. Every member is created in the new system with their savings balance.",
    "2. Each active loan is recorded with its schedule and outstanding balance.",
    "3. Every member receives an email inviting them to set their password.",
    "4. Members complete their own profile (department, position, next of kin, staff ID) on first login.",
    "5. Once every member has logged in, the manual ledger is retired.",
    "",
    "SUPPORT",
    "If any item is unclear, ask before guessing. The cost of a wrong value is a wrong",
    "figure on a member's statement, which is worse than a delayed migration.",
]
for line in INSTR:
    ws.append([line])
ws.column_dimensions["A"].width = 110
ws["A1"].font = TITLE_FONT

# ---- Members ---------------------------------------------------------------
M_HDR = ["registration_number *","first_name *","middle_name","last_name *","email *",
         "phone","admission_date *","first_contribution_date *",
         "standing_contribution_amount *","savings_balance *","status *","notes"]
M_ROWS = [[reg, fn, mn, ln, em, norm_phone(ph), adm, fc, stand, sav, st, note]
          for (reg,fn,mn,ln,em,ph,adm,fc,stand,sav,st,note) in MEMBERS]
write_sheet("Members", M_HDR, M_ROWS, "notes")

# ---- Loans ------------------------------------------------------------------
L_HDR = ["registration_number *","loan_reference_manual *","product_type *",
         "principal_amount *","disbursement_date *","term_months *",
         "total_repayable *","total_repaid *","outstanding_balance *",
         "monthly_instalment *","instalments_paid *","instalments_remaining *",
         "status *","notes"]
L_ROWS = [[reg,ref,prod,prin,disb,term,tr,rep,out,mon,paid,rem,st,note]
          for (reg,ref,prod,prin,disb,term,tr,rep,out,mon,paid,rem,st,note) in LOANS]
write_sheet("Loans", L_HDR, L_ROWS, "notes")

# ---- Data validation on status columns -------------------------------------
members_ws = wb["Members"]
status_col = M_HDR.index("status *") + 1
dv_m = DataValidation(type="list",
                      formula1='"Active,Suspended,Terminated,Exited"',
                      allow_blank=False)
members_ws.add_data_validation(dv_m)
dv_m.add(f"{get_column_letter(status_col)}2:{get_column_letter(status_col)}{len(M_ROWS)+1}")

loans_ws = wb["Loans"]
lstatus_col = L_HDR.index("status *") + 1
dv_l = DataValidation(type="list",
                      formula1='"Active,Defaulted"',
                      allow_blank=False)
loans_ws.add_data_validation(dv_l)
dv_l.add(f"{get_column_letter(lstatus_col)}2:{get_column_letter(lstatus_col)}{len(L_ROWS)+1}")

# ---- Self-check -------------------------------------------------------------
ws = wb.create_sheet("Self-check")
SC = [
    ["Self-check — please complete before returning this workbook.","",""],
    ["Check","Expected","Your answer"],
    ["Members rows",74,len(M_ROWS)],
    ["Loans rows","from your records",len(L_ROWS)],
    ["Members with status ≠ Active","(from your records)",""],
    ["Members with savings_balance < 0","0",""],
    ["Members with standing_contribution < 10000","0",""],
    ["Every email appears only once","True",""],
    ["Every registration_number appears only once","True",""],
    ["Every loan reconciles: total_repaid + outstanding = total_repayable","True",""],
    ["Every loan reconciles: paid + remaining = term_months","True",""],
    ["Every loan's registration_number exists on Members sheet","True",""],
    ["","",""],
    ["Sign-off","",""],
    ["Role","Name","Date"],
    ["Treasurer","",""],
    ["Secretary (received)","",""],
    ["Chairman (acknowledged)","",""],
]
for row in SC:
    ws.append(row)
ws["A1"].font = TITLE_FONT
for c in "ABC":
    ws.column_dimensions[c].width = 55 if c == "A" else 25
for r in (2, 14):
    for c in "ABC":
        ws[f"{c}{r}"].font = Font(bold=True)
        ws[f"{c}{r}"].fill = HDR_FILL

# ---------------------------------------------------------------- save
OUT = "SSCMPS-Migration-v1.xlsx"
wb.save(OUT)
print(f"Written: {OUT}")
print(f"  Members: {len(M_ROWS)}")
print(f"  Loans:   {len(L_ROWS)}")