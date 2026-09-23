// scripts/generate-migration-template.mjs
//
// Generates migration-template.xlsx — the workbook the Treasurer fills
// in to migrate member data from the manual system to SSCMPS.
//
// NOTE: Special Deposits are currently on hold by Committee decision,
// so that sheet is not included. If they are re-enabled, add the sheet
// back in (see git history for the version that includes it).
//
// Usage:
//   node scripts/generate-migration-template.mjs
//
// Output:
//   migration-template.xlsx in the repo root

import ExcelJS from 'exceljs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const OUT_PATH = join(__dirname, '..', 'migration-template.xlsx');

// ---------------------------------------------------------------------
// Style helpers
// ---------------------------------------------------------------------
const HEADER_FILL = {
  type: 'pattern',
  pattern: 'solid',
  fgColor: { argb: 'FF1F4E78' },   // dark blue
};
const HEADER_FONT = {
  bold: true,
  color: { argb: 'FFFFFFFF' },
  size: 11,
};
const EXAMPLE_ROW_FILL = {
  type: 'pattern',
  pattern: 'solid',
  fgColor: { argb: 'FFFFF3CD' },   // pale yellow
};
const EXAMPLE_ROW_FONT = {
  italic: true,
  color: { argb: 'FF665500' },
};
const REQUIRED_NOTE_FONT = {
  bold: true,
  color: { argb: 'FFFF0000' },      // red for required columns
};

function styleHeaderRow(worksheet, requiredFlags) {
  const headerRow = worksheet.getRow(1);
  headerRow.eachCell((cell, colNumber) => {
    cell.fill = HEADER_FILL;
    cell.font = HEADER_FONT;
    cell.alignment = { vertical: 'middle', horizontal: 'center', wrapText: true };
    cell.border = {
      top: { style: 'thin' },
      left: { style: 'thin' },
      bottom: { style: 'thin' },
      right: { style: 'thin' },
    };
    if (requiredFlags[colNumber - 1]) {
      cell.value = cell.value + ' *';
      cell.font = REQUIRED_NOTE_FONT;
      cell.fill = HEADER_FILL;
    }
  });
  headerRow.height = 32;
}

function styleExampleRow(worksheet, rowNumber, values) {
  const row = worksheet.getRow(rowNumber);
  values.forEach((value, idx) => {
    row.getCell(idx + 1).value = value;
    row.getCell(idx + 1).font = EXAMPLE_ROW_FONT;
    row.getCell(idx + 1).fill = EXAMPLE_ROW_FILL;
    row.getCell(idx + 1).border = {
      top: { style: 'thin' },
      left: { style: 'thin' },
      bottom: { style: 'thin' },
      right: { style: 'thin' },
    };
  });
}

function setColumnWidths(worksheet, widths) {
  worksheet.columns.forEach((col, idx) => {
    col.width = widths[idx] || 18;
  });
}

// ---------------------------------------------------------------------
// Instructions sheet
// ---------------------------------------------------------------------
const INSTRUCTIONS = [
  ['SSCMPS MEMBER MIGRATION TEMPLATE'],
  [''],
  ['Purpose'],
  ['This workbook captures the member data required to migrate the cooperative from the'],
  ['manual system to SSCMPS. Fill in the yellow example rows with real data, then delete'],
  ['the examples.'],
  [''],
  ['Sheets in this workbook'],
  ['1. Members — one row per member (all 76 members)'],
  ['2. Loans   — one row per ACTIVE loan (a member with 2 loans = 2 rows)'],
  [''],
  ['Note on special deposits'],
  ['Special deposits are currently ON HOLD by Committee decision. They are not included'],
  ['in this migration. If any member still holds an existing special deposit from before'],
  ['the hold, please inform the Secretary — we will handle those separately.'],
  [''],
  ['Rules'],
  ['• Columns marked with * are required'],
  ['• registration_number is the unique identifier — never reuse, never duplicate'],
  ['• Dates must be in YYYY-MM-DD format (e.g. 2019-06-15)'],
  ['• Amounts are in Naira, no commas or currency symbols (e.g. 145000, not ₦145,000)'],
  ['• Do NOT change column names or order'],
  ['• If a member has no loan, leave them out of the Loans sheet entirely (do not add a blank row)'],
  [''],
  ['Validation the import script will run'],
  ['• registration_number must be unique across all rows'],
  ['• email must be unique and a valid format'],
  ['• total_repaid + outstanding_balance must equal total_repayable (per loan row)'],
  ['• savings_balance must not be negative'],
  [''],
  ['If you need help filling any column, see the field notes at the bottom of each sheet.'],
];

// ---------------------------------------------------------------------
// Members sheet
// ---------------------------------------------------------------------
const MEMBERS_COLUMNS = [
  { header: 'registration_number', width: 22, required: true },
  { header: 'first_name', width: 16, required: true },
  { header: 'middle_name', width: 16, required: false },
  { header: 'last_name', width: 16, required: true },
  { header: 'email', width: 28, required: true },
  { header: 'phone', width: 14, required: true },
  { header: 'department', width: 20, required: false },
  { header: 'position', width: 18, required: false },
  { header: 'home_address', width: 24, required: false },
  { header: 'next_of_kin_name', width: 20, required: true },
  { header: 'next_of_kin_phone', width: 16, required: true },
  { header: 'next_of_kin_relationship', width: 18, required: true },
  { header: 'outside_indebtedness_declaration', width: 28, required: true },
  { header: 'admission_date', width: 14, required: true },
  { header: 'first_contribution_date', width: 16, required: true },
  { header: 'standing_contribution_amount', width: 18, required: true },
  { header: 'savings_balance', width: 16, required: true },
  { header: 'status', width: 12, required: true },
  { header: 'termination_date', width: 14, required: false },
  { header: 'termination_reason', width: 20, required: false },
  { header: 'notes', width: 30, required: false },
];

const MEMBERS_EXAMPLE = [
  'SSCMPS/2019/001',
  'Mohammed',
  'Yusuf',
  'Gana',
  'm.gana@nsp.edu.ng',
  '08031234567',
  'Computer Science',
  'Lecturer I',
  'Zungeru, Niger State',
  'Fatima Gana',
  '08039876543',
  'Spouse',
  'None',
  '2019-06-15',
  '2019-07-01',
  10000,
  145000,
  'Active',
  '',
  '',
  '',
];

const MEMBERS_NOTES = [
  [''],
  ['Field notes'],
  ['registration_number — Cooperative member number from the manual ledger. Must be unique.'],
  ['email              — Must be a real address for the login invite. Staff email preferred.'],
  ['phone              — 11-digit Nigerian format (e.g. 08031234567).'],
  ['admission_date     — The date the member joined the cooperative.'],
  ['first_contribution_date — Date of the member\'s very first contribution.'],
  ['standing_contribution_amount — Monthly contribution. Minimum N10,000.'],
  ['savings_balance    — Current savings as of cutover day (must match the manual ledger).'],
  ['status             — One of: Active, Suspended, Terminated, Exited.'],
  ['termination_date/reason — Fill only if status is not Active.'],
  ['outside_indebtedness_declaration — Per Bye-law Section 9. Write "None" if none.'],
];

// ---------------------------------------------------------------------
// Loans sheet
// ---------------------------------------------------------------------
const LOANS_COLUMNS = [
  { header: 'registration_number', width: 22, required: true },
  { header: 'loan_reference_manual', width: 20, required: true },
  { header: 'product_type', width: 18, required: true },
  { header: 'principal_amount', width: 16, required: true },
  { header: 'disbursement_date', width: 16, required: true },
  { header: 'term_months', width: 12, required: true },
  { header: 'normal_interest_rate', width: 16, required: true },
  { header: 'surplus_interest_rate', width: 16, required: false },
  { header: 'total_repayable', width: 16, required: true },
  { header: 'total_repaid', width: 14, required: true },
  { header: 'outstanding_balance', width: 18, required: true },
  { header: 'monthly_instalment', width: 16, required: true },
  { header: 'instalments_paid', width: 16, required: true },
  { header: 'instalments_remaining', width: 20, required: true },
  { header: 'next_payment_due_date', width: 20, required: true },
  { header: 'status', width: 12, required: true },
  { header: 'notes', width: 30, required: false },
];

const LOANS_EXAMPLE_1 = [
  'SSCMPS/2019/001',
  'LOAN/2024/042',
  'Long-Term',
  200000,
  '2024-03-15',
  12,
  5,
  20,
  212000,
  120000,
  92000,
  17667,
  7,
  5,
  '2026-10-10',
  'Active',
  '',
];

const LOANS_EXAMPLE_2 = [
  'SSCMPS/2019/001',
  'LOAN/2025/078',
  'Emergency',
  50000,
  '2025-08-10',
  6,
  10,
  20,
  54500,
  20000,
  34500,
  9083,
  2,
  4,
  '2026-10-10',
  'Active',
  'Same member — second loan',
];

const LOANS_NOTES = [
  [''],
  ['Field notes'],
  ['A member with multiple loans gets one row per loan. The examples above show the same'],
  ['member with two loans. If a member has no loan, do not include them on this sheet at all.'],
  [''],
  ['registration_number      — Must match a row on the Members sheet exactly.'],
  ['loan_reference_manual    — Old reference from the manual ledger (for reconciliation).'],
  ['product_type             — One of: Long-Term, Short-Term, Emergency, Essential Commodity.'],
  ['disbursement_date        — When the loan was given to the member.'],
  ['term_months              — Original agreed term.'],
  ['normal_interest_rate     — % per annum.'],
  ['total_repayable          — Principal + all interest + fees, as agreed with the member.'],
  ['total_repaid             — Amount already paid by cutover day.'],
  ['outstanding_balance      — Must equal total_repayable minus total_repaid.'],
  ['monthly_instalment       — Agreed monthly amount.'],
  ['instalments_paid         — How many instalments already paid.'],
  ['instalments_remaining    — How many remain (instalments_paid + remaining = term_months).'],
  ['next_payment_due_date    — Next 10th-of-month after cutover day.'],
  ['status                   — One of: Active, Defaulted. Do NOT include fully paid loans.'],
];

// ---------------------------------------------------------------------
// Build the workbook
// ---------------------------------------------------------------------
async function main() {
  const workbook = new ExcelJS.Workbook();
  workbook.creator = 'SSCMPS Migration Tool';
  workbook.created = new Date();

  // --- Instructions sheet ---
  const instr = workbook.addWorksheet('Instructions', {
    properties: { tabColor: { argb: 'FF1F4E78' } },
  });
  instr.columns = [{ width: 110 }];
  INSTRUCTIONS.forEach((row, idx) => {
    const r = instr.getRow(idx + 1);
    r.getCell(1).value = row[0];
    if (idx === 0) {
      r.getCell(1).font = { bold: true, size: 14, color: { argb: 'FF1F4E78' } };
    } else if (
      row[0] === 'Purpose' ||
      row[0] === 'Sheets in this workbook' ||
      row[0] === 'Note on special deposits' ||
      row[0] === 'Rules' ||
      row[0] === 'Validation the import script will run'
    ) {
      r.getCell(1).font = { bold: true, size: 12 };
    }
  });

  // --- Members sheet ---
  const members = workbook.addWorksheet('Members', {
    properties: { tabColor: { argb: 'FF2E7D32' } },
  });
  members.addRow(MEMBERS_COLUMNS.map((c) => c.header));
  styleHeaderRow(members, MEMBERS_COLUMNS.map((c) => c.required));
  setColumnWidths(members, MEMBERS_COLUMNS.map((c) => c.width));
  members.addRow(MEMBERS_EXAMPLE);
  styleExampleRow(members, 2, MEMBERS_EXAMPLE);
  members.addRow([]);
  MEMBERS_NOTES.forEach((note) => members.addRow(note));
  members.views = [{ state: 'frozen', ySplit: 1 }];

  // --- Loans sheet ---
  const loans = workbook.addWorksheet('Loans', {
    properties: { tabColor: { argb: 'FFC62828' } },
  });
  loans.addRow(LOANS_COLUMNS.map((c) => c.header));
  styleHeaderRow(loans, LOANS_COLUMNS.map((c) => c.required));
  setColumnWidths(loans, LOANS_COLUMNS.map((c) => c.width));
  loans.addRow(LOANS_EXAMPLE_1);
  styleExampleRow(loans, 2, LOANS_EXAMPLE_1);
  loans.addRow(LOANS_EXAMPLE_2);
  styleExampleRow(loans, 3, LOANS_EXAMPLE_2);
  loans.addRow([]);
  LOANS_NOTES.forEach((note) => loans.addRow(note));
  loans.views = [{ state: 'frozen', ySplit: 1 }];

  // --- Save ---
  await workbook.xlsx.writeFile(OUT_PATH);
  console.log(`✅ Template written to: ${OUT_PATH}`);
  console.log('');
  console.log('Sheets:');
  console.log('  • Instructions  — how to fill the template');
  console.log('  • Members       — one row per member (76 expected)');
  console.log('  • Loans         — one row per active loan');
  console.log('');
  console.log('Special Deposits sheet omitted: product is on hold.');
}

main().catch((err) => {
  console.error('❌ Template generation failed:', err);
  process.exit(1);
});