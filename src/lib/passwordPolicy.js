// src/lib/passwordPolicy.js
//
// Backend password validation. Mirrors the frontend policy, but the
// backend is the source of truth — the frontend check is a UX
// convenience, not a security boundary.

export const MIN_PASSWORD_LENGTH = 12;
export const MAX_PASSWORD_LENGTH = 128;

// Expanded list — top common passwords plus Nigeria-specific and
// system-specific terms. Kept inline so the Worker has no file deps.
const COMMON_PASSWORDS = new Set([
  'password', 'password1', 'password12', 'password123', 'password1234',
  'password12345', 'passw0rd', 'p@ssword', 'p@ssw0rd', 'pass1234',
  '123456', '1234567', '12345678', '123456789', '1234567890',
  '12345678901', '123456789012', '0123456789', '0987654321',
  'qwerty', 'qwerty123', 'qwertyuiop', 'qwerty123456', 'asdfgh',
  'asdfghjkl', 'zxcvbnm', 'qazwsx', '1q2w3e4r', '1qaz2wsx',
  'admin', 'admin123', 'administrator', 'letmein', 'letmein123',
  'welcome', 'welcome1', 'welcome123', 'welcome2024', 'welcome2025',
  'monkey', 'monkey123', 'dragon', 'sunshine', 'iloveyou',
  'princess', 'football', 'baseball', 'basketball', 'superman',
  'trustno1', 'master', 'shadow', 'master123', 'changeme',
  'abc123', 'abcd1234', 'abcdefgh', 'abcdefghi', 'abcdefghij',
  '111111', '1111111', '11111111', '111111111111', '000000000000',
  'nigeria', 'nigeria123', 'abuja', 'lagos', 'kano',
  'sscmps', 'sscmps123', 'cooperative', 'polytechnic', 'zungeru',
]);

export function validatePassword(password, { email, firstName, lastName, staffId } = {}) {
  const errors = [];

  if (!password || typeof password !== 'string') {
    return { valid: false, errors: ['Password is required'] };
  }

  if (password.length < MIN_PASSWORD_LENGTH) {
    errors.push(`Password must be at least ${MIN_PASSWORD_LENGTH} characters`);
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    errors.push(`Password must be ${MAX_PASSWORD_LENGTH} characters or fewer`);
  }

  const lower = password.toLowerCase();

  if (COMMON_PASSWORDS.has(lower)) {
    errors.push('This password is on the list of most-common passwords');
  }

  const personalTokens = [email, firstName, lastName, staffId]
    .filter(Boolean)
    .map((s) => String(s).toLowerCase().split('@')[0]);

  for (const token of personalTokens) {
    if (token.length >= 3 && lower.includes(token)) {
      errors.push('Password must not contain your name, email, or staff ID');
      break;
    }
  }

  if (/^(.)\1{5,}$/.test(password)) {
    errors.push('Password cannot be a single character repeated');
  }

  if (/^(012|123|234|345|456|567|678|789|890|abc|bcd|cde|def){2,}/i.test(password)) {
    errors.push('Password cannot be a simple sequence');
  }

  return { valid: errors.length === 0, errors };
}