import { test } from "node:test";
import { strict as assert } from "node:assert";
import { getNoteBody } from "./applescript.js";
import { listNotes } from "./db.js";
import { captureStdout } from "./test-utils.js";

function summarize(value: unknown, max = 240): string {
  const s = typeof value === "string" ? value : JSON.stringify(value);
  if (s === undefined) return String(value);
  return s.length > max ? s.slice(0, max) + "…" : s;
}

test("getNoteBody: reads a real note via osascript, writes 0 bytes to stdout", async () => {
  const sample = listNotes(undefined, 1)[0];
  if (!sample) {
    console.log("getNoteBody: no notes available, skipping");
    return;
  }

  const input = { title: sample.title, folder: sample.folder || undefined };
  const { result, stdout } = await captureStdout(() =>
    getNoteBody(input.title, input.folder)
  );

  console.log("getNoteBody input:", summarize(input));
  console.log("getNoteBody output (first 200 chars):", summarize(result, 200));
  console.log("getNoteBody stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0, `stdout leak: ${JSON.stringify(stdout)}`);
  assert.equal(typeof result, "string");
});
