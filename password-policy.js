(function () {
  "use strict";

  const MIN_LENGTH = 12;
  const MAX_BYTES = 72;
  const FORM_IDS = ["registerForm", "passwordForm", "newPasswordForm"];

  function countCharacters(value) {
    return Array.from(value).length;
  }

  function countUtf8Bytes(value) {
    return new TextEncoder().encode(value).length;
  }

  function getStatusNode(form, passwordInput) {
    let status = form.querySelector("[data-ft-password-status]");
    if (!status) {
      status = document.createElement("p");
      status.setAttribute("data-ft-password-status", "");
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      status.style.cssText = "margin:7px 0 12px;color:#526579;font-size:12px;line-height:1.5";
      const anchor = passwordInput.closest(".field, .form-group") || passwordInput.parentElement;
      anchor.insertAdjacentElement("afterend", status);
    }
    return status;
  }

  function validate(form, passwordInput, confirmInput, status) {
    const password = passwordInput.value;
    const length = countCharacters(password);
    const bytes = countUtf8Bytes(password);
    let message = "";

    if (length < MIN_LENGTH) {
      message = "Use at least 12 characters. A memorable passphrase is a good choice.";
    } else if (bytes > MAX_BYTES) {
      message = "Your password must not exceed Supabase’s 72-byte password limit. Use fewer characters or simpler characters.";
    } else if (!password.trim()) {
      message = "Your password cannot contain only spaces.";
    } else if (confirmInput && password !== confirmInput.value) {
      message = "The passwords do not match.";
    }

    passwordInput.setCustomValidity(
      bytes > MAX_BYTES || (length > 0 && length < MIN_LENGTH) || !password.trim()
        ? message : ""
    );
    if (confirmInput) {
      confirmInput.setCustomValidity(
        confirmInput.value && password !== confirmInput.value
          ? "The passwords do not match." : ""
      );
    }

    if (status) {
      status.textContent = message || (length >= MIN_LENGTH
        ? "Password length looks good. Avoid reusing a password from another service."
        : "Password guidance: 12 or more characters, up to 72 UTF-8 bytes. Spaces and passphrases are allowed.");
      status.style.color = message ? "#a11919" : "#526579";
    }
    return !message;
  }

  function attach(form) {
    const passwordInput = form.querySelector('input[type="password"][autocomplete="new-password"], input[type="password"]');
    if (!passwordInput) return;

    const confirmInput = form.querySelector(
      'input[id*="confirm" i], input[name*="confirm" i]'
    );
    passwordInput.minLength = MIN_LENGTH;
    passwordInput.maxLength = 72;
    passwordInput.setAttribute("aria-describedby",
      (passwordInput.getAttribute("aria-describedby") || "").trim());

    if (confirmInput) {
      confirmInput.minLength = MIN_LENGTH;
      confirmInput.maxLength = 72;
    }

    const status = getStatusNode(form, passwordInput);
    const update = () => validate(form, passwordInput, confirmInput, status);

    passwordInput.addEventListener("input", update);
    if (confirmInput) confirmInput.addEventListener("input", update);

    form.addEventListener("submit", function (event) {
      if (!update()) {
        event.preventDefault();
        event.stopImmediatePropagation();
        passwordInput.reportValidity();
        if (confirmInput && passwordInput.value === confirmInput.value) {
          confirmInput.reportValidity();
        }
      }
    }, true);
  }

  document.addEventListener("DOMContentLoaded", function () {
    FORM_IDS.forEach(function (id) {
      const form = document.getElementById(id);
      if (form) attach(form);
    });
  });
})();