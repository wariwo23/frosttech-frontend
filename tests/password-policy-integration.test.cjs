const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const pageCases = [
  ["customer-register.html", "registerForm", "password"],
  ["supplier-register.html", "registrationForm", "password"],
  ["guest-register.html", "guestForm", "password"],
  ["advertiser-register.html", "registerForm", "password"],
  ["advertiser-reset-password.html", "passwordForm", "newPassword"],
  ["supplier-reset-password.html", "newPasswordForm", "newPassword"],
  ["customer-login.html", "newPasswordForm", "newPassword"]
];

for (const [file, formId, passwordId] of pageCases) {
  test(file + " loads shared password policy on the intended form", () => {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /<script src="password-policy\.js"><\/script>/);
    assert.ok(html.includes('id="' + formId + '"'));
    assert.ok(html.includes('id="' + passwordId + '"'));
    assert.ok(html.includes('autocomplete="new-password"'));
  });
}

test("customer sign-in remains outside the new-password policy", () => {
  const html = fs.readFileSync("customer-login.html", "utf8");
  const loginForm = html.match(/<form id="loginForm">[\s\S]*?<\/form>/);
  assert.ok(loginForm);
  assert.match(loginForm[0], /autocomplete="current-password"/);
  assert.doesNotMatch(loginForm[0], /minlength="12"/);
});

test("supplier email-reset request is separate from new-password form", () => {
  const html = fs.readFileSync("supplier-reset-password.html", "utf8");
  const requestForm = html.match(/<form id="resetForm">[\s\S]*?<\/form>/);
  const newPasswordForm = html.match(/<form id="newPasswordForm">[\s\S]*?<\/form>/);
  assert.ok(requestForm);
  assert.ok(newPasswordForm);
  assert.doesNotMatch(requestForm[0], /type="password"/);
  assert.match(newPasswordForm[0], /id="newPassword"/);
});

test("all registration and reset form IDs are handled by shared policy", () => {
  const source = fs.readFileSync("password-policy.js", "utf8");
  assert.match(source, /\["registerForm", "registrationForm", "guestForm", "passwordForm", "newPasswordForm"\]/);
});

test("registration pages retain their existing submit handlers", () => {
  for (const file of ["customer-register.html", "supplier-register.html", "guest-register.html", "advertiser-register.html"]) {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /addEventListener\(["']submit["']/);
    assert.match(html, /password-policy\.js/);
  }
});

test("password reset pages retain their Supabase updateUser handlers", () => {
  for (const file of ["customer-login.html", "advertiser-reset-password.html", "supplier-reset-password.html"]) {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /updateUser\s*\(/);
    assert.match(html, /password-policy\.js/);
  }
});
