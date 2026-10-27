#!/usr/bin/env node
/**
 * workspace-to-file.cjs — npm-compat bridge for the Debian build (no bun).
 *
 * This monorepo's dependency specs use bun-style "workspace:*" (and
 * "workspace:^x"), which npm rejects outright (EUNSUPPORTEDPROTOCOL), and the
 * Debian packaging must build with npm alone. This script rewrites those specs
 * to npm `file:` specs **in place** before `npm ci`, stashing the original
 * contents, and restores them afterwards:
 *
 *   node scripts/workspace-to-file.cjs apply    # before npm install/ci
 *   node scripts/workspace-to-file.cjs restore  # after everything is staged
 *
 * The runtime tree does not care which spelling the package.json files used
 * (nothing parses dep specs outside installs), and the payload staged into
 * debian/prebuild ships the restored originals, so the .deb and the repo are
 * both clean of this build-only transform.
 */
'use strict'

const fs = require('fs')
const path = require('path')

const root = path.resolve(__dirname, '..')
const stashFile = path.join(root, '.workspace-stash.json')
const lockFile = path.join(root, '.workspace-stash.json.lock')

const STASH_KEY = 'files'

// Non-reentrant mutex across prebuild invocations: fail fast instead of two
// chains interleaving rm -rf / apply / restore (reviewer F5). A leftover lock
// is stolen when the recorded pid is gone OR no longer runs this script
// (kill(pid,0) alone is a false positive under pid reuse).
const lockOwnerAlive = (pid) => {
    try {
        return /workspace-to-file\.cjs/.test(fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8'))
    } catch {
        return false
    }
}

// Acquire: exclusive-create the lock, write our pid through the SAME fd,
// then close. fs.openSync returns an integer descriptor — it has no .close()
// method, closing goes through fs.closeSync. Any failure between create and
// close must remove the half-made file, else every later invocation would
// refuse on an empty lock that the liveness-stale check cannot recover.
const acquireLock = () => {
    let fd = null
    try {
        fd = fs.openSync(lockFile, 'wx')
        fs.writeFileSync(fd, String(process.pid))
        return true
    } catch {
        if (fd !== null) {
            try {
                fs.unlinkSync(lockFile)
            } catch {
                // leave it: the next run still steals it via the liveness check
            }
        }
        return false
    } finally {
        if (fd !== null) {
            try {
                fs.closeSync(fd)
            } catch {
                // fds close at process exit
            }
        }
    }
}

const withLock = (fn, name) => {
    if (fs.existsSync(lockFile)) {
        let pid = NaN
        try {
            pid = parseInt(fs.readFileSync(lockFile, 'utf8').trim(), 10)
        } catch {
            pid = NaN
        }
        if (!Number.isInteger(pid) || !lockOwnerAlive(pid)) {
            fs.unlinkSync(lockFile)
        }
    }
    if (!acquireLock()) {
        throw new Error(`workspace-to-file: another apply/restore is running (${name}); refused`)
    }
    try {
        return fn()
    } finally {
        try {
            fs.unlinkSync(lockFile)
        } catch {
            // a released-then-stale lock self-heals on the next run
        }
    }
}

// atomic-ish stash write: tmp + rename, so a killed writer leaves no
// truncated stash and restore never has to parse half of it.
const writeStash = (stash) => {
    const tmp = `${stashFile}.tmp`
    fs.writeFileSync(tmp, JSON.stringify(stash, null, 2), { mode: 0o600 })
    fs.renameSync(tmp, stashFile)
}

const readJson = (file) => JSON.parse(fs.readFileSync(path.join(root, file), 'utf8'))

// Turn a workspaces entry into a directory list: fixed paths as-is, one-level
// globs ("packages/qadams/core/*") expanded by readdir.
const workspaceDirs = (rootPkg, entry) => {
    const parts = entry.split('/')
    const last = parts[parts.length - 1]
    if (!last.includes('*')) {
        return [entry]
    }
    const parent = parts.slice(0, -1).join('/')
    if (!fs.existsSync(path.join(root, parent))) {
        return []
    }
    return fs.readdirSync(path.join(root, parent))
        .map((name) => path.posix.join(parent, name))
        .filter((dir) => fs.statSync(path.join(root, dir)).isDirectory())
}

const collectPackages = (rootPkg) => {
    const dirs = new Set([''])
    for (const entry of rootPkg.workspaces ?? []) {
        for (const dir of workspaceDirs(rootPkg, entry)) {
            const file = dir ? `${dir}/package.json` : 'package.json'
            if (fs.existsSync(path.join(root, file))) {
                dirs.add(dir)
            }
        }
    }
    return [...dirs]
}

const rebuildWorkspaceMap = (rootPkg) => {
    const byName = new Map()
    for (const dir of collectPackages(rootPkg)) {
        const file = dir ? `${dir}/package.json` : 'package.json'
        const pkg = readJson(file)
        if (pkg.name) {
            byName.set(pkg.name, path.posix.join(dir, 'package.json'))
        }
    }
    return byName
}

const apply = () => {
    if (fs.existsSync(stashFile)) {
        console.error('workspace-to-file: a stash already exists — run "restore" first')
        process.exit(1)
    }
    const rootPkg = readJson('package.json')
    const byName = rebuildWorkspaceMap(rootPkg)
    const stash = { [STASH_KEY]: {} }
    const sections = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']

    for (const dir of collectPackages(rootPkg)) {
        const file = dir ? `${dir}/package.json` : 'package.json'
        let pkg
        let changed = false
        try {
            pkg = readJson(file)
        } catch (error) {
            console.error(`workspace-to-file: skipping unreadable ${file}: ${error.message}`)
            continue
        }
        for (const section of sections) {
            const deps = pkg[section]
            if (!deps) {
                continue
            }
            for (const [name, spec] of Object.entries(deps)) {
                if (typeof spec !== 'string' || !spec.startsWith('workspace:')) {
                    continue
                }
                const target = byName.get(name)
                if (!target) {
                    console.error(`workspace-to-file: no workspace package named ${name} (referenced from ${file})`)
                    process.exit(1)
                }
                // npm accepts a bare relative path with an implicit file: —
                // keep the file: prefix explicit so npm<7-style parsing stays
                // unambiguous.
                const rel = path.posix.relative(dir, path.posix.dirname(target))
                deps[name] = rel.startsWith('.') ? `file:${rel}` : `file:./${rel}`
                changed = true
            }
        }
        if (changed) {
            // stash BEFORE the rewrite and flush the stash to disk per file:
            // a mid-apply crash must always leave a restorable state (each
            // already-rewritten file has its original on disk in the stash).
            stash[STASH_KEY][file] = fs.readFileSync(path.join(root, file), 'utf8')
            writeStash(stash)
            fs.writeFileSync(path.join(root, file), `${JSON.stringify(pkg, null, 2)}\n`)
            console.log(`workspace-to-file: rewrote ${file}`)
        }
    }
    if (Object.keys(stash[STASH_KEY]).length === 0) {
        console.error('workspace-to-file: nothing to rewrite — no workspace:* specs found')
        process.exitCode = 1
        return
    }
    writeStash(stash)
    console.log(`workspace-to-file: stash written (${Object.keys(stash.files).length} files)`)
}

const restore = () => {
    if (!fs.existsSync(stashFile)) {
        console.log('workspace-to-file: no stash to restore')
        return
    }
    let stash
    try {
        stash = JSON.parse(fs.readFileSync(stashFile, 'utf8'))
    } catch {
        console.error('workspace-to-file: stash file is corrupt — cannot restore automatically. ' +
            'Inspect it by hand, then delete .workspace-stash.json after recovery.')
        process.exitCode = 1
        return
    }
    const files = stash[STASH_KEY] ?? {}
    for (const [file, raw] of Object.entries(files)) {
        fs.writeFileSync(path.join(root, file), raw)
    }
    fs.unlinkSync(stashFile)
    console.log(`workspace-to-file: restored ${Object.keys(files).length} files`)
}

// allow import as a library (prebuild inline use) as well as CLI use;
// CLI invocations take the cross-invocation lock.
if (require.main === module) {
    const [mode] = process.argv.slice(2)
    if (mode === 'apply') {
        withLock(apply, 'apply')
    } else if (mode === 'restore') {
        withLock(restore, 'restore')
    } else {
        console.error('usage: node scripts/workspace-to-file.cjs apply|restore')
        process.exit(1)
    }
}

module.exports = { apply, restore }
