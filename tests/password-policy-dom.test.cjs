const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { JSDOM } = require("jsdom");
const { TextEncoder } = require("node:util");

const policy = fs.readFileSync(path.join(__dirname, "..", "password-policy.js"), "utf8");
const cases = [
  ["customer-register.html", "registerForm", "password"],
  ["supplier-register.html", "registrationForm", "password"],
  ["guest-register.html", "guestForm", "password"],
  ["advertiser-register.html", "registerForm", "password"],
  ["advertiser-reset-password.html", "passwordForm", "newPassword"],
  ["supplier-reset-password.html", "newPasswordForm", "newPassword"],
  ["customer-login.html", "newPasswordForm", "newPassword"]
];

function loadCase(file, formId, passwordId) {
  const html = fs.readFileSync(path.join(__dirname, "..", file), "utf8");
  const dom = new JSDOM(html, { runScripts: "outside-only", url: "https://frosttech.test/" });
  dom.window.TextEncoder = TextEncoder;
  dom.window.eval(policy);
  dom.window.document.dispatchEvent(new dom.window.Event("DOMContentLoaded"));
  const form = dom.window.document.getElementById(formId);
  const password = dom.window.document.getElementById(passwordId);
  assert.ok(form, file + " form exists");
  assert.ok(password, file + " password field exists");
  return { dom, form, password };
}

for (const [file, formId, passwordId] of cases) {
  test(file + " blocks a short password in the DOM", () => {
    const h = loadCase(file, formId, passwordId);
    h.password.value = "Short123";
    const event = new h.dom.window.Event("submit", { bubbles: true, cancelable: true });
    h.form.dispatchEvent(event);
    assert.equal(event.defaultPrevented, true);
    assert.match(h.password.validationMessage, /12 characters/);
    h.dom.window.close();
  });

  test(file + " accepts a valid passphrase in the DOM", () => {
    const h = loadCase(file, formId, passwordId);
    h.password.value = "correct horse battery";
    const confirm = h.form.querySelector('input[id*="confirm" i], input[name*="confirm" i]');
    if (confirm) confirm.value = h.password.value;
    const event = new h.dom.window.Event("submit", { bubbles: true, cancelable: true });
    h.form.dispatchEvent(event);
    assert.equal(event.defaultPrevented, false);
    h.dom.window.close();
  });
}

test("DOM validation marks the confirmation field when passwords differ", () => {
  const h = loadCase("supplier-register.html", "registrationForm", "password");
  h.password.value = "correct horse battery";
  const confirm = h.form.querySelector('input[id*="confirm" i], input[name*="confirm" i]');
  assert.ok(confirm);
  confirm.value = "another valid passphrase";
  const event = new h.dom.window.Event("submit", { bubbles: true, cancelable: true });
  h.form.dispatchEvent(event);
  assert.equal(event.defaultPrevented, true);
  assert.equal(confirm.validationMessage, "The passwords do not match.");
  h.dom.window.close();
});

test("DOM validation rejects a password over 72 UTF-8 bytes", () => {
  const h = loadCase("guest-register.html", "guestForm", "password");
  h.password.value = "é".repeat(37);
  const event = new h.dom.window.Event("submit", { bubbles: true, cancelable: true });
  h.form.dispatchEvent(event);
  assert.equal(event.defaultPrevented, true);
  assert.match(h.password.validationMessage, /72-byte/);
  h.dom.window.close();
});
