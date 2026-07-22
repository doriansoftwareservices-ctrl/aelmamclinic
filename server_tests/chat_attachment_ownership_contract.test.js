const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

test('managed storage.files is not altered by the ownership migration', () => {
  const sql = read('nhost/migrations/default/20260721230000_chat_attachment_ownership/up.sql');
  assert.doesNotMatch(sql, /SET(?:\s+LOCAL)?\s+ROLE\s+nhost_storage_admin/i);
  assert.doesNotMatch(sql, /ALTER\s+TABLE\s+storage\.files/i);
  assert.doesNotMatch(sql, /CREATE\s+(?:UNIQUE\s+)?INDEX[^;]+ON\s+storage\.files/is);
  assert.match(sql, /public\.chat_attachment_file_ownership/);
});

test('functions do not depend on custom storage.files columns', () => {
  const sources = [
    read('functions/_shared/storage_utils.js'),
    read('functions/chat-attachment-access/index.js'),
    read('functions/admin-upload-chat-attachment/index.js'),
  ].join('\n');
  assert.doesNotMatch(
    sources,
    /storage\.files\s+(?:sf\s+)?(?:set|where|select)[\s\S]*?\b(?:attachment_message_id|security_state)\b/i,
  );
  assert.match(sources, /claim_chat_attachment_file/);
});

test('no JavaScript tests are deployable Nhost functions', () => {
  const functionsRoot = path.join(root, 'functions');
  const pending = [functionsRoot];
  const testFiles = [];
  while (pending.length) {
    const current = pending.pop();
    for (const entry of fs.readdirSync(current, {withFileTypes: true})) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(full);
      else if (/\.(?:test|spec)\.js$/i.test(entry.name)) testFiles.push(full);
    }
  }
  assert.deepEqual(testFiles, []);
});