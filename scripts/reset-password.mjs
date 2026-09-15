// reset-password.mjs
import dotenv from 'dotenv';
dotenv.config();
import { createClient } from '@supabase/supabase-js';
import readline from 'readline';

const sb = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

const question = (q) => new Promise((resolve) => rl.question(q, resolve));

const run = async () => {
  console.log('\n═══════════════════════════════════════');
  console.log('   Reset Member Password');
  console.log('═══════════════════════════════════════\n');

  const email = process.argv[2] || (await question('Member email: '));
  const newPassword = process.argv[3] || (await question('New password: '));

  if (!email || !newPassword) {
    console.error('❌ Email and password are required');
    rl.close();
    process.exit(1);
  }

  const { data: { users }, error: listError } = await sb.auth.admin.listUsers();

  if (listError) {
    console.error('❌ List error:', listError.message);
    rl.close();
    process.exit(1);
  }

  const user = users.find((u) => u.email === email);

  if (!user) {
    console.error(`❌ No user found with email: ${email}`);
    rl.close();
    process.exit(1);
  }

  const { error } = await sb.auth.admin.updateUserById(user.id, {
    password: newPassword,
    email_confirm: true,
  });

  if (error) {
    console.error(`❌ Reset failed: ${error.message}`);
    rl.close();
    process.exit(1);
  }

  console.log(`✅ Password reset for: ${email}`);
  console.log(`   New password: ${newPassword}`);
  console.log('   ⚠️  Ask member to change password after login');

  rl.close();
};

run();