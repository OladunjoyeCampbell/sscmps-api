// scripts/migration/generate-template.mjs
//
// Generates the SSCMPS member migration workbook (.xlsx) for the Treasurer.
//
// Usage:
//   node scripts/migration/generate-template.mjs
//   node scripts/migration/generate-template.mjs --out path\to\custom.xlsx
//
// Output: data/SSCMPS-Migration-Template-v2.xlsx

import ExcelJS from 'exceljs';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const outFlagIdx = args.indexOf('--out');
const OUT = outFlagIdx !== -1
  ? args[outFlagIdx + 1]
  : path.join('data', 'SSCMPS-Migration-Template-v2.xlsx');

fs.mkdirSync(path.dirname(OUT), { recursive: true });

const wb = new ExcelJS.Workbook();
wb.creator = 'SSCMPS Migration Tool';
wb.lastModifiedBy = 'SSCMPS Migration Tool';
wb.created = new Date();
wb.modified = new Date();

// ─── Styles ──────────────────────────────────────────────────────────
const GREEN = 'FF0A5C36';
const GREEN_LIGHT = 'FFE8F3EC';
const YELLOW = 'FFFFF9C4';
const GREY = 'FFF3F4F6';
const BORDER_COLOR = 'FFD1D5DB';
const DATE_FMT = 'dd-mmm-yyyy';

const headerFill = { type: 'pattern', pattern: 'solid', fgColor: { argb: GREEN } };
const headerFont = { bold: true, color: { argb: 'FFFFFFFF' }, size: 11 };
const exampleFill = { type: 'pattern', pattern: 'solid', fgColor: { argb: YELLOW } };
const noteFill = { type: 'pattern', pattern: 'solid', fgColor: { argb: GREY } };
const sectionFill = { type: 'pattern', pattern: 'solid', fgColor: { argb: GREEN_LIGHT } };
const titleFont = { bold: true, size: 16, color: { argb: GREEN } };
const sectionFont = { bold: true, size: 12, color: { argb: GREEN } };
const noteFont = { italic: true, color: { argb: 'FF666666' }, size: 10 };
const bodyFont = { size: 11 };

const thinBorder = {
  top: { style: 'thin', color: { argb: BORDER_COLOR } },
  left: { style: 'thin', color: { argb: BORDER_COLOR } },
  bottom: { style: 'thin', color: { argb: BORDER_COLOR } },
  right: { style: 'thin', color: { argb: BORDER_COLOR } },
};

function applyHeaderStyle(row) {
  row.eachCell({ includeEmpty: false }, (cell) => {
    cell.fill = headerFill;
    cell.font = headerFont;
    cell.alignment = { vertical: 'middle', horizontal: 'left', wrapText: true };
    cell.border = thinBorder;
  });
  row.height = 24;
}

function applyExampleStyle(row) {
  row.eachCell({ includeEmpty: false }, (cell) => {
    cell.fill = exampleFill;
    cell.border = thinBorder;
    cell.font = bodyFont;
  });
}

function applyBodyBorder(row) {
  row.eachCell({ includeEmpty: true }, (cell) => {
    cell.border = thinBorder;
  });
}

function setDateColumnFormat(ws, letter) {
  ws.getColumn(letter).numFmt = DATE_FMT;
}

// ═════════════════════════════════════════════════════════════════════
// SHEET 1 — Instructions
// ═════════════════════════════════════════════════════════════════════
{
  const ws = wb.addWorksheet('Instructions', { properties: { tabColor: { argb: GREEN } } });
  ws.columns = [{ width: 105 }];
  ws.views = [{ showGridLines: false }];

  const lines = [
    { t: 'SSCMPS MEMBER MIGRATION TEMPLATE — v2', f: titleFont },
    { t: 'Niger State Polytechnic Senior Staff Cooperative & Multipurpose Society Ltd.', f: { italic: true, size: 11, color: { argb: 'FF666666' } } },
    { t: '' },
    { t: 'For completion by the Treasurer before migration to the digital system.', f: { size: 11 } },
    { t: '' },
    { t: 'Sheets in this workbook', f: sectionFont },
    { t: '1. Instructions      — this page. Read before filling.', f: bodyFont },
    { t: '2. Members          — one row per member (all 74 members).', f: bodyFont },
    { t: '3. Contributions    — one row per contribution for the last 12 completed months.', f: bodyFont },
    { t: '4. Loans            — one row per ACTIVE loan (a member with 2 loans = 2 rows).', f: bodyFont },
    { t: '5. Self-check       — numbers you should verify before submitting.', f: bodyFont },
    { t: '' },
    { t: 'DATE FORMAT — please read', f: sectionFont },
    { t: 'All dates in this workbook must be entered as YYYY-MM-DD (year first).', f: { ...bodyFont, bold: true } },
    { t: '   Example:  2026-10-03  means 3rd October 2026.', f: bodyFont },
    { t: 'Do NOT use DD/MM/YYYY or MM/DD/YYYY — they mean different things in different countries and', f: bodyFont },
    { t: 'will cause import errors. If you type a date normally and it displays as a date you did not', f: bodyFont },
    { t: 'intend (e.g. "10-Mar-2026" when you meant 3rd October), please correct it before saving.', f: bodyFont },
    { t: '' },
    { t: 'MONTH FORMAT — please read', f: sectionFont },
    { t: 'The month column uses YYYY-MM. Example: 2026-10  means October 2026.', f: bodyFont },
    { t: '' },
    { t: 'Why the Contributions sheet matters', f: sectionFont },
    { t: 'The new system enforces Bye-law §42(d): a member needs at least six contributions before their', f: bodyFont },
    { t: 'first loan can be approved. Without real month-by-month data, the system would have to invent', f: bodyFont },
    { t: 'contribution dates — which would mean telling a member they contributed in months when they', f: bodyFont },
    { t: 'actually did not. This is not acceptable for a financial record.', f: bodyFont },
    { t: '' },
    { t: 'Please fill the Contributions sheet with the real contributions for the last 12 completed months.', f: bodyFont },
    { t: 'Combined with "contributions_count_to_date" on the Members sheet, this gives us both:', f: bodyFont },
    { t: '  • accurate recent history for member statements, and', f: bodyFont },
    { t: '  • an accurate lifetime count for loan eligibility.', f: bodyFont },
    { t: '' },
    { t: 'Note on the Loans sheet — report the FULL amount owed', f: sectionFont },
    { t: 'On the Loans sheet, "total_repayable" is the TOTAL the member owes — principal + interest + any', f: bodyFont },
    { t: 'historical application fee, exactly as it appears in the manual ledger. Do not try to separate the', f: bodyFont },
    { t: 'fee from the interest. The import script handles that decomposition so the migrated loan satisfies', f: bodyFont },
    { t: 'the system\'s constraints.', f: bodyFont },
    { t: '' },
    { t: 'Reconcile every loan with:   total_repaid + outstanding_balance = total_repayable.', f: { ...bodyFont, bold: true } },
    { t: '' },
    { t: 'Note on special deposits', f: sectionFont },
    { t: 'Special deposits are currently ON HOLD by Committee decision and are not part of this migration.', f: bodyFont },
    { t: 'If any member still holds an existing special deposit from before the hold, inform the Secretary.', f: bodyFont },
    { t: '' },
    { t: 'General rules', f: sectionFont },
    { t: '• Columns marked with * are required. Rows with a missing required value will fail import.', f: bodyFont },
    { t: '• registration_number is the unique identifier. Never reuse, never duplicate.', f: bodyFont },
    { t: '• Amounts are in Naira, no commas or currency symbols (e.g. 145000, not ₦145,000).', f: bodyFont },
    { t: '• Do NOT change column names or order.', f: bodyFont },
    { t: '• If a member has no loan, leave them out of the Loans sheet entirely — do not add a blank row.', f: bodyFont },
    { t: '• If a member missed a month, do NOT add a blank row in the Contributions sheet for that month.', f: bodyFont },
    { t: '  Just do not add a row. Absence of a row means no contribution that month.', f: bodyFont },
    { t: '' },
    { t: 'Data you should NOT include', f: sectionFont },
    { t: '• Special deposits (on hold by Committee decision)', f: bodyFont },
    { t: '• Fully paid loans (historical only, not part of active migration)', f: bodyFont },
    { t: '• Exited, deceased, or terminated members', f: bodyFont },
    { t: '• Applicants who were never admitted', f: bodyFont },
    { t: '' },
    { t: 'Questions the Secretary needs you to answer', f: sectionFont },
    { t: '1. Which members currently have fewer than 6 contributions since joining? (list staff IDs)', f: bodyFont },
    { t: '2. Which members are currently Suspended or in the process of being suspended?', f: bodyFont },
    { t: '3. Are there any members whose savings include special deposits? (exclude those amounts)', f: bodyFont },
    { t: '4. Any loans in default (3+ consecutive missed instalments)? Mark these status=Defaulted.', f: bodyFont },
    { t: '5. Any member currently in arrears? Their recent missing months should simply be absent from', f: bodyFont },
    { t: '   the Contributions sheet, which the system will read as missed months. Note it in the Members', f: bodyFont },
    { t: '   sheet Notes column so we can cross-check.', f: bodyFont },
    { t: '' },
    { t: 'What happens after you send this', f: sectionFont },
    { t: '1. Every member is created in the new system with their savings balance and lifetime contribution count.', f: bodyFont },
    { t: '2. Each contribution row becomes a real entry on the member\'s statement.', f: bodyFont },
    { t: '3. Active loans get records, schedules, and outstanding balances.', f: bodyFont },
    { t: '4. Every member receives an email inviting them to set their password on the new portal.', f: bodyFont },
    { t: '5. Once every member has logged in successfully, the manual ledger is retired.', f: bodyFont },
  ];

  lines.forEach(({ t, f }) => {
    const row = ws.addRow([t]);
    row.getCell(1).font = f || bodyFont;
    row.getCell(1).alignment = { vertical: 'middle', wrapText: false };
  });
}

// ═════════════════════════════════════════════════════════════════════
// SHEET 2 — Members
// ═════════════════════════════════════════════════════════════════════
{
  const ws = wb.addWorksheet('Members', { properties: { tabColor: { argb: 'FF1E88E5' } } });

  const headers = [
    'registration_number *', 'first_name *', 'middle_name', 'last_name *', 'email *', 'phone *',
    'department', 'position', 'home_address',
    'next_of_kin_name *', 'next_of_kin_phone *', 'next_of_kin_relationship *',
    'outside_indebtedness_declaration *', 'admission_date *', 'first_contribution_date *',
    'standing_contribution_amount *', 'contributions_count_to_date *', 'savings_balance *',
    'status *', 'termination_date', 'termination_reason', 'notes',
  ];
  const widths = [18, 14, 12, 14, 28, 14, 22, 18, 24, 20, 16, 20, 26, 18, 22, 20, 20, 16, 12, 18, 20, 40];

  ws.columns = headers.map((h, i) => ({ header: h, key: `c${i}`, width: widths[i] }));
  applyHeaderStyle(ws.getRow(1));
  ws.views = [{ state: 'frozen', xSplit: 0, ySplit: 1 }];

  const examples = [
    {
      c0: '0005', c1: 'Mohammed', c2: 'Yusuf', c3: 'Gana',
      c4: 'm.gana@nsp.edu.ng', c5: '08031234567',
      c6: 'Business Administration', c7: 'Chief Lecturer', c8: 'Zungeru, Niger State',
      c9: 'Fatima Gana', c10: '08039876543', c11: 'Spouse',
      c12: 'None', c13: new Date(2019, 5, 15), c14: new Date(2019, 6, 1),
      c15: 10000, c16: 76, c17: 145000,
      c18: 'Active', c19: '', c20: '', c21: '',
    },
    {
      c0: '0007', c1: 'Rachael', c2: 'N.', c3: 'Majin',
      c4: 'rachael.majin@gmail.com', c5: '08039876544',
      c6: 'Science Laboratory Technology', c7: 'Lecturer I', c8: 'Zungeru, Niger State',
      c9: 'Daniel Majin', c10: '08039990001', c11: 'Spouse',
      c12: 'None', c13: new Date(2026, 3, 10), c14: new Date(2026, 4, 1),
      c15: 10000, c16: 5, c17: 50000,
      c18: 'Active', c19: '', c20: '', c21: 'Joined recently — 5 contributions to date',
    },
  ];
  examples.forEach((ex) => applyExampleStyle(ws.addRow(ex)));

  for (let i = 0; i < 80; i++) applyBodyBorder(ws.addRow({}));

  setDateColumnFormat(ws, 'N');
  setDateColumnFormat(ws, 'O');
  setDateColumnFormat(ws, 'T');

  ws.addRow([]);
  const h = ws.addRow(['Field notes']);
  h.getCell(1).font = sectionFont;
  h.getCell(1).fill = sectionFill;

  const notes = [
    'registration_number — Cooperative member number from the manual ledger. Must be unique across all rows.',
    'email — Must be a real address. The member receives a login invitation on this address.',
    'phone — 11-digit Nigerian format, e.g. 08031234567.',
    'admission_date — The date the member joined. Enter as YYYY-MM-DD, e.g. 2019-06-15.',
    'first_contribution_date — Date of the member\'s very first contribution. Enter as YYYY-MM-DD.',
    'standing_contribution_amount — Current monthly contribution. Minimum 10000 (Bye-law §13(a)(i)).',
    'contributions_count_to_date — TOTAL number of monthly contributions the member has made since joining.',
    '                              Not a status, not a flag — a count. Examples:',
    '                                • Joined 2019-06, contributed every month since → 76',
    '                                • Joined 2026-04, contributed every month through Sept → 6',
    '                                • Joined 2026-04, contributed only in Apr, Jun, Aug, Sep → 4',
    'savings_balance — Current savings as at cutover day. Must match the manual ledger.',
    'status — One of: Active, Suspended, Terminated, Exited.',
    'termination_date / termination_reason — Fill only if status is not Active.',
    'outside_indebtedness_declaration — Per Bye-law §9. Write "None" if none.',
    'notes — Anything you want the Secretary to know. Note any member currently in arrears.',
  ];
  notes.forEach((t) => {
    const r = ws.addRow([t]);
    r.getCell(1).font = noteFont;
    r.getCell(1).fill = noteFill;
  });
}

// ═════════════════════════════════════════════════════════════════════
// SHEET 3 — Contributions
// ═════════════════════════════════════════════════════════════════════
{
  const ws = wb.addWorksheet('Contributions', { properties: { tabColor: { argb: 'FFF9A825' } } });

  const headers = [
    'registration_number *', 'contribution_month *', 'amount *', 'received_date *', 'reference',
  ];
  const widths = [22, 22, 14, 18, 28];

  ws.columns = headers.map((h, i) => ({ header: h, key: `c${i}`, width: widths[i] }));
  applyHeaderStyle(ws.getRow(1));
  ws.views = [{ state: 'frozen', xSplit: 0, ySplit: 1 }];

  const examples = [
    { c0: '0005', c1: '2025-10', c2: 10000, c3: new Date(2025, 9, 8), c4: 'TRF/2025/10342' },
    { c0: '0005', c1: '2025-11', c2: 10000, c3: new Date(2025, 10, 6), c4: 'TRF/2025/11021' },
    { c0: '0005', c1: '2025-12', c2: 10000, c3: new Date(2025, 11, 9), c4: 'TRF/2025/12008' },
    { c0: '0007', c1: '2026-05', c2: 10000, c3: new Date(2026, 4, 4), c4: 'payroll' },
    { c0: '0007', c1: '2026-06', c2: 10000, c3: new Date(2026, 5, 3), c4: 'payroll' },
  ];
  examples.forEach((ex) => applyExampleStyle(ws.addRow(ex)));

  for (let i = 0; i < 900; i++) applyBodyBorder(ws.addRow({}));

  setDateColumnFormat(ws, 'D');

  ws.addRow([]);
  const h = ws.addRow(['Field notes']);
  h.getCell(1).font = sectionFont;
  h.getCell(1).fill = sectionFill;

  const notes = [
    'One row per contribution. This sheet covers the LAST 12 COMPLETED MONTHS only.',
    'If today is October 2026, that means October 2025 through September 2026.',
    '',
    'registration_number — Must match a row on the Members sheet exactly.',
    'contribution_month — The month the contribution is for, in YYYY-MM format.',
    '                    Example: 2026-04 means April 2026.',
    'amount — Amount contributed that month, in Naira, no commas. May exceed 10000 if the member',
    '         contributed extra.',
    'received_date — Date the contribution hit the cooperative bank account, in YYYY-MM-DD format.',
    '                Example: 2026-04-05 for 5th April 2026.',
    'reference — Teller number, transfer reference, or "payroll" if deducted at source.',
    '',
    'IMPORTANT: If a member missed a month, do NOT add a row for that month. The absence of a row',
    'is what tells the system the member did not contribute.',
    '',
    'Consistency rule: for each member, sum of amounts here should be <= savings_balance on the',
    'Members sheet. The difference is their HISTORICAL SAVINGS BROUGHT FORWARD — the net savings',
    'they accumulated before this 12-month window:',
    '    historical_savings = savings_balance - sum(contributions in this sheet)',
    'The system records that figure as a single summary entry, clearly labelled as a pre-window',
    'aggregate and excluded from the loan-eligibility contribution count.',
  ];
  notes.forEach((t) => {
    const r = ws.addRow([t]);
    r.getCell(1).font = noteFont;
    r.getCell(1).fill = noteFill;
  });
}

// ═════════════════════════════════════════════════════════════════════
// SHEET 4 — Loans
// ═════════════════════════════════════════════════════════════════════
{
  const ws = wb.addWorksheet('Loans', { properties: { tabColor: { argb: 'FFD32F2F' } } });

  const headers = [
    'registration_number *', 'loan_reference_manual *', 'product_type *', 'principal_amount *',
    'disbursement_date *', 'term_months *', 'normal_interest_rate *', 'surplus_interest_rate',
    'total_repayable *', 'total_repaid *', 'outstanding_balance *', 'monthly_instalment *',
    'instalments_paid *', 'instalments_remaining *', 'next_payment_due_date *', 'status *', 'notes',
  ];
  const widths = [18, 22, 20, 16, 20, 12, 18, 18, 16, 14, 18, 18, 16, 20, 22, 12, 36];

  ws.columns = headers.map((h, i) => ({ header: h, key: `c${i}`, width: widths[i] }));
  applyHeaderStyle(ws.getRow(1));
  ws.views = [{ state: 'frozen', xSplit: 0, ySplit: 1 }];

  const examples = [
    {
      c0: '0005', c1: 'LOAN/2024/042', c2: 'Long-Term', c3: 200000,
      c4: new Date(2024, 2, 15), c5: 12, c6: 5, c7: 20,
      c8: 212000, c9: 120000, c10: 92000, c11: 17667,
      c12: 7, c13: 5, c14: new Date(2026, 9, 10), c15: 'Active', c16: '',
    },
    {
      c0: '0005', c1: 'LOAN/2025/078', c2: 'Emergency', c3: 50000,
      c4: new Date(2025, 7, 10), c5: 6, c6: 10, c7: 20,
      c8: 54500, c9: 20000, c10: 34500, c11: 9083,
      c12: 2, c13: 4, c14: new Date(2026, 9, 10), c15: 'Active', c16: 'Same member — second loan',
    },
  ];
  examples.forEach((ex) => applyExampleStyle(ws.addRow(ex)));

  for (let i = 0; i < 100; i++) applyBodyBorder(ws.addRow({}));

  setDateColumnFormat(ws, 'E');
  setDateColumnFormat(ws, 'O');

  ws.addRow([]);
  const h = ws.addRow(['Field notes']);
  h.getCell(1).font = sectionFont;
  h.getCell(1).fill = sectionFill;

  const notes = [
    'One row per ACTIVE loan. A member with 2 loans appears twice. Do NOT include fully paid loans.',
    '',
    'registration_number — Must match a row on the Members sheet exactly.',
    'loan_reference_manual — Old reference from the manual ledger, for reconciliation.',
    'product_type — One of: Long-Term, Short-Term, Emergency, Essential Commodity.',
    'disbursement_date — When the loan was given to the member. Enter as YYYY-MM-DD.',
    'term_months — Original agreed term.',
    'normal_interest_rate — % per annum (e.g. 5 for 5%).',
    'surplus_interest_rate — Default 20 if the loan exceeded the member\'s savings at disbursement.',
    '',
    'total_repayable — The TOTAL amount the member owes, exactly as it appears in the manual ledger.',
    '                   Include principal, interest, and any historical application fee — do not break them apart.',
    '                   The import script handles the breakdown so the migrated loan satisfies the system constraints.',
    '                   Reconcile: total_repaid + outstanding_balance must equal total_repayable.',
    '',
    'total_repaid — Amount already paid by cutover day.',
    'outstanding_balance — Must equal total_repayable - total_repaid.',
    'monthly_instalment — Agreed monthly amount.',
    'instalments_paid — Number of instalments already paid.',
    'instalments_remaining — Must equal term_months - instalments_paid.',
    'next_payment_due_date — The date the member\'s next monthly instalment is due, per the manual ledger.',
    '                        If the ledger only records months paid (not exact dates), use the 10th of the',
    '                        month after the last one paid. Enter as YYYY-MM-DD.',
    'status — One of: Active, Defaulted.',
    '',
    'Validation the import will run:',
    '  • total_repaid + outstanding_balance must equal total_repayable (exact to the naira)',
    '  • instalments_paid + instalments_remaining must equal term_months',
  ];
  notes.forEach((t) => {
    const r = ws.addRow([t]);
    r.getCell(1).font = noteFont;
    r.getCell(1).fill = noteFill;
  });
}

// ═════════════════════════════════════════════════════════════════════
// SHEET 5 — Self-check
// ═════════════════════════════════════════════════════════════════════
{
  const ws = wb.addWorksheet('Self-check', { properties: { tabColor: { argb: 'FF7B1FA2' } } });
  ws.columns = [
    { width: 62, key: 'check' },
    { width: 40, key: 'expected' },
    { width: 20, key: 'actual' },
  ];

  const title = ws.addRow(['Self-check — please complete before sending this workbook back.']);
  title.getCell(1).font = titleFont;
  ws.mergeCells('A1:C1');

  applyHeaderStyle(ws.addRow(['Check', 'Expected result', 'Your result']));

  const checks = [
    ['Total rows on Members sheet', '74', ''],
    ['Total rows on Contributions sheet', 'roughly 74 × 12 = ~888, less any missed months', ''],
    ['Total rows on Loans sheet', '(from your records)', ''],
    ['Members whose contributions_count_to_date < 6', '(from your records)', ''],
    ['Members whose status is not Active', '(from your records)', ''],
    ['Members currently in arrears (noted in Members Notes)', '(from your records)', ''],
    ['For every loan: total_repaid + outstanding_balance = total_repayable', 'True', ''],
    ['For every loan: instalments_paid + instalments_remaining = term_months', 'True', ''],
    ['For every member: savings_balance >= 0', 'True', ''],
    ['For every member: standing_contribution_amount >= 10000', 'True', ''],
    ['For every member: contributions_count_to_date >= 1', 'True', ''],
    ['For every member: email appears only once', 'True', ''],
    ['For every member: registration_number appears only once', 'True', ''],
    ['For every row in Contributions: registration_number exists on Members sheet', 'True', ''],
    ['For every row in Contributions: amount > 0', 'True', ''],
    ['For every row in Contributions: contribution_month is in YYYY-MM format', 'True', ''],
    ['For every row in Contributions: received_date is a real date in YYYY-MM-DD', 'True', ''],
  ];

  checks.forEach((c) => {
    const r = ws.addRow(c);
    r.getCell(1).font = bodyFont;
    r.getCell(2).font = bodyFont;
    r.getCell(3).font = bodyFont;
    applyBodyBorder(r);
    r.height = 22;
  });

  ws.addRow([]);
  const extraHeader = ws.addRow(['Consistency check for the Contributions sheet:']);
  extraHeader.getCell(1).font = sectionFont;
  extraHeader.getCell(1).fill = sectionFill;
  ws.mergeCells(`A${extraHeader.number}:C${extraHeader.number}`);

  const extras = [
    'For each member, sum of contributions in the sheet should be <= savings_balance on Members sheet.',
    'The difference is their HISTORICAL SAVINGS BROUGHT FORWARD — net savings accumulated before',
    'the 12-month window, after accounting for any fines or withdrawals during that period.',
    '',
    'Sanity check: contributions_count_to_date should be >= the number of rows that member has in',
    'the Contributions sheet (because the count is their lifetime total, and the sheet is only the',
    'last 12 months).',
  ];
  extras.forEach((t) => {
    const r = ws.addRow([t]);
    r.getCell(1).font = noteFont;
    r.getCell(1).fill = noteFill;
    ws.mergeCells(`A${r.number}:C${r.number}`);
  });

  ws.addRow([]);
  const signoffHeader = ws.addRow(['Sign-off']);
  signoffHeader.getCell(1).font = sectionFont;
  signoffHeader.getCell(1).fill = sectionFill;
  ws.mergeCells(`A${signoffHeader.number}:C${signoffHeader.number}`);

  const signoff = [
    ['Role', 'Name', 'Date'],
    ['Treasurer', '', ''],
    ['Secretary (received)', '', ''],
    ['Chairman (acknowledged)', '', ''],
  ];
  signoff.forEach((row, idx) => {
    const r = ws.addRow(row);
    if (idx === 0) applyHeaderStyle(r);
    else applyBodyBorder(r);
    r.height = 24;
  });
}

wb.views = [{ activeTab: 0 }];
await wb.xlsx.writeFile(OUT);
console.log(`✓ Wrote ${path.resolve(OUT)}`);
console.log(`  Open it in Excel or LibreOffice to review before sending to the Treasurer.`);