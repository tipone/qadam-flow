# debian/

Sources for the future `.deb` package. Nothing here is used by the Docker
install or by `npm run dev`; the live files on a host are
`/etc/qadam-flow/*.conf` and `/lib/systemd/system/qadam-flow-*.service`.

| File | Installs to | Mode |
| --- | --- | --- |
| `master.conf` | `/etc/qadam-flow/master.conf` | 0600 root:root (conffile) |
| `worker.conf` | `/etc/qadam-flow/worker.conf` | 0600 root:root (conffile) |
| `qadam-flow-master` | `/usr/bin/qadam-flow-master` | 0755 |
| `qadam-flow-worker` | `/usr/bin/qadam-flow-worker` | 0755 |
| `qadam-flow-master.service` | `/lib/systemd/system/` | 0644 |
| `qadam-flow-worker.service` | `/lib/systemd/system/` | 0644 |

systemd reads the two conf files as root before dropping privileges, so the
`qadam` user never needs to read them. Keep them 0600: they hold
`AP_JWT_SECRET`, `AP_ENCRYPTION_KEY`, the database password and
`AP_WORKER_TOKEN`.

## Runtime layout

    /usr/lib/qadam-flow/                 program tree (root:root, 0755)
    /usr/share/qadam-flow/web/           frontend build
    /var/lib/qadam-flow/                 state (qadam:qadam, 0750)
    /var/cache/qadam-flow/               cache (qadam:qadam, 0750)
    /usr/share/doc/qadam-flow/           copyright, changelog, README.Debian

`StateDirectory=qadam-flow` and `CacheDirectory=qadam-flow` create the two
`/var` directories. The app creates `qadam-versions/` and its subdirectories
itself.

The service user is a system account with no login shell:

    adduser --system --group --home /var/lib/qadam-flow --no-create-home qadam

## Before first start

Replace every placeholder in both confs:

- `AP_FRONTEND_URL` — the public HTTPS URL of the web app.
- `AP_POSTGRES_PASSWORD` — the database password.
- `AP_ENCRYPTION_KEY` — `openssl rand -hex 16` (32 hex characters).
- `AP_JWT_SECRET` — `openssl rand -hex 32`.
- `AP_WORKER_TOKEN` — minted from `AP_JWT_SECRET`, see `INSTALL.md`.

`AP_ENCRYPTION_KEY=CHANGE_ME` fails the API's 32-hex check at startup;
`AP_JWT_SECRET` accepts any non-empty string, so a forgotten `CHANGE_ME`
there is only caught by review. The confs are 0600, so read the secret with
`sudo` when minting the worker token.

## Verify after install

    systemd-analyze verify /lib/systemd/system/qadam-flow-master.service
    systemctl show qadam-flow-master -p Environment
    systemctl show qadam-flow-worker -p Environment

Editing a conf needs `systemctl restart`; `daemon-reload` is only for unit
file changes.

## Two symlinks the package must create

The server resolves these paths against its working directory
(`process.cwd()`), so the package has to bridge them:

    /usr/lib/qadam-flow/cache               -> /var/cache/qadam-flow
    /usr/lib/qadam-flow/dist/packages/web   -> /usr/share/qadam-flow/web

Without the first, the worker cannot write its cache under
`ProtectSystem=strict`. Without the second, the API's `fastifyStatic`
registration in production fails at startup. Create them from `debian/links`
or `postinst`.

## Security notes

- `UNSANDBOXED` runs Code steps with the worker's own privileges. Use
  `SANDBOX_CODE_ONLY` for untrusted users. `SANDBOX_PROCESS` additionally
  needs `CAP_SYS_ADMIN`; drop `NoNewPrivileges` and add
  `AmbientCapabilities=CAP_SYS_ADMIN` to the worker unit in that case.
- The worker health server binds every interface on `AP_PORT` (the code has
  no host parameter). Firewall 3000 and 3001 to localhost; only 80/443
  should be public.
- `LimitCORE=0` keeps core dumps, which can contain secrets, off disk.

## Future packaging files

`control`, `rules`, `changelog`, `copyright` (DEP-5, MIT), `source/format`,
`install`, `links`, `conffiles`, `postinst`, `prerm`, `postrm`. The units and
confs stay where they are; `install` maps them to the paths above, and
`conffiles` lists the two `/etc` paths so upgrades keep local edits.

`master` is our name for the process; the code calls it `APP`
(`AP_CONTAINER_TYPE=APP`). The value inside the conf is what matters.
