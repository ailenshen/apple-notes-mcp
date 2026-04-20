/**
 * Run `fn` with process.stdout.write intercepted. Any bytes the function
 * writes to stdout are captured into the returned `stdout` string instead of
 * going to the terminal. stderr is untouched.
 *
 * In MCP stdio servers, stdout is reserved for JSON-RPC protocol traffic.
 * This helper lets unit tests assert that unit methods never leak non-protocol
 * bytes to the stdout channel (the kind of leak that fills the pipe buffer
 * during upstream backpressure — see issue #5 / anthropics/claude-code#50981).
 */
export async function captureStdout<T>(
  fn: () => Promise<T> | T
): Promise<{ result: T; stdout: string }> {
  const chunks: string[] = [];
  const original = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: string | Uint8Array) => {
    chunks.push(
      typeof chunk === "string" ? chunk : Buffer.from(chunk).toString("utf8")
    );
    return true;
  }) as typeof process.stdout.write;
  try {
    const result = await fn();
    return { result, stdout: chunks.join("") };
  } finally {
    process.stdout.write = original;
  }
}
