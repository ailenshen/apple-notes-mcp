#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { listNotes, searchNotes, listFolders, findNoteByTitle } from "./db.js";
import { getNoteBody, createNote, deleteNote } from "./applescript.js";

const server = new McpServer({
  name: "apple-notes",
  version: "1.0.0",
});

// --- list_notes ---
server.tool(
  "list_notes",
  "List notes from Apple Notes. Returns title, folder, dates, pinned status, snippet. Optionally filter by folder name and limit results.",
  {
    folder: z.string().optional().describe("Filter by folder name"),
    limit: z.number().optional().describe("Max number of notes to return"),
  },
  async ({ folder, limit }) => {
    try {
      const notes = listNotes(folder, limit);
      return {
        content: [{ type: "text", text: JSON.stringify(notes, null, 2) }],
      };
    } catch (e: unknown) {
      return {
        content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- search_notes ---
server.tool(
  "search_notes",
  "Search Apple Notes by keyword. Searches in title and snippet. Returns matching notes with metadata.",
  {
    query: z.string().describe("Search keyword"),
    limit: z.number().optional().describe("Max number of results"),
  },
  async ({ query, limit }) => {
    try {
      const notes = searchNotes(query, limit);
      return {
        content: [{ type: "text", text: JSON.stringify(notes, null, 2) }],
      };
    } catch (e: unknown) {
      return {
        content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- get_note ---
server.tool(
  "get_note",
  "Get the full HTML body of a note by its title. Optionally specify folder to disambiguate.",
  {
    title: z.string().describe("Note title (exact match)"),
    folder: z.string().optional().describe("Folder name to scope the search"),
  },
  async ({ title, folder }) => {
    try {
      const body = await getNoteBody(title, folder);
      return {
        content: [{ type: "text", text: body }],
      };
    } catch (e: unknown) {
      return {
        content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- create_note ---
server.tool(
  "create_note",
  "Create a new note in Apple Notes from Markdown content. The first line becomes the title. Optionally specify a target folder (defaults to 'Notes').",
  {
    markdown: z.string().describe("Markdown content for the note. First line (with or without #) becomes the title."),
    folder: z.string().optional().describe("Target folder name (e.g. 'Projects'). Defaults to 'Notes'."),
  },
  async ({ markdown, folder }) => {
    try {
      const title = await createNote(markdown, folder);
      return {
        content: [{ type: "text", text: `Note "${title}" created successfully${folder ? ` in folder "${folder}"` : ""}.` }],
      };
    } catch (e: unknown) {
      return {
        content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- delete_note ---
server.tool(
  "delete_note",
  "Delete a note from Apple Notes by title. Optionally specify folder to disambiguate. The note is moved to Recently Deleted.",
  {
    title: z.string().describe("Title of the note to delete"),
    folder: z.string().optional().describe("Folder name to scope the search"),
  },
  async ({ title, folder }) => {
    try {
      await deleteNote(title, folder);
      return {
        content: [{ type: "text", text: `Note "${title}" deleted successfully.` }],
      };
    } catch (e: unknown) {
      return {
        content: [{ type: "text", text: `Error: ${(e as Error).message}` }],
        isError: true,
      };
    }
  }
);

// --- Start server ---
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Apple Notes MCP server running on stdio");
}

main().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
