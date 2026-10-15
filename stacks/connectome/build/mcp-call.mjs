// Usage: node mcp-call.mjs <tool> '<json-args>' -- <server-command> [args...]
// Spawns a stdio MCP server, calls one tool, prints {isError, text} as JSON.
// Server env: inherited from this process (pass vars with `env K=V node ...`).
const SDK = '/opt/mcpl/term-sessions/node_modules/@modelcontextprotocol/sdk/dist/esm';
const { Client } = await import(`${SDK}/client/index.js`);
const { StdioClientTransport } = await import(`${SDK}/client/stdio.js`);

const [tool, rawArgs, sep, command, ...args] = process.argv.slice(2);
if (!tool || sep !== '--' || !command) {
  console.error("usage: mcp-call.mjs <tool> '<json>' -- <cmd> [args...]");
  process.exit(2);
}
const transport = new StdioClientTransport({ command, args, env: { ...process.env }, stderr: 'ignore' });
const client = new Client({ name: 'connectome-test', version: '0.0.0' }, { capabilities: {} });
await client.connect(transport);
try {
  const res = await client.callTool({ name: tool, arguments: JSON.parse(rawArgs || '{}') });
  const text = (res.content ?? []).map((c) => c.text ?? '').join('\n');
  console.log(JSON.stringify({ isError: Boolean(res.isError), text }));
} finally {
  await client.close();
}
