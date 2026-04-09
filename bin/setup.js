#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const DATA_DIR = process.env.COST_TRACKER_DIR || path.join(os.homedir(), '.claude', 'cost-tracker');
const PLUGIN_ROOT = process.env.CLAUDE_PLUGIN_ROOT || path.resolve(__dirname, '..');

function ensure(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function main() {
  ensure(DATA_DIR);
  ensure(path.join(DATA_DIR, 'tags'));

  // Copy default config if user doesn't have one
  const userConfig = path.join(DATA_DIR, 'config.json');
  const defaultConfig = path.join(PLUGIN_ROOT, 'config.default.json');

  if (!fs.existsSync(userConfig) && fs.existsSync(defaultConfig)) {
    fs.copyFileSync(defaultConfig, userConfig);
    console.log(`Created ${userConfig} from defaults`);
  }

  // Ensure data files exist
  for (const f of ['activity.jsonl', 'costs.jsonl']) {
    const p = path.join(DATA_DIR, f);
    if (!fs.existsSync(p)) fs.writeFileSync(p, '', 'utf8');
  }

  console.log(`Cost tracker data directory: ${DATA_DIR}`);
  console.log('Setup complete.');
}

main();
