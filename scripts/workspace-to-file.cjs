#!/usr/bin/env node
/**
 * workspace-to-file.cjs — npm-compat manifest derivation for the Debian build.
 *
 * The repo is bun-canonical: "workspace:*" dependency specs and `resolutions`.
 * npm rejects the workspace protocol outright (EUNSUPPORTEDPROTOCOL) and
 * forbids overriding a package the root depends on directly (EOVERRIDE when
 * `rollup` is both a direct dependency and an overrides alias). The Debian
 * prebuild runs the whole toolchain inside a disposable copy (build/source,
 * see scripts/debian-prebuild.sh) and derivES the npm-compatible manifests
 * THERE — the repo working tree is never written:
 *
 *   node scripts/workspace-to-file.cjs apply <targetRoot>
 *
 * Derivation, mechanical:
 *   - root package.json: an `overrides` block mirrored from `resolutions`;
 *     direct deps that the overrides redirect are dropped (npm EOVERRIDE —
 *     the `rollup -> npm:@rollup/wasm-node` alias stands in for the direct
 *     entry; the `@rollup/wasm-node` dependency pins the version the alias
 *     resolves to, it has no import site).
 *   - member manifests: bun-style "workspace:*" / "workspace:^x" specs become
 *     npm `file:` specs.
 *
 * The vendored payload ships the REPO manifests (workspace:*): the prebuild
 * copies the originals back over build/source before staging. Nothing parses
 * dep specs outside installs, so the .deb determinantly carries the
 * bun-canonical spelling.
 */
'use strict'

const fs = require('fs')
const path = require('path')

const SECTIONS = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']

const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'))

// Turn a workspaces entry (relative to targetRoot) into a directory list:
// fixed paths as-is, one-level globs ("packages/qadams/core/*") expanded by
// readdir.
const workspaceDirs = (targetRoot, entry) => {
    const parts = entry.split('/')
    const last = parts[parts.length - 1]
    if (!last.includes('*')) {
        return [entry]
    }
    const parent = parts.slice(0, -1).join('/')
    if (!fs.existsSync(path.join(targetRoot, parent))) {
        return []
    }
    return fs.readdirSync(path.join(targetRoot, parent))
        .map((name) => path.posix.join(parent, name))
        .filter((dir) => fs.statSync(path.join(targetRoot, dir)).isDirectory())
}

const collectPackages = (targetRoot, rootPkg) => {
    const files = []
    for (const entry of rootPkg.workspaces ?? []) {
        for (const dir of workspaceDirs(targetRoot, entry)) {
            const file = `${dir}/package.json`
            // glob parents may carry bare namespace directories
            // (packages/qadams in a "packages/*"-style glob) — skip anything
            // that is not a real member manifest
            if (fs.existsSync(path.join(targetRoot, file))) {
                files.push(file)
            }
        }
    }
    return files
}

const rebuildWorkspaceMap = (targetRoot, rootPkg) => {
    const byName = new Map()
    for (const file of collectPackages(targetRoot, rootPkg)) {
        const pkg = readJson(path.join(targetRoot, file))
        if (pkg.name) {
            byName.set(pkg.name, path.posix.dirname(file))
        }
    }
    return byName
}

// npm-compat root manifest: mirror `resolutions` into `overrides`, then drop
// the direct deps that the overrides redirect (npm refuses EOVERRIDE).
const deriveRoot = (targetRoot) => {
    const file = path.join(targetRoot, 'package.json')
    const pkg = readJson(file)
    if (!pkg.resolutions || Object.keys(pkg.resolutions).length === 0) {
        console.error('workspace-to-file: no resolutions in the root manifest — nothing to derive')
        process.exitCode = 1
        return false
    }
    if (pkg.overrides) {
        console.error('workspace-to-file: dropping an existing overrides block (mirrored from resolutions)')
    }
    const overrides = { ...pkg.resolutions }
    for (const section of SECTIONS) {
        const deps = pkg[section]
        if (!deps) {
            continue
        }
        for (const name of Object.keys(deps)) {
            if (name in overrides) {
                delete deps[name]
            }
        }
    }
    pkg.overrides = overrides
    fs.writeFileSync(file, `${JSON.stringify(pkg, null, 2)}\n`)
    console.log(`workspace-to-file: derived npm root manifest (overrides: ${Object.keys(overrides).length})`)
    return true
}

const apply = ({ targetRoot }) => {
    // refuse to guess: a git checkout is the world this script must never
    // write (the operand is always the disposable build/source copy)
    if (fs.existsSync(path.join(targetRoot, '.git'))) {
        console.error(`workspace-to-file: ${targetRoot} looks like a git checkout — refusing; pass the disposable build/source copy`)
        process.exitCode = 1
        return
    }
    if (!fs.existsSync(path.join(targetRoot, 'package.json'))) {
        console.error(`workspace-to-file: no package.json under ${targetRoot} — refusing`)
        process.exitCode = 1
        return
    }
    if (deriveRoot(targetRoot) === false) {
        return
    }
    const rootPkg = readJson(path.join(targetRoot, 'package.json'))
    const byName = rebuildWorkspaceMap(targetRoot, rootPkg)

    let changed = 0
    for (const file of collectPackages(targetRoot, rootPkg)) {
        let pkg
        try {
            pkg = readJson(path.join(targetRoot, file))
        } catch (error) {
            console.error(`workspace-to-file: skipping unreadable ${file}: ${error.message}`)
            continue
        }
        let touched = false
        for (const section of SECTIONS) {
            const deps = pkg[section]
            if (!deps) {
                continue
            }
            for (const [name, spec] of Object.entries(deps)) {
                if (typeof spec !== 'string' || !spec.startsWith('workspace:')) {
                    continue
                }
                const memberDir = byName.get(name)
                if (!memberDir) {
                    console.error(`workspace-to-file: no workspace package named ${name} (referenced from ${file})`)
                    process.exitCode = 1
                    return
                }
                // npm accepts a bare relative path with an implicit file: —
                // keep the file: prefix explicit so npm<7-style parsing stays
                // unambiguous.
                const rel = path.posix.relative(path.posix.dirname(file), memberDir)
                deps[name] = rel.startsWith('.') ? `file:${rel}` : `file:./${rel}`
                touched = true
            }
        }
        if (touched) {
            fs.writeFileSync(path.join(targetRoot, file), `${JSON.stringify(pkg, null, 2)}\n`)
            changed += 1
            console.log(`workspace-to-file: derived ${file}`)
        }
    }
    console.log(`workspace-to-file: derived npm manifests (${changed} member files + root)`)
}

if (require.main === module) {
    const [mode, targetRoot] = process.argv.slice(2)
    if (mode === 'apply' && targetRoot) {
        apply({ targetRoot: path.resolve(targetRoot) })
    } else {
        console.error('usage: node scripts/workspace-to-file.cjs apply <targetRoot>')
        process.exitCode = 1
    }
}

module.exports = { apply }
