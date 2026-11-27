#!/usr/bin/env node
// PROTOTYPE — spike for issue #79. Not used by any apex delivery path.
//
// Minimal stdio MCP "channel" server named `apex`. It tails a file and pushes
// every new complete line into the Claude Code session as a
// `notifications/claude/channel` event. Zero dependencies: MCP over stdio is
// newline-delimited JSON-RPC, so the SDK is not needed for a one-way channel.
//
// File watched: $APEX_CHANNEL_FILE, default ./apex-channel.in (relative to cwd).
// Debug log:    $APEX_CHANNEL_LOG, default ./apex-channel.log.
import fs from 'node:fs'
import path from 'node:path'
import readline from 'node:readline'

const file = path.resolve(process.env.APEX_CHANNEL_FILE || 'apex-channel.in')
const logFile = path.resolve(process.env.APEX_CHANNEL_LOG || 'apex-channel.log')
const log = (msg) => fs.appendFileSync(logFile, `${new Date().toISOString()} ${msg}\n`)

const send = (obj) => process.stdout.write(JSON.stringify(obj) + '\n')

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let msg
  try { msg = JSON.parse(line) } catch { return }
  log(`<- ${line}`)
  if (msg.method === 'initialize') {
    send({
      jsonrpc: '2.0',
      id: msg.id,
      result: {
        // Echo the client's revision; channels docs warn 2026-07-28 does not register.
        protocolVersion: msg.params?.protocolVersion ?? '2025-06-18',
        capabilities: { experimental: { 'claude/channel': {} } },
        serverInfo: { name: 'apex', version: '0.0.1' },
        instructions:
          'Events from the apex channel arrive as <channel source="apex" seq="N">. ' +
          'They are messages from your apex manager: read them and act on them.',
      },
    })
  } else if (msg.method === 'notifications/initialized') {
    startWatching()
  } else if (msg.id !== undefined) {
    // ping and anything else with an id: answer so the client never hangs.
    if (msg.method === 'ping') send({ jsonrpc: '2.0', id: msg.id, result: {} })
    else send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'Method not found' } })
  }
})
process.stdin.on('end', () => process.exit(0))

let started = false
let offset = 0
let partial = ''
let seq = 0

function startWatching() {
  if (started) return
  started = true
  if (!fs.existsSync(file)) fs.writeFileSync(file, '')
  offset = fs.statSync(file).size // only lines appended after startup
  log(`watching ${file} from offset ${offset}`)
  fs.watchFile(file, { interval: 250 }, drain)
}

function drain() {
  const size = fs.statSync(file).size
  if (size < offset) offset = 0 // truncated: start over
  if (size === offset) return
  const fd = fs.openSync(file, 'r')
  const buf = Buffer.alloc(size - offset)
  fs.readSync(fd, buf, 0, buf.length, offset)
  fs.closeSync(fd)
  offset = size
  const lines = (partial + buf.toString('utf8')).split('\n')
  partial = lines.pop() // keep an unterminated tail for the next drain
  for (const content of lines) {
    if (!content) continue
    seq += 1
    log(`-> event seq=${seq}: ${content}`)
    send({
      jsonrpc: '2.0',
      method: 'notifications/claude/channel',
      params: { content, meta: { seq: String(seq) } },
    })
  }
}
