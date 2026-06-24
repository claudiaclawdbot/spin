#!/usr/bin/env node
// Resolve SPIN-owned app/runtime binaries before PATH fallbacks.

const fs = require('fs');
const path = require('path');

function runtimeRoot() {
  return process.env.SPIN_RUNTIME_ROOT ||
    process.env.SPIN_ROOT ||
    process.env.OMP_ROOT ||
    path.resolve(__dirname, '..', '..');
}

function envName(name) {
  return `SPIN_${String(name).replace(/-/g, '_').toUpperCase()}_BIN`;
}

function candidateBinDirs(root = runtimeRoot()) {
  return [
    process.env.SPIN_APP_RESOURCES ? path.join(process.env.SPIN_APP_RESOURCES, 'bin') : '',
    process.env.SPIN_INTERNAL_BIN_DIR || '',
    path.join(root, 'vendor', 'bin'),
    path.join(root, 'agent', 'bin'),
    path.join(root, 'app', 'bin'),
  ].filter(Boolean);
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveBinary(name, root = runtimeRoot()) {
  const override = process.env[envName(name)];
  if (override && isExecutable(override)) return override;

  for (const dir of candidateBinDirs(root)) {
    const candidate = path.join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }

  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    if (isExecutable(candidate)) return candidate;
  }
  return null;
}

function internalPath(root = runtimeRoot()) {
  return candidateBinDirs(root).filter((dir) => {
    try {
      return fs.statSync(dir).isDirectory();
    } catch {
      return false;
    }
  }).join(path.delimiter);
}

module.exports = {
  candidateBinDirs,
  internalPath,
  resolveBinary,
  runtimeRoot,
};
