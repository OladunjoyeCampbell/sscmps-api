// fix-users.mjs
import dotenv from 'dotenv';
dotenv.config();

import { createClient } from '@supabase/supabase-js';

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  }
);

const users = [
  'staff002@csnigerpoly.com',
  'staff003@csnigerpoly.com',
  'trustee1@csnigerpoly.com',
  'trustee2@csnigerpoly.com',
  'trustee3@csnigerpoly.com',
];

console.log('═══════════════════════════════════════');
console.log('   Fix Users - Password Reset');
console.log('═══════════════════════════════════════\n');

// List all users first
const { data: { users: allUsers }, error: listError } = await sb.auth.admin.listUsers();

if (listError) {
  console.error('❌ Failed to list users:', listError.message);
  process.exit(1);
}

console.log(`Found ${allUsers.length} total users\n`);

for (const email of users) {
  const user = allUsers.find((u) => u.email === email);

  if (!user) {
    console.log(`⚠️  ${email} — Not found, skipping`);
    continue;
  }

  // Update password AND ensure email is confirmed
  const { data, error } = await sb.auth.admin.updateUserById(user.id, {
    password: 'Test1234!',
    email_confirm: true,
  });

  if (error) {
    console.log(`❌ ${email} — ${error.message}`);
  } else {
    console.log(`✅ ${email} — Password reset, email confirmed`);
  }
}

console.log('\n✅ All users updated.');