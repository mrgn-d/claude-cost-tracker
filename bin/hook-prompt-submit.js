#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const BASE_DIR = process.env.COST_TRACKER_DIR || path.join(process.env.HOME, '.claude', 'cost-tracker');
const ACTIVITY_FILE = path.join(BASE_DIR, 'activity.jsonl');
const CONFIG_FILE = path.join(BASE_DIR, 'config.json');
const TAGS_FILE = path.join(BASE_DIR, 'tags', 'sessions.json');

const VALID_STAGES = ['research', 'prd', 'plan', 'implementation', 'code', 'review', 'testing', 'debug'];

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'));
  } catch (_) {
    return { ticketPattern: '[A-Z]{2,6}-\\d+', nudgeAfterToolCalls: 20 };
  }
}

function extractTicket(text, pattern) {
  if (!text || !pattern) return null;
  try {
    const match = text.match(new RegExp(pattern));
    return match ? match[0] : null;
  } catch (_) {
    return null;
  }
}

function extractStage(text) {
  if (!text) return null;
  for (const stage of VALID_STAGES) {
    if (new RegExp(`#${stage}\\b`, 'i').test(text)) {
      return stage;
    }
  }
  return null;
}

function extractSummary(text) {
  if (!text) return null;
  const match = text.match(/#summary\s+(.+?)(?:\s*#|$)/i);
  return match ? match[1].trim() : null;
}

function loadSessionTags() {
  try {
    const raw = fs.readFileSync(TAGS_FILE, 'utf8');
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function saveSessionTags(tags) {
  try {
    const dir = path.dirname(TAGS_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(TAGS_FILE, JSON.stringify(tags, null, 2) + '\n', 'utf8');
  } catch (_) {
    // Silently fail
  }
}

function countToolCallsForSession(sessionId) {
  if (!sessionId) return 0;
  try {
    const raw = fs.readFileSync(ACTIVITY_FILE, 'utf8');
    const lines = raw.split('\n').filter(Boolean);
    let count = 0;
    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        if (entry.event === 'tool_call' && entry.sessionId === sessionId) {
          count++;
        }
      } catch (_) {
        // skip malformed lines
      }
    }
    return count;
  } catch (_) {
    return 0;
  }
}

async function main() {
  let input = '';
  process.stdin.setEncoding('utf8');
  for await (const chunk of process.stdin) {
    input += chunk;
  }

  let data;
  try {
    data = JSON.parse(input);
  } catch (_) {
    return;
  }

  const config = loadConfig();
  const sessionId = data.session_id || null;
  const prompt = data.user_prompt || '';

  // Extract ticket, stage, and summary from prompt
  const ticket = extractTicket(prompt, config.ticketPattern);
  const stage = extractStage(prompt);
  const summary = extractSummary(prompt);

  // Update tags/sessions.json if we found anything
  const sessionTags = loadSessionTags();
  const existing = sessionTags[sessionId] || {};
  let updated = false;

  if (ticket && existing.ticket !== ticket) {
    existing.ticket = ticket;
    updated = true;
  }
  if (stage && existing.stage !== stage) {
    existing.stage = stage;
    updated = true;
  }
  if (summary) {
    existing.summary = summary;
    updated = true;
  }

  if (sessionId && updated) {
    sessionTags[sessionId] = existing;
    saveSessionTags(sessionTags);
  }

  // Log user_prompt event (no prompt text — metadata + tags only)
  const entry = {
    timestamp: new Date().toISOString(),
    event: 'user_prompt',
    sessionId,
    tags: {
      ...(ticket ? { ticket } : {}),
      ...(stage ? { stage } : {}),
    },
  };

  try {
    const dir = path.dirname(ACTIVITY_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(ACTIVITY_FILE, JSON.stringify(entry) + '\n', 'utf8');
  } catch (_) {
    // Silently fail
  }

  // Nudge: if session is untagged and tool_call count hits the nudge threshold
  const nudgeAfter = config.nudgeAfterToolCalls || 20;
  const isUntagged = !existing.ticket && !existing.stage && !ticket && !stage;

  if (isUntagged && sessionId) {
    const toolCallCount = countToolCallsForSession(sessionId);
    if (toolCallCount > 0 && toolCallCount % nudgeAfter === 0) {
      process.stderr.write(
        `[cost-tracker] Reminder: session ${sessionId} has ${toolCallCount} tool calls but no ticket or stage tag. ` +
        `Add a ticket (e.g. ENG-123) or stage tag (e.g. #research) to your message to enable cost tracking.\n`
      );
    }
  }
}

main().catch(() => {
  // Never crash
});
