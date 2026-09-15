// create-officers.mjs
import dotenv from 'dotenv';
dotenv.config();

import { createClient } from '@supabase/supabase-js';

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

const officers = [
  { email: 'james.bake@csnigerpoly.com', staff_id: 'Staff011', name: 'Dr James Bake' },
  { email: 'elijah.santali@csnigerpoly.com', staff_id: 'Staff012', name: 'Mr Elijah Santali' },
  { email: 'nura.mohammed@csnigerpoly.com', staff_id: 'Staff013', name: 'Mr Nura Adamu Mohammed' },
  { email: 'enoch@csnigerpoly.com', staff_id: 'Staff010', name: 'Dr Enoch Gana' },
];

console.log('═══════════════════════════════════════');
console.log('   Create Officer Auth Users');
console.log('═══════════════════════════════════════\n');

for (const officer of officers) {
  console.log(`Processing: ${officer.name} (${officer.email})`);

  const { data, error } = await sb.auth.admin.createUser({
    email: officer.email,
    password: 'Test1234!',
    email_confirm: true,
    user_metadata: { staff_id: officer.staff_id, full_name: officer.name },
  });

  if (error) {
    if (error.message.includes('already been registered')) {
      // User exists — reset password and confirm
      const { data: { users } } = await sb.auth.admin.listUsers();
      const existing = users.find((u) => u.email === officer.email);

      if (existing) {
        await sb.auth.admin.updateUserById(existing.id, {
          password: 'Test1234!',
          email_confirm: true,
        });
        console.log(`  ✅ Reset password for existing user`);
      }
    } else {
      console.log(`  ❌ Failed: ${error.message}`);
    }
  } else {
    console.log(`  ✅ Created: ${data.user.id}`);

    // Link the auth user to the member record
    await sb
      .from('members')
      .update({ auth_user_id: data.user.id })
      .eq('staff_id', officer.staff_id);
    console.log(`  ✅ Linked to member`);
  }

  console.log('');
}

console.log('═══════════════════════════════════════');
console.log('   Done');
console.log('═══════════════════════════════════════');
console.log('\nLogin credentials for officers:');
console.log('  Password: Test1234!');
console.log('');
console.log('  Dr James Bake:        james.bake@csnigerpoly.com');
console.log('  Mr Elijah Santali:    elijah.santali@csnigerpoly.com');
console.log('  Mr Nura Mohammed:     nura.mohammed@csnigerpoly.com');
console.log('  Dr Enoch Gana:        enoch@csnigerpoly.com');