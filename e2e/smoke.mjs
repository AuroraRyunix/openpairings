// A read-only smoke check of a running OpenPairings: does it answer, do the
// public pages render, does a LiveView connect over its websocket. Meant for
// right after a deploy, against the real server:
//
//   cd e2e && npm ci && npx playwright install chromium-headless-shell
//   node smoke.mjs https://pairings.cloud
//
// (or BASE_URL=https://pairings.cloud node smoke.mjs). Exit status 0 when
// every check passed, 1 otherwise, with one line per check either way.
//
// READ-ONLY, and that is the whole contract: it opens pages and looks at
// them. It never submits a form, never presses a button, never signs in and
// never creates an account - nothing it does leaves a row in anybody's
// database. A check that would need to write something does not belong here;
// it belongs in test/e2e, which runs against a throwaway test database.
// See docs/e2e.md.

import {chromium} from "playwright"

const base = (process.argv[2] || process.env.BASE_URL || "").replace(/\/+$/, "")

if (!/^https?:\/\/[^/]+/.test(base)) {
  console.error("usage: node smoke.mjs <base url>   e.g. node smoke.mjs https://pairings.cloud")
  process.exit(2)
}

const timeout = Number(process.env.SMOKE_TIMEOUT_MS || 15000)

// Each check gets a fresh page and returns nothing on success, or throws.
const checks = [
  ["the front door sends a visitor to the login page", async (page) => {
    const response = await page.goto(`${base}/`)
    expectOk(response)
    await page.waitForURL(/\/users\/log-in/, {timeout})
  }],

  ["the login page renders its forms (none submitted)", async (page) => {
    expectOk(await page.goto(`${base}/users/log-in`))
    await page.locator("#login_form_magic").waitFor({timeout})
    // Present in the markup; looked at, never filled in.
    await page.locator("#login_form_password").waitFor({state: "attached", timeout})
    await connected(page)
  }],

  ["the stylesheet and the script are served", async (page) => {
    expectOk(await page.goto(`${base}/users/log-in`))
    const assets = await page.evaluate(() => [
      ...[...document.querySelectorAll("link[rel=stylesheet]")].map((l) => l.href),
      ...[...document.querySelectorAll("script[src]")].map((s) => s.src)
    ])
    if (assets.length === 0) throw new Error("no stylesheet or script on the page")

    for (const url of assets) {
      const r = await page.request.get(url)
      if (!r.ok()) throw new Error(`${url} answered ${r.status()}`)
    }
  }],

  ["the manual renders and its LiveView connects", async (page) => {
    expectOk(await page.goto(`${base}/help`))
    await connected(page)
    await page.locator("main h1, main h2").first().waitFor({timeout})
  }],

  ["the changelog renders, with at least one version in it", async (page) => {
    expectOk(await page.goto(`${base}/changelog`))
    await connected(page)
    await page.getByText(/\b\d+\.\d+\.\d+\b/).first().waitFor({timeout})
  }],

  ["the arbiter tools page renders", async (page) => {
    expectOk(await page.goto(`${base}/tools`))
  }]
]

function expectOk(response) {
  if (!response) throw new Error("no response")
  if (response.status() >= 400) throw new Error(`${response.url()} answered ${response.status()}`)
}

// LiveView adds .phx-connected to its root once the websocket is up - the
// part of a deploy most likely to be broken by a proxy, and invisible to curl.
async function connected(page) {
  await page.locator(".phx-connected").first().waitFor({state: "attached", timeout})
}

const browser = await chromium.launch()
let failed = 0

try {
  for (const [name, check] of checks) {
    const context = await browser.newContext({locale: "en-GB"})
    const page = await context.newPage()
    page.setDefaultTimeout(timeout)

    try {
      await check(page)
      console.log(`ok    ${name}`)
    } catch (error) {
      failed += 1
      console.log(`FAIL  ${name}\n      ${String(error.message || error).split("\n")[0]}`)
    } finally {
      await context.close()
    }
  }
} finally {
  await browser.close()
}

console.log(failed === 0 ? `\nAll ${checks.length} checks passed against ${base}.` : `\n${failed} of ${checks.length} checks failed against ${base}.`)
process.exit(failed === 0 ? 0 : 1)
