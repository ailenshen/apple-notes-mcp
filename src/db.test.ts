import { test } from "node:test";
import { strict as assert } from "node:assert";
import { listNotes, searchNotes, listFolders, findNoteByTitle } from "./db.js";
import { captureStdout } from "./test-utils.js";

function summarize(value: unknown, max = 240): string {
  const s = JSON.stringify(value);
  if (s === undefined) return String(value);
  return s.length > max ? s.slice(0, max) + "…" : s;
}

test("listFolders: reads folders, writes 0 bytes to stdout", async () => {
  const input = {};
  const { result, stdout } = await captureStdout(() => listFolders());

  console.log("listFolders input:", summarize(input));
  console.log("listFolders output:", summarize(result));
  console.log("listFolders stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0, `stdout leak: ${JSON.stringify(stdout)}`);
  assert.ok(Array.isArray(result), "listFolders should return an array");
});

test("listNotes(undefined, 3): reads at most 3 notes, writes 0 bytes to stdout", async () => {
  const input = { folder: undefined, limit: 3 };
  const { result, stdout } = await captureStdout(() =>
    listNotes(input.folder, input.limit)
  );

  console.log("listNotes input:", summarize(input));
  console.log(
    "listNotes output (count + first row):",
    summarize({ count: result.length, first: result[0] ?? null })
  );
  console.log("listNotes stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0, `stdout leak: ${JSON.stringify(stdout)}`);
  assert.ok(Array.isArray(result));
  assert.ok(result.length <= 3, "limit=3 should cap the result");
});

test("searchNotes('a', 3): runs LIKE search, writes 0 bytes to stdout", async () => {
  const input = { query: "a", limit: 3 };
  const { result, stdout } = await captureStdout(() =>
    searchNotes(input.query, input.limit)
  );

  console.log("searchNotes input:", summarize(input));
  console.log(
    "searchNotes output (count + first row):",
    summarize({ count: result.length, first: result[0] ?? null })
  );
  console.log("searchNotes stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0, `stdout leak: ${JSON.stringify(stdout)}`);
  assert.ok(Array.isArray(result));
  assert.ok(result.length <= 3, "limit=3 should cap the result");
});

test("findNoteByTitle: roundtrips via listNotes, writes 0 bytes to stdout", async () => {
  // Pick any existing note to use as the lookup target.
  const sample = listNotes(undefined, 1)[0];
  if (!sample) {
    console.log("findNoteByTitle: no notes available, skipping roundtrip");
    return;
  }

  const input = { title: sample.title, folder: sample.folder || undefined };
  const { result, stdout } = await captureStdout(() =>
    findNoteByTitle(input.title, input.folder)
  );

  console.log("findNoteByTitle input:", summarize(input));
  console.log("findNoteByTitle output:", summarize(result));
  console.log("findNoteByTitle stdout bytes during call:", stdout.length);

  assert.equal(stdout.length, 0, `stdout leak: ${JSON.stringify(stdout)}`);
  assert.ok(result, "should find the note we just listed");
  assert.equal(result!.identifier, sample.identifier);
});
