const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");

const cases = [
  ["customer-register.html", "registerForm"],
  ["advertiser-register.html", "registerForm"],
  ["advertiser-reset-password.html", "passwordForm"],
  ["supplier-reset-password.html", "newPasswordForm"],
  ["customer-login.html", "newPasswordForm"]
];

for (const [file, formId] of cases) {
  test(file + " loads the shared policy and contains the intended password form", () => {
    const html = fs.readFileSync(file, "utf8");
    assert.match(html, /<script src="password-policy\.js"><\/script>/);
    assert.match(html, new RegExp('<form\\b[^>]*id="' + formId + '"'));
    assert.match(html, /autocomplete="new-password"/);
  });
}

test("customer sign-in form remains outside the new-password policy", () => {
  const html = fs.readFileSync("customer-login.html", "utf8");
  const loginForm = html.match(/<form id="loginForm">[\s\S]*?<\/form>/);
  assert.ok(loginForm);
  assert.match(loginForm[0], /autocomplete="current-password"/);
  assert.doesNotMatch(loginForm[0], /password-policy/);
});

test("supplier email-request form remains separate from password reset form", () => {
  const html = fs.readFileSync("supplier-reset-password.html", "utf8");
  assert.match(html, /<form id="resetForm">/);
  assert.match(html, /<form id="newPasswordForm">/);
});
