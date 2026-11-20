import { readFileSync } from "node:fs";
import { Script } from "node:vm";

const files = ["admin-independent-quotations.html", "direct-quotation.html", "direct-order-sourcing.html", "finance-admin.html"];
let checked = 0;
for (const file of files) {
  const html = readFileSync(file, "utf8");
  const matches = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
    .filter((match) => !/\bsrc\s*=/.test(match[1]));
  if (matches.length === 0) throw new Error("No inline JavaScript found in " + file);
  for (let index = 0; index < matches.length; index++) {
    new Script(matches[index][2], { filename: file + ":inline-script-" + (index + 1) });
    checked++;
  }
  console.log("Validated " + matches.length + " inline script(s) in " + file);
}
console.log("Validated " + checked + " inline script(s) total.");
