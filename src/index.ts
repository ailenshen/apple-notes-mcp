#!/usr/bin/env node

// Suppress Node.js ExperimentalWarning (e.g. node:sqlite) from polluting MCP stdio output
process.removeAllListeners("warning");
process.on("warning", (w) => {
  if (w.name !== "ExperimentalWarning") process.stderr.write(`Warning: ${w.message}\n`);
});

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { randomUUID, randomBytes } from "node:crypto";
import { listNotes, searchNotes, type NoteRow } from "./db.js";
import { getNoteBody, createNote, deleteNote, updateNote } from "./applescript.js";
import { friendlyError, logError } from "./permissions.js";

// --- Output formatting ---
//
// One line per note instead of pretty-printed JSON: an agent only needs the
// title (every other tool takes a title) plus enough context to choose.
// Internal ids are left out because no tool accepts them.
// 当工具改为按 ZIDENTIFIER 精确定位笔记时，在这一行里加回 identifier。

const DEFAULT_LIST_LIMIT = 50;
const DEFAULT_SEARCH_LIMIT = 20;

function noteLine(n: NoteRow): string {
  return [n.title, n.folder, n.modified.slice(0, 10), n.is_pinned ? "pinned" : ""]
    .filter(Boolean)
    .join(" | ");
}

// --- Tool registration ---

function createServer(): McpServer {
  const server = new McpServer({
    name: "apple-notes",
    version: "1.0.0",
  });

  // --- list_notes ---
  server.tool(
    "list_notes",
    `List notes, newest first, one line each: "title | folder | modified date | pinned". Returns ${DEFAULT_LIST_LIMIT} by default. To find notes by content, use search_notes instead.`,
    {
      folder: z.string().optional().describe("Filter by folder name"),
      limit: z.number().optional().describe(`Max number of notes to return (default ${DEFAULT_LIST_LIMIT})`),
    },
    async ({ folder, limit }) => {
      try {
        const all = listNotes(folder);
        const shown = all.slice(0, limit ?? DEFAULT_LIST_LIMIT);
        const header = `Showing ${shown.length} of ${all.length} notes${folder ? ` in "${folder}"` : ""}.`;
        return {
          content: [{ type: "text", text: [header, ...shown.map(noteLine)].join("\n") }],
        };
      } catch (e: unknown) {
        logError("list_notes", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
          isError: true,
        };
      }
    }
  );

  // --- search_notes ---
  server.tool(
    "search_notes",
    `Full-text search across note titles and bodies. All space-separated words must match (case-insensitive). Each result is "title | folder | modified date" followed by an excerpt around the match, so you often don't need get_note. Returns ${DEFAULT_SEARCH_LIMIT} by default; title matches come first.`,
    {
      query: z.string().describe("Words to search for"),
      limit: z.number().optional().describe(`Max number of results (default ${DEFAULT_SEARCH_LIMIT})`),
    },
    async ({ query, limit }) => {
      try {
        const hits = searchNotes(query);
        const shown = hits.slice(0, limit ?? DEFAULT_SEARCH_LIMIT);
        const header = `${hits.length} notes match "${query}"${shown.length < hits.length ? `, showing ${shown.length}` : ""}.`;
        const lines = shown.map((h) => `- ${noteLine(h)}\n  ${h.excerpt}`);
        return {
          content: [{ type: "text", text: [header, ...lines].join("\n") }],
        };
      } catch (e: unknown) {
        logError("search_notes", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
          isError: true,
        };
      }
    }
  );

  // --- get_note ---
  server.tool(
    "get_note",
    "Get the full content of a note by its title, returned as Markdown. Optionally specify folder to disambiguate.",
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
        logError("get_note", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
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
        logError("create_note", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
          isError: true,
        };
      }
    }
  );

  // --- update_note ---
  server.tool(
    "update_note",
    "Update an existing note in Apple Notes. Deletes the old note and creates a new one with the given Markdown content, preserving the original folder.",
    {
      title: z.string().describe("Title of the existing note to update"),
      markdown: z.string().describe("New Markdown content for the note. First line (with or without #) becomes the title."),
      folder: z.string().optional().describe("Folder name to scope the search for the existing note"),
    },
    async ({ title, markdown, folder }) => {
      try {
        const newTitle = await updateNote(title, markdown, folder);
        return {
          content: [{ type: "text", text: `Note "${title}" updated successfully (new title: "${newTitle}").` }],
        };
      } catch (e: unknown) {
        logError("update_note", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
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
        logError("delete_note", e);
        return {
          content: [{ type: "text", text: friendlyError(e) }],
          isError: true,
        };
      }
    }
  );

  return server;
}

// --- CLI argument parsing ---

function parseArgs() {
  const args = process.argv.slice(2);
  let httpMode = false;
  let port = 3100;
  let secret: string | undefined;

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--http":
        httpMode = true;
        break;
      case "--port":
        port = parseInt(args[++i], 10);
        if (isNaN(port)) {
          console.error("Invalid port number");
          process.exit(1);
        }
        break;
      case "--secret":
        secret = args[++i];
        break;
    }
  }

  return { httpMode, port, secret };
}

// --- Stdio mode ---

async function startStdio() {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Apple Notes MCP server running on stdio");
}

// --- HTTP mode ---

async function startHttp(port: number, secret: string) {
  // Dynamic import to avoid requiring express for stdio users
  const { default: express } = await import("express");

  const app = express();
  app.use(express.json());

  const mcpPath = `/mcp/${secret}`;
  const transports: Record<string, StreamableHTTPServerTransport> = {};

  app.post(mcpPath, async (req, res) => {
    const sessionId = req.headers["mcp-session-id"] as string | undefined;

    if (sessionId && transports[sessionId]) {
      // Existing session
      await transports[sessionId].handleRequest(req, res, req.body);
    } else if (!sessionId) {
      // New session — create a fresh server + transport
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: () => randomUUID(),
        onsessioninitialized: (sid) => {
          transports[sid] = transport;
        },
      });
      transport.onclose = () => {
        if (transport.sessionId) delete transports[transport.sessionId];
      };
      const server = createServer();
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } else {
      // sessionId provided but not found
      res.status(400).json({
        jsonrpc: "2.0",
        error: { code: -32000, message: "Bad Request: invalid session ID" },
        id: null,
      });
    }
  });

  app.get(mcpPath, async (req, res) => {
    const sessionId = req.headers["mcp-session-id"] as string | undefined;
    if (sessionId && transports[sessionId]) {
      await transports[sessionId].handleRequest(req, res);
    } else {
      res.status(400).send("Invalid or missing session ID");
    }
  });

  app.delete(mcpPath, async (req, res) => {
    const sessionId = req.headers["mcp-session-id"] as string | undefined;
    if (sessionId && transports[sessionId]) {
      await transports[sessionId].handleRequest(req, res);
    } else {
      res.status(400).send("Invalid or missing session ID");
    }
  });

  app.listen(port, "0.0.0.0", () => {
    const url = `http://localhost:${port}${mcpPath}`;
    console.error(`Apple Notes MCP server running on HTTP`);
    console.error(`Endpoint: ${url}`);
  });
}

// --- Main ---

async function main() {
  const { httpMode, port, secret } = parseArgs();

  if (httpMode) {
    const urlSecret = secret || randomBytes(24).toString("hex");
    await startHttp(port, urlSecret);
  } else {
    await startStdio();
  }
}

main().catch((e) => {
  console.error("Fatal error:", e);
  process.exit(1);
});
