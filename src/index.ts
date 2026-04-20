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
import { listNotes, searchNotes, listFolders, findNoteByTitle } from "./db.js";
import { getNoteBody, createNote, deleteNote, updateNote } from "./applescript.js";
import { friendlyError, logError } from "./permissions.js";

// --- Tool registration ---

function createServer(): McpServer {
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
