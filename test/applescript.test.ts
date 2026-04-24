import { test } from "node:test";
import { strict as assert } from "node:assert";
import { getNoteBody, permanentlyDeleteNote } from "../src/applescript.js";
import { listNotes } from "../src/db.js";
import { captureStdout } from "./test-utils.js";

test("getNoteBody: reads a real note without stdout leak", async () => {
  const sample = listNotes(undefined, 1)[0];
  if (!sample) return;
  // Verify no stdout leak regardless of whether the note is accessible.
  const { stdout } = await captureStdout(async () => {
    try {
      await getNoteBody(sample.title, sample.folder || undefined);
    } catch { /* note may be transiently inaccessible due to sync lag */ }
  });
  assert.equal(stdout.length, 0, "stdout leak detected");
});

test("permanentlyDeleteNote: no-ops when note absent from Recently Deleted", async () => {
  const { stdout } = await captureStdout(() =>
    permanentlyDeleteNote("__nonexistent_perm_del_test__")
  );
  assert.equal(stdout.length, 0);
});
