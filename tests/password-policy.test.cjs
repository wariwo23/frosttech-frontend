const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync("password-policy.js", "utf8");

class MockInput {
  constructor(value = "") {
    this.value = value;
    this.type = "password";
    this.minLength = 0;
    this.maxLength = 524288;
    this.attributes = {};
    this.listeners = {};
    this.validityMessage = "";
  }
  addEventListener(name, callback) {
    (this.listeners[name] ||= []).push(callback);
  }
  setAttribute(name, value) { this.attributes[name] = value; }
  getAttribute(name) { return this.attributes[name] || ""; }
  setCustomValidity(message) { this.validityMessage = message; }
  reportValidity() { this.reported = true; return !this.validityMessage; }
  dispatch(name) {
    for (const callback of this.listeners[name] || []) callback({ target: this });
  }
  closest() { return { insertAdjacentElement() {} }; }
}

class MockStatus {
  setAttribute() {}
  style = {};
  textContent = "";
}

class MockForm {
  constructor(password, confirmation) {
    this.password = password;
    this.confirmation = confirmation;
    this.listeners = {};
    this.status = null;
  }
  querySelector(selector) {
    if (selector === "[data-ft-password-status]") return this.status;
    if (selector.includes("input[type=\"password\"]")) return this.password;
    if (selector.includes("confirm")) return this.confirmation;
    return null;
  }
  addEventListener(name, callback, capture) {
    (this.listeners[name] ||= []).push({ callback, capture });
  }
  dispatchSubmit() {
    const event = {
      prevented: false,
      stopped: false,
      preventDefault() { this.prevented = true; },
      stopImmediatePropagation() { this.stopped = true; }
    };
    for (const entry of this.listeners.submit || []) entry.callback(event);
    return event;
  }
}

function makeHarness(passwordValue, confirmationValue = "") {
  const password = new MockInput(passwordValue);
  const confirmation = new MockInput(confirmationValue);
  const form = new MockForm(password, confirmation);
  const document = {
    getElementById(id) { return id === "registerForm" ? form : null; },
    createElement() { return new MockStatus(); },
    addEventListener(name, callback) {
      if (name === "DOMContentLoaded") callback();
    }
  };
  vm.runInNewContext(source, { document, TextEncoder });
  return { form, password, confirmation };
}

test("blocks an 8-character password", () => {
  const h = makeHarness("Abcdef1!");
  const result = h.form.dispatchSubmit();
  assert.equal(result.prevented, true);
  assert.match(h.password.validityMessage, /12 characters/);
});

test("blocks an 11-character password", () => {
  const h = makeHarness("Abcdef12345");
  assert.equal(h.form.dispatchSubmit().prevented, true);
});

test("accepts a 12-character passphrase with spaces", () => {
  const h = makeHarness("correct horse battery");
  assert.equal(h.form.dispatchSubmit().prevented, false);
  assert.equal(h.password.validityMessage, "");
});

test("accepts a 12-character mixed password", () => {
  const h = makeHarness("Abcdef123!@#");
  assert.equal(h.form.dispatchSubmit().prevented, false);
});

test("blocks mismatched confirmation", () => {
  const h = makeHarness("correct horse battery", "correct horse batteries");
  assert.equal(h.form.dispatchSubmit().prevented, true);
  assert.equal(h.confirmation.validityMessage, "The passwords do not match.");
});

test("accepts matching confirmation", () => {
  const value = "correct horse battery";
  const h = makeHarness(value, value);
  assert.equal(h.form.dispatchSubmit().prevented, false);
});

test("blocks passwords above 72 UTF-8 bytes", () => {
  const h = makeHarness("é".repeat(37)); // 74 UTF-8 bytes
  assert.equal(h.form.dispatchSubmit().prevented, true);
  assert.match(h.password.validityMessage, /72-byte/);
});

test("blocks whitespace-only passwords", () => {
  const h = makeHarness("            ");
  assert.equal(h.form.dispatchSubmit().prevented, true);
  assert.match(h.password.validityMessage, /only spaces/);
});

test("keeps the policy at 12 characters and 72 bytes", () => {
  assert.match(source, /const MIN_LENGTH = 12/);
  assert.match(source, /const MAX_BYTES = 72/);
});
