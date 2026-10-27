/* eslint-disable @typescript-eslint/no-require-imports */
// Uses require() instead of import to prevent hoisting, ensuring dotenv
// populates process.env before any module-level code reads it.
// quiet: dotenv 17 otherwise prints a plain-text "injecting env -- tip: <vendor ad>" line at
// every start, outside the JSON log stream. DOTENV_CONFIG_QUIET=false brings it back.
const path = require('path')
// `QF_ENV_FILE` lets a local checkout point the API at another env file (e.g. `.env.prod`)
// without editing the committed `.env.dev`; dotenv still does not override exported values.
// `AP_ENV_FILE` stays accepted during the AP_ -> QF_ rename, with QF_ taking precedence.
const envFile = process.env['QF_ENV_FILE']?.trim() || process.env['AP_ENV_FILE']?.trim() || '.env.dev'
require('dotenv').config({ path: path.resolve(__dirname, '../../../../', envFile), quiet: true })
require('./main')
