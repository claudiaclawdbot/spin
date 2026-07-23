#!/usr/bin/env node
'use strict';

const CLOSED_ATTENTION_STATES = new Set([
  'acknowledged',
  'archived',
  'dismissed',
  'resolved',
  'superseded',
]);

function jobNeedsAttention(job) {
  if (!job || !['blocked', 'failed'].includes(String(job.status || '').toLowerCase())) return false;
  if (job.attention_required === false || job.acknowledged === true || job.resolved === true) return false;
  if (job.acknowledged_at || job.resolved_at || job.archived_at || job.superseded_at) return false;
  return !CLOSED_ATTENTION_STATES.has(String(job.attention_status || '').toLowerCase());
}

module.exports = { jobNeedsAttention };
