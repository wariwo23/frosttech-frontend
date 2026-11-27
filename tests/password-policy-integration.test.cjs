const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const pageCases = [
  ["customer-register.html", "registerForm", "password"],
  ["advertiser-register.html", "registerForm", "password"],
  ["advertiser-reset-password.html", "passwordForm", "newPassword"],
  ["supplier-reset-password.html", "newPasswordForm", "newPassword"],
  ["customer-login.html", "newPasswordForm", "newPassword"]
];

for (const [file, formId, passwordId] of pageCases) {
  test(file + " loads the shared password policy on its new-password form", () => {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /<script src="password-policy\.js"><\/script>/);
    assert.match(html, new RegExp('<form\\b[^>]*id="' + formId + '"'));
    assert.match(html, new RegExp('id="' + passwordId + '"[\\s\\S]{0,120}autocomplete="new-password"|autocomplete="new-password"[\\s\\S]{0,120}id="' + passwordId + '"'));
  });
}

test("customer sign-in continues to use current-password and existing login form", () => {
  const html = fs.readFileSync("customer-login.html", "utf8");
  const loginForm = html.match(/<form id="loginForm">[\s\S]*?<\/form>/);
  assert.ok(loginForm);
  assert.match(loginForm[0], /autocomplete="current-password"/);
  assert.doesNotMatch(loginForm[0], /minlength="12"/);
});

test("supplier email-reset form remains separate from the new-password form", () => {
  const html = fs.readFileSync("supplier-reset-password.html", "utf8");
  const requestForm = html.match(/<form id="resetForm">[\s\S]*?<\/form>/);
  const newPasswordForm = html.match(/<form id="newPasswordForm">[\s\S]*?<\/form>/);
  assert.ok(requestForm);
  assert.ok(newPasswordForm);
  assert.doesNotMatch(requestForm[0], /type="password"/);
  assert.match(newPasswordForm[0], /id="newPassword"/);
});

test("shared policy targets only the intended new-password forms", () => {
  const source = fs.readFileSync("password-policy.js", "utf8");
  assert.match(source, /\["registerForm", "passwordForm", "newPasswordForm"\]/);
  assert.match(source, /confirmInput\.validity && !confirmInput\.validity\.valid/);
});

test("registration pages retain their original submit handlers", () => {
  for (const file of ["customer-register.html", "advertiser-register.html"]) {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /addEventListener\(["']submit["']/);
    assert.match(html, /password-policy\.js/);
  }
});

test("password reset pages retain Supabase updateUser handlers", () => {
  for (const file of ["customer-login.html", "advertiser-reset-password.html", "supplier-reset-password.html"]) {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /updateUser\s*\(/);
    assert.match(html, /password-policy\.js/);
  }
});
