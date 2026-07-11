#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const SERVER_NAME = 'computer-use';
const CLIENT_RELATIVE_PATH = path.join(
  'Contents',
  'SharedSupport',
  'SkyComputerUseClient.app',
  'Contents',
  'MacOS',
  'SkyComputerUseClient',
);

const args = process.argv.slice(2);
const action = args.find((arg) => !arg.startsWith('-')) || 'repair';
const jsonOutput = args.includes('--json');
const quiet = args.includes('--quiet');

function isExecutable(file) {
  if (!file || !path.isAbsolute(file)) return false;
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return fs.statSync(file).isFile();
  } catch {
    return false;
  }
}

function addCandidate(candidates, file) {
  if (!file) return;
  const resolved = path.resolve(file);
  if (!candidates.includes(resolved)) candidates.push(resolved);
}

function codexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

function findNodeRepl() {
  const candidates = [];
  addCandidate(candidates, process.env.SPIN_NODE_REPL_BIN);
  addCandidate(candidates, '/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl');
  addCandidate(candidates, '/Applications/Codex.app/Contents/Resources/cua_node/bin/node_repl');
  return candidates.find(isExecutable) || null;
}

function validPluginRoot(root) {
  return Boolean(
    root
    && fs.existsSync(path.join(root, 'scripts', 'computer-use-client.mjs'))
    && fs.existsSync(path.join(root, 'skills', 'computer-use', 'SKILL.md')),
  );
}

function findPluginRoot() {
  const candidates = [];
  addCandidate(candidates, process.env.SPIN_COMPUTER_USE_PLUGIN_ROOT);

  const cacheRoot = path.join(codexHome(), 'plugins', 'cache', 'openai-bundled', 'computer-use');
  try {
    const versions = fs.readdirSync(cacheRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    for (const version of versions) addCandidate(candidates, path.join(cacheRoot, version));
  } catch {}

  return candidates.find(validPluginRoot) || null;
}

function findLegacyClient() {
  const candidates = [];
  addCandidate(candidates, process.env.SPIN_COMPUTER_USE_CLIENT);
  addCandidate(
    candidates,
    path.join(codexHome(), 'computer-use', 'Codex Computer Use.app', CLIENT_RELATIVE_PATH),
  );
  return candidates.find(isExecutable) || null;
}

function configPath() {
  if (process.env.SPIN_OMP_MCP_CONFIG) return path.resolve(process.env.SPIN_OMP_MCP_CONFIG);
  const agentDir = process.env.PI_CODING_AGENT_DIR
    ? path.resolve(process.env.PI_CODING_AGENT_DIR)
    : path.join(os.homedir(), '.omp', 'agent');
  return path.join(agentDir, 'mcp.json');
}

function readConfig(file) {
  if (!fs.existsSync(file)) return { config: {}, exists: false, error: null };
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object') {
      throw new Error('expected a JSON object');
    }
    return { config: parsed, exists: true, error: null };
  } catch (error) {
    return { config: null, exists: true, error: error.message };
  }
}

function codexConfigHasLegacyServer() {
  try {
    const config = fs.readFileSync(path.join(codexHome(), 'config.toml'), 'utf8');
    return /\[mcp_servers\.computer-use\]/.test(config);
  } catch {
    return false;
  }
}

function isLegacyServer(server) {
  if (!server || typeof server !== 'object') return false;
  if (!isExecutable(server.command)) return true;
  if (String(server.command).includes('SkyComputerUseClient')) return true;
  const knownClient = findLegacyClient();
  return Boolean(knownClient && path.resolve(server.command) === path.resolve(knownClient));
}

function isCustomServer(server) {
  return Boolean(
    server
    && !isLegacyServer(server)
    && isExecutable(server.command),
  );
}

function bridgeComponents() {
  return {
    nodeRepl: findNodeRepl(),
    pluginRoot: findPluginRoot(),
  };
}

function status() {
  const file = configPath();
  const loaded = readConfig(file);
  if (loaded.error) {
    return {
      ok: false,
      status: 'error',
      changed: false,
      configPath: file,
      detail: `OMP MCP config is invalid JSON: ${loaded.error}`,
    };
  }

  const server = loaded.config?.mcpServers?.[SERVER_NAME];
  const disabled = Array.isArray(loaded.config.disabledServers)
    && loaded.config.disabledServers.includes(SERVER_NAME);
  if (isCustomServer(server)) {
    const active = server.enabled !== false && !disabled;
    return {
      ok: true,
      status: active ? 'custom' : 'custom-disabled',
      changed: false,
      configPath: file,
      command: server.command,
      detail: active
        ? 'a custom executable OMP computer-use MCP is configured; SPIN left it unchanged'
        : 'a custom executable OMP computer-use MCP is intentionally disabled; SPIN left it unchanged',
    };
  }

  const components = bridgeComponents();
  const suppressed = disabled;
  const directEntryPresent = Boolean(server);
  const componentsReady = Boolean(components.nodeRepl && components.pluginRoot);

  if (componentsReady && suppressed && !directEntryPresent) {
    return {
      ok: true,
      status: 'ready',
      route: 'node_repl',
      changed: false,
      configPath: file,
      ...components,
      detail: 'OMP Computer Use is ready through node_repl; the disabled legacy direct MCP is suppressed',
    };
  }

  if (componentsReady) {
    return {
      ok: true,
      status: 'repairable',
      route: 'node_repl',
      changed: false,
      configPath: file,
      ...components,
      detail: 'node_repl and the Computer Use plugin are installed; OMP needs the legacy direct MCP suppressed',
    };
  }

  return {
    ok: true,
    status: 'unavailable',
    route: null,
    changed: false,
    configPath: file,
    ...components,
    detail: suppressed
      ? 'legacy direct computer-use MCP is suppressed; node_repl or the Computer Use plugin is unavailable'
      : 'node_repl or the Computer Use plugin is unavailable; OMP will continue without desktop control',
  };
}

function writeConfig(file, config) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, file);
  fs.chmodSync(file, 0o600);
}

function repair() {
  const before = status();
  if (!before.ok || before.status === 'custom' || before.status === 'custom-disabled') return before;

  const file = before.configPath;
  const loaded = readConfig(file);
  if (loaded.error) return before;

  const config = { ...loaded.config };
  const servers = config.mcpServers && typeof config.mcpServers === 'object'
    ? { ...config.mcpServers }
    : {};
  const directServer = servers[SERVER_NAME];
  let changed = false;

  if (directServer && isLegacyServer(directServer)) {
    delete servers[SERVER_NAME];
    changed = true;
  }
  config.mcpServers = servers;

  const shouldSuppress = Boolean(
    before.nodeRepl
    || before.pluginRoot
    || directServer
    || codexConfigHasLegacyServer(),
  );
  if (shouldSuppress) {
    const disabled = new Set(Array.isArray(config.disabledServers) ? config.disabledServers : []);
    if (!disabled.has(SERVER_NAME)) {
      disabled.add(SERVER_NAME);
      changed = true;
    }
    config.disabledServers = [...disabled].sort();
  }

  if (changed) writeConfig(file, config);
  return {
    ...status(),
    changed,
    detail: changed
      ? 'suppressed OMP 16.4 legacy direct computer-use discovery; node_repl is the supported route'
      : before.detail,
  };
}

function computerUsePrompt() {
  const current = status();
  if (current.status !== 'ready' || !current.pluginRoot) return '';
  const skill = path.join(current.pluginRoot, 'skills', 'computer-use', 'SKILL.md');
  const wrapper = path.join(current.pluginRoot, 'scripts', 'computer-use-client.mjs');
  return `## macOS Computer Use\n\nFor desktop UI work, use the connected node_repl MCP, not a direct computer-use MCP. Read ${skill} before acting. In node_repl, initialize the supported plugin wrapper with:\n\nif (!globalThis.sky) {\n  var { setupComputerUseRuntime } = await import(${JSON.stringify(wrapper)});\n  await setupComputerUseRuntime({ globals: globalThis });\n}\n\nThen use sky.get_app_state and the other sky methods exactly as the skill describes. Re-read app state after each action and follow the skill's confirmation policy.`;
}

function printResult(result) {
  if (jsonOutput) {
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (!quiet) process.stdout.write(`${result.detail}\n`);
}

if (!['repair', 'status', 'prompt'].includes(action)) {
  process.stderr.write('usage: omp-mcp-bootstrap.js [repair|status|prompt] [--json] [--quiet]\n');
  process.exit(2);
}

if (action === 'prompt') {
  const prompt = computerUsePrompt();
  if (jsonOutput) process.stdout.write(`${JSON.stringify({ ok: true, prompt })}\n`);
  else if (!quiet && prompt) process.stdout.write(`${prompt}\n`);
  process.exit(0);
}

const result = action === 'repair' ? repair() : status();
printResult(result);
process.exit(result.ok ? 0 : 1);
