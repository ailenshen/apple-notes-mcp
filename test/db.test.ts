import { test } from "node:test";
import { strict as assert } from "node:assert";
import { gzipSync } from "node:zlib";
import { listNotes, searchNotes, listFolders, findNoteByTitle, extractNoteText } from "../src/db.js";
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

test("searchNotes: runs full-text search without stdout leak", async () => {
  const { result, stdout } = await captureStdout(() => searchNotes("a", 3));
  assert.equal(stdout.length, 0);
  assert.ok(result.length <= 3);
});

// Build NoteStoreProto{ document(2){ note(3){ note_text(2) } } } by hand.
function lenField(fieldNo: number, payload: Buffer): Buffer {
  return Buffer.concat([Buffer.from([(fieldNo << 3) | 2, payload.length]), payload]);
}

test("extractNoteText: decodes the plain text field from gzip + protobuf", () => {
  const text = "Title\nbody with 中文";
  const proto = lenField(2, lenField(3, Buffer.concat([
    Buffer.from([0x08, 0x01]), // unrelated varint field before the text
    lenField(2, Buffer.from(text, "utf8")),
  ])));
  assert.equal(extractNoteText(gzipSync(proto)), text);
});

test("extractNoteText: returns empty string for null or garbage data", () => {
  assert.equal(extractNoteText(null), "");
  assert.equal(extractNoteText(new Uint8Array([1, 2, 3])), "");
});

test("searchNotes: finds a note by a word that only appears in its body", (t) => {
  // Pick a real note whose body has a long word absent from its title and snippet.
  for (const n of listNotes(undefined, 200)) {
    const hit = searchNotes(n.title, 1)[0];
    if (!hit || hit.title !== n.title) continue;
    const words = (hit.excerpt.match(/[A-Za-z]{8,}/g) ?? []).filter(
      (w) => !n.title.toLowerCase().includes(w.toLowerCase()) && !n.snippet.toLowerCase().includes(w.toLowerCase())
    );
    if (words.length === 0) continue;
    const found = searchNotes(`${words[0]}`).some((h) => h.identifier === n.identifier);
    assert.ok(found, "body-only word should find its note");
    return;
  }
  t.skip("no note with a body-only English word among the 200 newest notes");
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
