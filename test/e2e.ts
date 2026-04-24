/**
 * Integration test: create → list → get → update → get → delete → get(404)
 *
 * Uses a UUID-suffixed title to avoid collision with existing notes.
 */

import { randomUUID } from "crypto";
import { listNotes, findNoteByTitle } from "../src/db.js";
import { getNoteBody, createNote, updateNote, deleteNote } from "../src/applescript.js";

const ID = randomUUID().slice(0, 8);
const TITLE_V1 = `MCP_Test_${ID}`;
const TITLE_V2 = `MCP_Test_v2_${ID}`;
const BODY_V1 = `Body v1 ${ID}`;
const BODY_V2 = `Body **v2** ${ID}`;
const FOLDER = "Notes";

let passed = 0;
let failed = 0;

function assert(ok: boolean, msg: string) {
  ok ? passed++ : failed++;
  console.log(ok ? `  ✅ ${msg}` : `  ❌ ${msg}`);
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitFor(check: () => boolean | Promise<boolean>, label: string, retries = 15) {
  for (let i = 0; i < retries; i++) {
    if (await check()) return true;
    process.stdout.write(`  ⏳ ${label} (${i + 1}/${retries})\r`);
    await sleep(1000);
  }
  process.stdout.write("\n");
  return check();
}

let cleanupTitle: string | null = null;

async function cleanup() {
  if (!cleanupTitle) return;
  try { await deleteNote(cleanupTitle, FOLDER); } catch { /* already gone */ }
}

async function main() {
  console.log(`\n🧪 Integration Test (ID: ${ID})\n`);
  const beforeCount = listNotes(FOLDER).length;

  try {
    // 1. Create
    console.log("── Create ──");
    const t1 = await createNote(`# ${TITLE_V1}\n\n${BODY_V1}`);
    cleanupTitle = t1;
    assert(t1 === TITLE_V1, `created "${t1}"`);

    // 2. List — should include the new note
    console.log("\n── List ──");
    await waitFor(() => !!findNoteByTitle(TITLE_V1), "SQLite sync");
    const list = listNotes(FOLDER);
    assert(list.some((n) => n.title === TITLE_V1), "appears in listNotes");
    assert(list.every((n) => !("has_checklist" in n)), "no has_checklist field");

    // 3. Get — should return Markdown (not HTML)
    console.log("\n── Get ──");
    const body1 = await getNoteBody(TITLE_V1, FOLDER);
    assert(body1.includes(BODY_V1), "body contains v1 text");
    assert(!body1.includes("<div>"), "body is not HTML");

    // 4. Update — should preserve folder and permanently remove old version
    console.log("\n── Update ──");
    const t2 = await updateNote(TITLE_V1, `# ${TITLE_V2}\n\n${BODY_V2}`, FOLDER);
    cleanupTitle = t2;
    assert(t2 === TITLE_V2, `updated title → "${t2}"`);

    // 5. Get updated note and verify no duplicate old versions
    console.log("\n── Get (after update) ──");
    let body2 = "";
    const accessible = await waitFor(async () => {
      try { body2 = await getNoteBody(TITLE_V2, FOLDER); return true; } catch { return false; }
    }, "note accessible via AppleScript");
    assert(accessible, `note accessible: "${TITLE_V2}"`);
    assert(body2.includes(ID), "body contains test ID");
    assert(body2.includes("v2"), "body contains v2 keyword");
    await waitFor(() => !!findNoteByTitle(TITLE_V2), "SQLite sync for v2");
    const row = findNoteByTitle(TITLE_V2)!;
    assert(row.folder === FOLDER, `still in folder "${row.folder}"`);

    const afterList = listNotes(FOLDER);
    const v1Count = afterList.filter((n) => n.title === TITLE_V1).length;
    const v2Count = afterList.filter((n) => n.title === TITLE_V2).length;
    assert(v1Count === 0, "old version not in list after update");
    assert(v2Count === 1, "new version appears exactly once after update");

    // 6. Delete
    console.log("\n── Delete ──");
    await deleteNote(TITLE_V2, FOLDER);
    cleanupTitle = null;

    // 7. Get deleted — should throw
    console.log("\n── Get (after delete) ──");
    let gone = false;
    try { await getNoteBody(TITLE_V2, FOLDER); } catch { gone = true; }
    assert(gone, "getNoteBody throws for deleted note");
    const sqlGone = await waitFor(() => !findNoteByTitle(TITLE_V2), "deleted note gone");
    assert(sqlGone, "deleted note gone from SQLite");

    // Side-effect check (wait for deferred Imported Notes cleanup timers to fire)
    console.log("\n── Side effects ──");
    await sleep(4000);
    const afterCount = listNotes(FOLDER).length;
    assert(afterCount === beforeCount, `note count unchanged: ${beforeCount} → ${afterCount}`);
  } catch (e) {
    console.error("\n💥", e);
    failed++;
  } finally {
    await cleanup();
  }

  console.log(`\n${"═".repeat(40)}`);
  console.log(`  Passed: ${passed}  Failed: ${failed}`);
  console.log(`${"═".repeat(40)}\n`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
