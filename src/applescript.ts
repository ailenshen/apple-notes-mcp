import { execFile } from "child_process";
import { writeFile, unlink } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";
import { randomUUID } from "crypto";
import TurndownService from "turndown";
import { findNoteByTitle } from "./db.js";

const turndown = new TurndownService({
  headingStyle: "atx",
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
});

function runAppleScript(script: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile("osascript", ["-e", script], { timeout: 30000 }, (err, stdout, stderr) => {
      if (err) {
        reject(new Error(`AppleScript error: ${err.message}\n${stderr}`));
      } else {
        resolve(stdout.trim());
      }
    });
  });
}

export async function getNoteBody(title: string, folder?: string): Promise<string> {
  const folderClause = folder
    ? `of folder ${JSON.stringify(folder)}`
    : "";

  // Try to find by exact title; if folder is given, scope to that folder
  const script = `
tell application "Notes"
  set matchedNotes to (every note ${folderClause} whose name is ${JSON.stringify(title)})
  if (count of matchedNotes) = 0 then
    error "Note not found: ${title.replace(/"/g, '\\"')}"
  end if
  return body of item 1 of matchedNotes
end tell
`;
  const html = await runAppleScript(script);
  return turndown.turndown(html);
}

export async function deleteNote(title: string, folder?: string): Promise<void> {
  const folderClause = folder
    ? `of folder ${JSON.stringify(folder)}`
    : "";

  const script = `
tell application "Notes"
  set matchedNotes to (every note ${folderClause} whose name is ${JSON.stringify(title)})
  if (count of matchedNotes) = 0 then
    error "Note not found: ${title.replace(/"/g, '\\"')}"
  end if
  delete item 1 of matchedNotes
end tell
`;
  await runAppleScript(script);
}

export async function createNote(
  markdown: string,
  targetFolder?: string
): Promise<string> {
  // 1. Extract title from first line
  const firstLine = markdown.split("\n")[0].replace(/^#\s*/, "").trim();
  const title = firstLine || "Untitled";

  // 2. Write temp .md file
  const tmpPath = join(tmpdir(), `note-${randomUUID()}.md`);
  await writeFile(tmpPath, markdown, "utf-8");

  try {
    // 3. Remember current frontmost app, open file, auto-confirm Import sheet
    const importScript = `
-- Remember which app is currently active
tell application "System Events"
  set frontApp to name of first process whose frontmost is true
end tell

do shell script "open -g -a Notes " & quoted form of "${tmpPath}"
delay 0.5

tell application "System Events"
  tell process "Notes"
    repeat 20 times
      repeat with w in every window
        try
          repeat with s in every sheet of w
            if (name of every button of s) contains "Import" then
              click button "Import" of s
              return frontApp
            end if
          end repeat
        end try
      end repeat
      delay 0.2
    end repeat
  end tell
end tell

return "no_sheet"
`;
    const importResult = await runAppleScript(importScript);

    if (importResult === "no_sheet") {
      throw new Error("Failed to confirm Import sheet within timeout");
    }

    const frontApp = importResult;

    // 4. Wait briefly for Notes to process
    await new Promise((r) => setTimeout(r, 1000));

    // 5. Move to target folder + clean up Imported Notes + show note + restore frontmost app
    const finalFolder = targetFolder || "Notes";
    const postImportScript = `
tell application "Notes"
  try
    set importedFolder to folder "Imported Notes"
    set matchedNotes to (every note of importedFolder whose name is ${JSON.stringify(title)})
    if (count of matchedNotes) > 0 then
      set targetNote to item 1 of matchedNotes
      move targetNote to folder ${JSON.stringify(finalFolder)}
      -- Select the note in Notes UI
      show targetNote
    end if
    -- Clean up empty Imported Notes folder
    if (count of notes of importedFolder) = 0 then
      delete importedFolder
    end if
  end try
end tell

-- Restore the original frontmost app
tell application ${JSON.stringify(frontApp)} to activate
`;
    try {
      await runAppleScript(postImportScript);
    } catch {
      // best-effort: Imported Notes folder may not exist
    }

    return title;
  } finally {
    // 6. Delete temp file
    try {
      await unlink(tmpPath);
    } catch {
      // ignore
    }
  }
}

export async function updateNote(
  title: string,
  markdown: string,
  folder?: string
): Promise<string> {
  // 1. Find the note's current folder via SQLite
  const row = findNoteByTitle(title, folder);
  if (!row) throw new Error(`Note not found: ${title}`);
  const originalFolder = row.folder || "Notes";

  // 2. Delete the old note
  await deleteNote(title, folder);

  // 3. Create the new note in the original folder
  return createNote(markdown, originalFolder);
}
