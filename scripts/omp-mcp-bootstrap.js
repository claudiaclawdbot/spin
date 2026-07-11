#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

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

function addPathCandidate(candidates, name) {
  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (dir) addCandidate(candidates, path.join(dir, name));
  }
}

function commandWorks(file) {
  if (!isExecutable(file)) return false;
  const result = spawnSync(file, ['--version'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 5000,
  });
  return !result.error && result.status === 0;
}

function trustedForComputerUse(file) {
  if (process.env.SPIN_ALLOW_UNSIGNED_CODEX_COMPUTER_USE === '1') return true;
  if (process.platform !== 'darwin') return true;
  const result = spawnSync('/usr/bin/codesign', ['-d', '--verbose=4', file], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 5000,
  });
  const output = `${result.stdout || ''}\n${result.stderr || ''}`;
  return !result.error && result.status === 0 && /TeamIdentifier=2DC432GLL2/.test(output);
}

function findCodex() {
  const candidates = [];
  addCandidate(candidates, process.env.SPIN_CODEX_BIN);
  addCandidate(candidates, process.env.CODEX_CLI_PATH);
  addCandidate(candidates, '/Applications/ChatGPT.app/Contents/Resources/codex');
  addCandidate(candidates, '/Applications/Codex.app/Contents/Resources/codex');
  addPathCandidate(candidates, 'codex');
  return candidates.find((file) => commandWorks(file) && trustedForComputerUse(file)) || null;
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
    codexBin: findCodex(),
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
  const componentsReady = Boolean(components.codexBin && components.nodeRepl && components.pluginRoot);

  if (componentsReady && suppressed && !directEntryPresent) {
    return {
      ok: true,
      status: 'configured',
      route: 'codex-delegate',
      changed: false,
      configPath: file,
      ...components,
      probeCommand: 'spin computer-use probe',
      detail: 'Codex Computer Use delegation is configured; run the read-only probe before claiming runtime readiness',
    };
  }

  if (componentsReady) {
    return {
      ok: true,
      status: 'repairable',
      route: 'codex-delegate',
      changed: false,
      configPath: file,
      ...components,
      detail: 'signed Codex, node_repl, and the Computer Use plugin are installed; OMP needs the unsupported direct MCP suppressed',
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
      ? 'unsupported direct computer-use MCP is suppressed; signed Codex, node_repl, or the Computer Use plugin is unavailable'
      : 'signed Codex, node_repl, or the Computer Use plugin is unavailable; OMP will continue without desktop control',
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
      ? 'suppressed OMP 16.4 direct computer-use discovery; desktop work delegates to signed Codex'
      : before.detail,
  };
}

function computerUsePrompt() {
  const current = status();
  if (current.status !== 'configured' || !current.pluginRoot) return '';
  const skill = path.join(current.pluginRoot, 'skills', 'computer-use', 'SKILL.md');
  const delegate = path.join(__dirname, 'codex-computer-use.sh');
  return `## macOS Computer Use\n\nOMP does not own Codex's native Computer Use trust chain. Do not call OMP's imported node_repl or a direct computer-use MCP for desktop work. Delegate each exact, bounded desktop task to the signed Codex lane:\n\n${JSON.stringify(delegate)} --cwd \"$PWD\" -- \"<exact desktop task and acceptance evidence>\"\n\nFor inspection-only work, add --read-only. The delegated Codex agent must read ${skill}, use its connected node_repl MCP, and follow the skill's action-time confirmation policy. Generic delegation is not confirmation for a risky UI action. Quote any relevant explicit user-authored pre-approval exactly in the task; never infer or invent it. If the command reports quota, approval, or native-runtime failure, report that exact blocker and do not invent UI evidence. Run ${JSON.stringify(delegate)} probe for a read-only runtime proof.`;
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
