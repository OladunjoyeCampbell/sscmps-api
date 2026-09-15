// test-supabase.mjs
import dns from 'dns';
dns.setDefaultResultOrder('ipv4first');

import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';

dotenv.config();

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY
);

console.log('Testing Supabase connection...');
console.log('URL:', process.env.SUPABASE_URL);
console.log('Key length:', process.env.SUPABASE_SERVICE_ROLE_KEY?.length);

// Test 1: List users (uses service_role)
console.log('\nTest 1: listUsers');
try {
  const { data, error } = await supabase.auth.admin.listUsers();
  if (error) {
    console.error('❌ Error:', error.message);
    console.error('   Status:', error.status);
    console.error('   Full:', JSON.stringify(error, null, 2));
  } else {
    console.log('✅ Success — users:', data.users.length);
  }
} catch (err) {
  console.error('❌ Exception:', err.message);
  console.error('   Cause:', err.cause?.message || err.cause);
  console.error('   Stack:', err.stack);
}

// Test 2: Simple query to members table
console.log('\nTest 2: Query members table');
try {
  const { data, error } = await supabase
    .from('members')
    .select('id, staff_id, email')
    .limit(3);
  if (error) {
    console.error('❌ Error:', error.message);
  } else {
    console.log('✅ Success — rows:', data.length);
    console.log('   Sample:', data);
  }
} catch (err) {
  console.error('❌ Exception:', err.message);
  console.error('   Cause:', err.cause?.message || err.cause);
}