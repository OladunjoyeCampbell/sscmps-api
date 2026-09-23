// scripts/import-legacy-members.mjs
//
// Imports legacy member data from the migration template into Supabase.
//
// Usage:
//   node scripts/import-legacy-members.mjs --file=migration-template.xlsx --dry-run
//   node scripts/import-legacy-members.mjs --file=migration-template.xlsx --apply
//
// Behaviour:
//   --dry-run  Validates the workbook and prints a report. No writes.
//   --apply    Validates, then writes to Supabase. Creates auth users,
//              member rows, opening-balance ledger entries, loan rows,
//              and repayment schedules.
//
// Environment (.env.node):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

import 'dotenv/config';
import ExcelJS from 'exceljs';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ---------------------------------------------------------------------
// CLI args
// ---------------------------------------------------------------------
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, '').split('=');
    return [k, v ?? true];
  })
);

const FILE_PATH = args.file
  ? join(process.cwd(), args.file)
  : join(__dirname, '..', 'migration-template.xlsx');

const DRY_RUN = !!args['dry-run'];
const APPLY = !!args.apply;

if (!DRY_RUN && !APPLY) {
  console.error('❌ Specify either --dry-run or --apply');
  process.exit(1);
}

if (DRY_RUN && APPLY) {
  console.error('❌ Cannot use --dry-run and --apply together');
  process.exit(1);
}

// ---------------------------------------------------------------------
// Supabase client
// ---------------------------------------------------------------------
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('❌ SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in .env.node');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// ---------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------
const REQUIRED_MEMBER_FIELDS = [
  'registration_number',
  'first_name',
  'last_name',
  'email',
  'phone',
  'next_of_kin_name',
  'next_of_kin_phone',
  'next_of_kin_relationship',
  'outside_indebtedness_declaration',
  'admission_date',
  'first_contribution_date',
  'standing_contribution_amount',
  'savings_balance',
  'status',
];

const REQUIRED_LOAN_FIELDS = [
  'registration_number',
  'loan_reference_manual',
  'product_type',
  'principal_amount',
  'disbursement_date',
  'term_months',
  'normal_interest_rate',
  'total_repayable',
  'total_repaid',
  'outstanding_balance',
  'monthly_instalment',
  'instalments_paid',
  'instalments_remaining',
  'next_payment_due_date',
  'status',
];

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const REG_RE = /^[0-9]{4}$/;
const PHONE_RE = /^0[0-9]{10}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const PRODUCTS = ['Long-Term', 'Short-Term', 'Emergency', 'Essential Commodity'];

function cellToString(value) {
  if (value == null) return '';
  if (value instanceof Date) {
    // ExcelJS converts ISO date strings to Date objects in some cases.
    // Convert back to YYYY-MM-DD.
    const y = value.getUTCFullYear();
    const m = String(value.getUTCMonth() + 1).padStart(2, '0');
    const d = String(value.getUTCDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  if (typeof value === 'object' && value.text) return String(value.text).trim();
  return String(value).trim();
}

function rowToObject(headers, row) {
  const obj = {};
  headers.forEach((h, idx) => {
    if (!h) return;
    obj[h] = cellToString(row.getCell(idx + 1).value);
  });
  return obj;
}

// ---------------------------------------------------------------------
// Read workbook
// ---------------------------------------------------------------------
async function readWorkbook(path) {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.readFile(path);

  const membersSheet = wb.getWorksheet('Members');
  const loansSheet = wb.getWorksheet('Loans');

  if (!membersSheet) throw new Error('Workbook is missing the "Members" sheet');
  if (!loansSheet) throw new Error('Workbook is missing the "Loans" sheet');

  const membersHeaders = membersSheet.getRow(1).values.slice(1).map((h) => cellToString(h));
  const loansHeaders = loansSheet.getRow(1).values.slice(1).map((h) => cellToString(h));

  const members = [];
  membersSheet.eachRow((row, rowNumber) => {
    if (rowNumber === 1) return;
    const obj = rowToObject(membersHeaders, row);
    // Skip empty rows and the yellow example row (detected by registration_number '0005'
    // paired with 'Mohammed'/'Yusuf'/'Gana' — the specific example).
    if (!obj.registration_number) return;
    if (
      obj.registration_number === '0005' &&
      obj.first_name === 'Mohammed' &&
      obj.last_name === 'Gana'
    ) return;
    members.push({ ...obj, __row: rowNumber });
  });

  const loans = [];
  loansSheet.eachRow((row, rowNumber) => {
    if (rowNumber === 1) return;
    const obj = rowToObject(loansHeaders, row);
    if (!obj.registration_number) return;
    // Skip the two yellow example rows
    if (
      obj.registration_number === '0005' &&
      (obj.loan_reference_manual === 'LOAN/2024/042' ||
        obj.loan_reference_manual === 'LOAN/2025/078')
    ) return;
    loans.push({ ...obj, __row: rowNumber });
  });

  return { members, loans };
}

// ---------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------
function validate(members, loans) {
  const errors = [];
  const warnings = [];

  // Duplicate registration numbers
  const regCounts = {};
  members.forEach((m) => {
    regCounts[m.registration_number] = (regCounts[m.registration_number] || 0) + 1;
  });
  Object.entries(regCounts).forEach(([reg, count]) => {
    if (count > 1) errors.push(`Members: registration_number ${reg} appears ${count} times`);
  });

  // Duplicate emails
  const emailCounts = {};
  members.forEach((m) => {
    if (m.email) emailCounts[m.email.toLowerCase()] = (emailCounts[m.email.toLowerCase()] || 0) + 1;
  });
  Object.entries(emailCounts).forEach(([email, count]) => {
    if (count > 1) errors.push(`Members: email ${email} appears ${count} times`);
  });

  // Per-member validation
  members.forEach((m) => {
    const tag = `Members row ${m.__row} (${m.registration_number || 'no reg'})`;
    for (const field of REQUIRED_MEMBER_FIELDS) {
      if (!m[field]) errors.push(`${tag}: missing required field "${field}"`);
    }
    if (m.registration_number && !REG_RE.test(m.registration_number)) {
      errors.push(`${tag}: registration_number must be 4 digits`);
    }
    if (m.email && !EMAIL_RE.test(m.email)) {
      errors.push(`${tag}: invalid email "${m.email}"`);
    }
    if (m.phone && !PHONE_RE.test(m.phone)) {
      warnings.push(`${tag}: phone "${m.phone}" is not 11-digit Nigerian format`);
    }
    if (m.admission_date && !DATE_RE.test(m.admission_date)) {
      errors.push(`${tag}: admission_date must be YYYY-MM-DD`);
    }
    if (m.first_contribution_date && !DATE_RE.test(m.first_contribution_date)) {
      errors.push(`${tag}: first_contribution_date must be YYYY-MM-DD`);
    }
    const savings = parseFloat(m.savings_balance);
    if (isNaN(savings) || savings < 0) {
      errors.push(`${tag}: savings_balance must be a non-negative number`);
    }
    const standing = parseFloat(m.standing_contribution_amount);
    if (isNaN(standing) || standing < 10000) {
      errors.push(`${tag}: standing_contribution_amount must be >= 10000`);
    }
    if (!['Active', 'Suspended', 'Terminated', 'Exited'].includes(m.status)) {
      errors.push(`${tag}: status must be Active, Suspended, Terminated, or Exited`);
    }
  });

  // Per-loan validation
  const memberRegs = new Set(members.map((m) => m.registration_number));
  loans.forEach((l) => {
    const tag = `Loans row ${l.__row} (${l.registration_number} / ${l.loan_reference_manual || 'no ref'})`;
    for (const field of REQUIRED_LOAN_FIELDS) {
      if (!l[field]) errors.push(`${tag}: missing required field "${field}"`);
    }
    if (l.registration_number && !memberRegs.has(l.registration_number)) {
      errors.push(`${tag}: registration_number does not match any member`);
    }
    if (l.product_type && !PRODUCTS.includes(l.product_type)) {
      errors.push(`${tag}: product_type must be one of ${PRODUCTS.join(', ')}`);
    }
    if (l.disbursement_date && !DATE_RE.test(l.disbursement_date)) {
      errors.push(`${tag}: disbursement_date must be YYYY-MM-DD`);
    }
    if (l.next_payment_due_date && !DATE_RE.test(l.next_payment_due_date)) {
      errors.push(`${tag}: next_payment_due_date must be YYYY-MM-DD`);
    }

    const principal = parseFloat(l.principal_amount);
    const repayable = parseFloat(l.total_repayable);
    const repaid = parseFloat(l.total_repaid);
    const outstanding = parseFloat(l.outstanding_balance);
    const monthly = parseFloat(l.monthly_instalment);
    const termMonths = parseInt(l.term_months, 10);
    const instPaid = parseInt(l.instalments_paid, 10);
    const instRemaining = parseInt(l.instalments_remaining, 10);

    if (isNaN(principal) || principal <= 0) errors.push(`${tag}: principal_amount must be > 0`);
    if (isNaN(repayable) || repayable <= 0) errors.push(`${tag}: total_repayable must be > 0`);
    if (isNaN(repaid) || repaid < 0) errors.push(`${tag}: total_repaid must be >= 0`);
    if (isNaN(outstanding) || outstanding < 0) errors.push(`${tag}: outstanding_balance must be >= 0`);
    if (isNaN(monthly) || monthly <= 0) errors.push(`${tag}: monthly_instalment must be > 0`);

    if (!isNaN(repayable) && !isNaN(repaid) && !isNaN(outstanding)) {
      const sum = repaid + outstanding;
      if (Math.abs(sum - repayable) > 0.5) {
        errors.push(
          `${tag}: total_repaid (${repaid}) + outstanding_balance (${outstanding}) = ${sum}, ` +
          `does not equal total_repayable (${repayable})`
        );
      }
    }

    if (!isNaN(termMonths) && !isNaN(instPaid) && !isNaN(instRemaining)) {
      if (instPaid + instRemaining !== termMonths) {
        warnings.push(
          `${tag}: instalments_paid (${instPaid}) + instalments_remaining (${instRemaining}) = ` +
          `${instPaid + instRemaining}, but term_months is ${termMonths}`
        );
      }
    }
  });

  return { errors, warnings };
}

// ---------------------------------------------------------------------
// Reconciliation summary
// ---------------------------------------------------------------------
function summarise(members, loans) {
  const totalSavings = members.reduce(
    (s, m) => s + (parseFloat(m.savings_balance) || 0),
    0
  );
  const totalOutstanding = loans.reduce(
    (s, l) => s + (parseFloat(l.outstanding_balance) || 0),
    0
  );
  const activeCount = members.filter((m) => m.status === 'Active').length;
  const nonActiveCount = members.length - activeCount;

  return {
    memberCount: members.length,
    activeCount,
    nonActiveCount,
    loanCount: loans.length,
    totalSavings,
    totalOutstanding,
  };
}

function fmtNaira(v) {
  return 'N' + Number(v || 0).toLocaleString('en-NG', { maximumFractionDigits: 2 });
}

// ---------------------------------------------------------------------
// Date helpers
// ---------------------------------------------------------------------
function firstDueDate(disbursementDate) {
  // First instalment due: 10th of the month following disbursement
  const d = new Date(disbursementDate + 'T00:00:00Z');
  const y = d.getUTCFullYear();
  const m = d.getUTCMonth();
  // Move to next month, day 10
  const first = new Date(Date.UTC(y, m + 1, 10));
  return first.toISOString().split('T')[0];
}

function addMonths(dateStr, months) {
  const d = new Date(dateStr + 'T00:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + months);
  return d.toISOString().split('T')[0];
}

// ---------------------------------------------------------------------
// Apply: write to Supabase
// ---------------------------------------------------------------------
async function applyImport(members, loans) {
  const batch = new Date().toISOString().split('T')[0];
  const results = {
    members_created: 0,
    members_failed: [],
    auth_users_created: 0,
    auth_users_failed: [],
    opening_balances_created: 0,
    loans_created: 0,
    loans_failed: [],
    schedule_entries_created: 0,
  };

  // Pre-load loan products for lookup by name
  const { data: products } = await supabase
    .from('loan_products')
    .select('id, name');
  const productByName = Object.fromEntries((products || []).map((p) => [p.name, p.id]));

  // Track member reg -> member id (for loans)
  const memberIdByReg = {};

  for (const m of members) {
    // 1. Create auth user (or find existing)
    let authUserId = null;
    const { data: created, error: authErr } = await supabase.auth.admin.createUser({
      email: m.email,
      password: crypto.randomUUID() + 'Aa1!',   // random unguessable; user resets
      email_confirm: true,
      user_metadata: {
        registration_number: m.registration_number,
        first_name: m.first_name,
        last_name: m.last_name,
        migrated: true,
      },
    });

    if (authErr) {
      if (authErr.message?.includes('already been registered')) {
        // Fetch existing user id
        const { data: list } = await supabase.auth.admin.listUsers();
        const existing = list?.users?.find(
          (u) => u.email?.toLowerCase() === m.email.toLowerCase()
        );
        if (existing) authUserId = existing.id;
        else {
          results.auth_users_failed.push({ reg: m.registration_number, error: authErr.message });
          continue;
        }
      } else {
        results.auth_users_failed.push({ reg: m.registration_number, error: authErr.message });
        continue;
      }
    } else {
      authUserId = created.user.id;
      results.auth_users_created++;
    }

    // 2. Insert member row
    const memberRow = {
      auth_user_id: authUserId,
      registration_number: m.registration_number,
      staff_id: m.staff_id || null,
      first_name: m.first_name,
      middle_name: m.middle_name || null,
      last_name: m.last_name,
      email: m.email,
      phone: m.phone || null,
      department: m.department || null,
      position: m.position || null,
      home_address: m.home_address || null,
      next_of_kin_name: m.next_of_kin_name || null,
      next_of_kin_phone: m.next_of_kin_phone || null,
      next_of_kin_relationship: m.next_of_kin_relationship || null,
      outside_indebtedness_declaration: m.outside_indebtedness_declaration || 'None',
      admission_date: m.admission_date || null,
      first_contribution_date: m.first_contribution_date || null,
      standing_contribution_amount: parseFloat(m.standing_contribution_amount),
      status: m.status || 'Active',
      termination_date: m.termination_date || null,
      termination_reason: m.termination_reason || null,
      role: 'Member',
      admission_decision_at: new Date().toISOString(),
    };

    const { data: insertedMember, error: memberErr } = await supabase
      .from('members')
      .insert(memberRow)
      .select('id')
      .single();

    if (memberErr) {
      results.members_failed.push({ reg: m.registration_number, error: memberErr.message });
      continue;
    }

    memberIdByReg[m.registration_number] = insertedMember.id;
    results.members_created++;

    // 3. Opening balance ledger entry
    const savings = parseFloat(m.savings_balance) || 0;
    if (savings > 0) {
      const { error: ledgerErr } = await supabase.from('ledger_entries').insert({
        member_id: insertedMember.id,
        transaction_date: batch,
        transaction_type: 'CONTRIBUTION',
        amount: savings,
        source: 'SYSTEM',
        status: 'Approved',
        approved_at: new Date().toISOString(),
        approved_by: insertedMember.id,   // self-approved system entry
        allocation_notes: `Opening balance — migrated from manual records on ${batch} (reg ${m.registration_number})`,
      });
      if (!ledgerErr) results.opening_balances_created++;
    }
  }

  // 4. Loans
  for (const l of loans) {
    const memberId = memberIdByReg[l.registration_number];
    if (!memberId) {
      results.loans_failed.push({ reg: l.registration_number, error: 'Member not imported' });
      continue;
    }
    const productId = productByName[l.product_type];
    if (!productId) {
      results.loans_failed.push({
        reg: l.registration_number,
        ref: l.loan_reference_manual,
        error: `Unknown product_type "${l.product_type}"`,
      });
      continue;
    }

    const { data: insertedLoan, error: loanErr } = await supabase
      .from('loans')
      .insert({
        member_id: memberId,
        loan_product_id: productId,
        principal_amount: parseFloat(l.principal_amount),
        total_repayable: parseFloat(l.total_repayable),
        total_repaid: parseFloat(l.total_repaid),
        monthly_instalment: parseFloat(l.monthly_instalment),
        term_months: parseInt(l.term_months, 10),
        instalments_paid: parseInt(l.instalments_paid, 10),
        next_payment_due_date: l.next_payment_due_date,
        status: 'Active',
        application_date: l.disbursement_date,
        disbursed_at: l.disbursement_date + 'T00:00:00Z',
        purpose: `Migrated from manual ledger (ref ${l.loan_reference_manual})`,
      })
      .select('id')
      .single();

    if (loanErr) {
      results.loans_failed.push({
        reg: l.registration_number,
        ref: l.loan_reference_manual,
        error: loanErr.message,
      });
      continue;
    }

    results.loans_created++;

    // 5. Repayment schedule — generate remaining instalments starting from
    //    next_payment_due_date
    const remaining = parseInt(l.instalments_remaining, 10) || 0;
    const monthlyAmount = parseFloat(l.monthly_instalment);
    let dueDate = l.next_payment_due_date;

    for (let i = 1; i <= remaining; i++) {
      const { error: schedErr } = await supabase
        .from('loan_repayment_schedule')
        .insert({
          loan_id: insertedLoan.id,
          instalment_number: i,
          due_date: dueDate,
          scheduled_amount: monthlyAmount,
          amount_paid: 0,
          status: 'Pending',
        });
      if (!schedErr) results.schedule_entries_created++;
      dueDate = addMonths(dueDate, 1);
    }
  }

  return { batch, results };
}

// ---------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------
async function main() {
  console.log('═══════════════════════════════════════════════════════════');
  console.log('  SSCMPS Legacy Migration — ' + (DRY_RUN ? 'DRY RUN' : 'APPLY'));
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`Workbook: ${FILE_PATH}`);
  console.log('');

  if (!FILE_PATH.endsWith('.xlsx')) {
    console.error('❌ Workbook must be an .xlsx file');
    process.exit(1);
  }

  let workbook;
  try {
    workbook = await readWorkbook(FILE_PATH);
  } catch (err) {
    console.error('❌ Failed to read workbook:', err.message);
    process.exit(1);
  }

  const { members, loans } = workbook;
  console.log(`Loaded ${members.length} member rows and ${loans.length} loan rows.`);
  console.log('');

  const { errors, warnings } = validate(members, loans);

  if (warnings.length) {
    console.log(`⚠️  ${warnings.length} warning(s):`);
    warnings.slice(0, 20).forEach((w) => console.log('   - ' + w));
    if (warnings.length > 20) console.log(`   ... and ${warnings.length - 20} more`);
    console.log('');
  }

  if (errors.length) {
    console.log(`❌ ${errors.length} validation error(s):`);
    errors.slice(0, 40).forEach((e) => console.log('   - ' + e));
    if (errors.length > 40) console.log(`   ... and ${errors.length - 40} more`);
    console.log('');
    console.log('Fix the above in the workbook, then re-run.');
    process.exit(1);
  }

  console.log('✅ Validation passed.');
  console.log('');

  const s = summarise(members, loans);
  console.log('Reconciliation summary:');
  console.log(`   Members:                ${s.memberCount} (${s.activeCount} active, ${s.nonActiveCount} non-active)`);
  console.log(`   Active loans:           ${s.loanCount}`);
  console.log(`   Total savings imported: ${fmtNaira(s.totalSavings)}`);
  console.log(`   Total loans outstanding: ${fmtNaira(s.totalOutstanding)}`);
  console.log('');

  if (DRY_RUN) {
    console.log('Dry run complete. No writes made.');
    console.log('');

    // Write a CSV preview
    const previewPath = join(__dirname, '..', 'migration-preview.csv');
    const headers = ['registration_number', 'first_name', 'last_name', 'email', 'savings_balance', 'status'];
    const csv = [headers.join(',')];
    members.forEach((m) => {
      csv.push(
        [
          m.registration_number,
          m.first_name,
          m.last_name,
          m.email,
          m.savings_balance,
          m.status,
        ]
          .map((v) => `"${String(v ?? '').replace(/"/g, '""')}"`)
          .join(',')
      );
    });
    writeFileSync(previewPath, csv.join('\n'));
    console.log(`Preview CSV written to: ${previewPath}`);
    console.log('Review it, then run with --apply when satisfied.');
    return;
  }

  // APPLY
  console.log('Applying import...');
  const { batch, results } = await applyImport(members, loans);

  console.log('');
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`  Import complete — batch ${batch}`);
  console.log('═══════════════════════════════════════════════════════════');
  console.log(`Auth users created:      ${results.auth_users_created}`);
  console.log(`Auth users failed:       ${results.auth_users_failed.length}`);
  console.log(`Members inserted:        ${results.members_created}`);
  console.log(`Members failed:          ${results.members_failed.length}`);
  console.log(`Opening balances:        ${results.opening_balances_created}`);
  console.log(`Loans created:           ${results.loans_created}`);
  console.log(`Loans failed:            ${results.loans_failed.length}`);
  console.log(`Schedule entries:        ${results.schedule_entries_created}`);
  console.log('');

  if (results.members_failed.length) {
    console.log('Member failures:');
    results.members_failed.forEach((f) => console.log(`   - ${f.reg}: ${f.error}`));
    console.log('');
  }
  if (results.loans_failed.length) {
    console.log('Loan failures:');
    results.loans_failed.forEach((f) => console.log(`   - ${f.reg}/${f.ref}: ${f.error}`));
    console.log('');
  }

  console.log('Next steps:');
  console.log('   1. Verify member count in DB: SELECT COUNT(*) FROM members WHERE role = \'Member\';');
  console.log('   2. Reconcile savings total: SELECT SUM(amount) FROM ledger_entries WHERE transaction_type = \'CONTRIBUTION\';');
  console.log('   3. Send auth invite emails (separate script — to be written).');
}

main().catch((err) => {
  console.error('❌ Import failed:', err);
  process.exit(1);
});