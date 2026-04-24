import { test } from "node:test";
import { strict as assert } from "node:assert";
import { listNotes, searchNotes, listFolders, findNoteByTitle } from "../src/db.js";
import { captureStdout } from "./test-utils.js";

test("listFolders: reads folders without stdout leak", async () => {
  const { result, stdout } = await captureStdout(() => listFolders());
  assert.equal(stdout.length, 0);
  assert.ok(Array.isArray(result));
});

test("listNotes: respects limit and has no stdout leak", async () => {
  const { result, stdout } = await captureStdout(() => listNotes(undefined, 3));
  assert.equal(stdout.length, 0);
  assert.ok(result.length <= 3);
});

test("listNotes: excludes null-folder orphan notes", () => {
  const notes = listNotes();
  assert.ok(
    notes.every((n) => n.folder !== ""),
    "all notes must have a non-empty folder name"
  );
});

test("listNotes: excludes notes from Recently Deleted folder", () => {
  const notes = listNotes();
  assert.ok(
    notes.every((n) => n.folder !== "Recently Deleted"),
    "no notes from Recently Deleted should appear in results"
  );
});

test("searchNotes: runs LIKE search without stdout leak", async () => {
  const { result, stdout } = await captureStdout(() => searchNotes("a", 3));
  assert.equal(stdout.length, 0);
  assert.ok(result.length <= 3);
});

test("findNoteByTitle: roundtrips via listNotes without stdout leak", async () => {
  const sample = listNotes(undefined, 1)[0];
  if (!sample) return;
  const { result, stdout } = await captureStdout(() =>
    findNoteByTitle(sample.title, sample.folder || undefined)
  );
  assert.equal(stdout.length, 0);
  assert.ok(result);
  assert.equal(result!.identifier, sample.identifier);
});
