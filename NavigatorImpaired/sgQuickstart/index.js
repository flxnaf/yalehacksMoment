/**
 * SendGrid Mail Send API via @sendgrid/mail (Node.js).
 *
 * Usage:
 *   1) Copy .env.example to .env and set SENDGRID_API_KEY + SENDGRID_FROM_EMAIL (verified sender).
 *   2) Demo email (tutorial):  npm run demo
 *   3) Fall-alert relay (iOS posts here):  npm start
 *
 * Environment:
 *   SENDGRID_API_KEY   — required
 *   SENDGRID_FROM_EMAIL — verified sender in SendGrid
 *   SENDGRID_FROM_NAME  — optional (default SightAssist)
 *   PORT — default 8787
 *   RELAY_SECRET — optional; if set, require header X-Relay-Secret on POST /fall-alert
 */

require('dotenv').config()
const os = require('os')
const express = require('express')
const sgMail = require('@sendgrid/mail')

const apiKey = process.env.SENDGRID_API_KEY
if (!apiKey) {
  console.error('[SendGrid] Missing SENDGRID_API_KEY in environment')
}
sgMail.setApiKey(apiKey || '')

const FROM_EMAIL = process.env.SENDGRID_FROM_EMAIL || 'test@example.com'
const FROM_NAME = process.env.SENDGRID_FROM_NAME || 'SightAssist'
const RELAY_SECRET = (process.env.RELAY_SECRET || '').trim()

function assertConfigured() {
  if (!apiKey) {
    throw new Error('SENDGRID_API_KEY is not set')
  }
}

/**
 * Send fall alert: plain text body + optional JPEG attachments (base64 content).
 */
async function sendFallAlertEmail(body) {
  assertConfigured()
  const to = body.to
  const toName = (body.toName || '').trim()
  const subject = body.subject || 'SightAssist Fall Alert'
  const text = body.text || ''

  const msg = {
    to: toName ? { email: to, name: toName } : to,
    from: { email: FROM_EMAIL, name: FROM_NAME },
    subject,
    text,
  }

  const attachments = body.attachments
  if (Array.isArray(attachments) && attachments.length > 0) {
    msg.attachments = attachments.map((a) => ({
      content: a.content,
      filename: a.filename || 'attachment.bin',
      type: a.type || 'image/jpeg',
      disposition: 'attachment',
    }))
  }

  return sgMail.send(msg)
}

/** SendGrid tutorial-style demo (text + html). */
function runDemo() {
  assertConfigured()
  const msg = {
    to: process.env.DEMO_TO || 'test@example.com',
    from: { email: FROM_EMAIL, name: FROM_NAME },
    subject: 'Sending with SendGrid is Fun',
    text: 'and easy to do anywhere, even with Node.js',
    html: '<strong>and easy to do anywhere, even with Node.js</strong>',
  }

  sgMail
    .send(msg)
    .then((response) => {
      console.log(response[0].statusCode)
      console.log(response[0].headers)
    })
    .catch((error) => {
      console.error(error)
      if (error.response) {
        console.error(error.response.body)
      }
      process.exitCode = 1
    })
}

function checkRelaySecret(req) {
  if (!RELAY_SECRET) return true
  const got = (req.get('X-Relay-Secret') || '').trim()
  return got === RELAY_SECRET
}

/** LAN IPv4s to paste into iOS Settings (not 0.0.0.0 — ATS and routing reject that from the phone). */
function lanIPv4Hints() {
  const nets = os.networkInterfaces()
  const out = []
  for (const addrs of Object.values(nets)) {
    if (!addrs) continue
    for (const a of addrs) {
      if (a.family === 'IPv4' && !a.internal) {
        out.push(a.address)
      }
    }
  }
  return [...new Set(out)]
}

function main() {
  if (process.argv.includes('--demo')) {
    runDemo()
    return
  }

  const app = express()
  const port = Number(process.env.PORT) || 8787
  app.use(express.json({ limit: '20mb' }))

  app.get('/', (_req, res) => {
    res.type('html').send(
      '<!DOCTYPE html><meta charset="utf-8"><title>SightAssist relay</title><body style="font-family:system-ui;padding:1.5rem">' +
        '<h1>Relay is running</h1>' +
        '<p>JSON: <a href="/health">/health</a></p>' +
        '<p>iOS Settings base URL should be <code>http://' +
        (lanIPv4Hints()[0] || 'YOUR_MAC_LAN_IP') +
        ':' +
        port +
        '</code> (http, same Wi‑Fi as this Mac).</p>' +
        '<p>Fall alerts: <code>POST /fall-alert</code> with JSON body.</p></body>'
    )
  })

  app.get('/health', (_req, res) => {
    res.json({ ok: true, service: 'sightassist-sendgrid-relay' })
  })

  app.post('/fall-alert', async (req, res) => {
    if (!checkRelaySecret(req)) {
      console.warn(
        '[relay] 401: X-Relay-Secret mismatch or missing (RELAY_SECRET is set in .env — copy it to the iOS “Relay shared secret” field, or remove RELAY_SECRET from .env).'
      )
      return res.status(401).json({ error: 'unauthorized' })
    }
    try {
      if (!apiKey) {
        return res.status(500).json({ error: 'server missing SENDGRID_API_KEY' })
      }
      const to = (req.body && req.body.to) || ''
      if (!to || typeof to !== 'string') {
        return res.status(400).json({ error: 'missing "to" email' })
      }
      const att = req.body && Array.isArray(req.body.attachments) ? req.body.attachments.length : 0
      await sendFallAlertEmail(req.body)
      console.log(`[SendGrid] HTTP 202 (fall-alert), attachments=${att}`)
      return res.status(202).json({ ok: true })
    } catch (e) {
      console.error(e)
      return res.status(500).json({ error: String(e.message || e) })
    }
  })

  app.listen(port, '0.0.0.0', () => {
    const hints = lanIPv4Hints()
    console.log(`SendGrid relay listening on 0.0.0.0:${port}  POST /fall-alert`)
    if (hints.length > 0) {
      console.log('In iOS Settings → fall alert relay URL use your Mac’s Wi‑Fi IP, e.g.')
      for (const ip of hints) {
        console.log(`  http://${ip}:${port}`)
      }
    } else {
      console.log('In iOS Settings use http://<your-mac-lan-ip>:' + port + ' (not http://0.0.0.0 — the phone cannot reach that).')
    }
  })
}

main()
