# Star Command

*Command every port. Watch every agent.*

A free, open-source macOS menu bar app for engineers who run agents. It keeps
SSH, Kubernetes and AWS Session Manager port forwards up through drops, sleep,
network changes and expired SSO, and shows every Claude Code session, the dev
servers it started and the ports they hold. Individual forwards toggle on and
off from the menu.

Site: [strcmd.com](https://strcmd.com). Star Command was called Berth before
0.1; on first launch it picks up Berth's config and settings.

## Connection types

- **SSH**: one `ssh -M -N` ControlMaster process per connection. Forwards are
  added and removed live with `ssh -O forward` / `ssh -O cancel`, so you never
  reconnect just to add a port.
- **Kubernetes**: each forward runs `kubectl port-forward` against a context and
  namespace. The resource is a service, deployment, or pod such as `svc/web`.
- **AWS**: one connection per profile and region. Each forward picks a
  service (host, RDS, MSK or Airflow) and a resource. See [AWS](#aws).

Every forward binds to `127.0.0.1:<local port>` on your Mac.

Reconnect behaviour, per host (on by default):

- `ServerAliveInterval` detects a dead link within about 30 seconds and the
  app reconnects with exponential backoff (3s, 6s, 12s ... capped at 60s).
- On wake from sleep, and whenever the network path changes, every connected
  host is probed with a real round trip. Dead connections are torn down and
  re-established, and hosts stuck in backoff retry immediately.
- All enabled forwards are re-applied after every reconnect.
- A single forward that dies on its own, such as a `kubectl port-forward`
  losing its pod, is restarted with the same backoff without touching the
  other forwards on that connection.

## Remote and SOCKS forwards

SSH connections support all three OpenSSH forward types. Pick one per forward
in the editor:

- **Local** (`-L`): `localhost:<local port>` on your Mac reaches
  `<remote host>:<remote port>` as seen from the server.
- **Remote** (`-R`): the server opens `<remote port>` and anything connecting
  to it reaches `<remote host>:<local port>` as seen from your Mac.
- **SOCKS** (`-D`): a SOCKS proxy on `localhost:<local port>` that tunnels
  through the server.

Kubernetes and AWS connections only do local forwards. Remote and SOCKS
forwards are added and removed live like local ones, and the menu's
"open in browser" button appears only for local forwards.

## AWS

An AWS connection is a profile and region. Connecting checks the credentials
with `aws sts get-caller-identity`; an expired SSO session shows as
`SSO expired. Run: aws sso login --profile <profile>` and is retried with the
usual backoff. With **Sign in again in the browser when SSO expires** on (the
default), Star Command runs that `aws sso login` itself when the connection check or
a forward fails on an expired token, waits up to five minutes for you to
approve it in the browser, then retries. Connections sharing a profile share
one sign-in. If a sign-in is not approved, Star Command waits 15 minutes before
opening the browser again, and pressing reconnect skips that wait. Each forward row picks a service, then a resource, then local
port to remote port. The editor lists the databases, Kafka clusters, Airflow
environments and SSM-online instances it finds for the profile and region.
Breakglass profiles are never scanned.

| Service | Resource | How it connects |
| --- | --- | --- |
| Host | any host:port the jump host can reach, or `localhost` for the jump host itself | SSM port forwarding |
| RDS | DB instance identifier; the endpoint is looked up on connect | SSM port forwarding |
| MSK | one broker hostname of a cluster, port 9092 | SSM port forwarding |
| Airflow (MWAA) | environment name | local sign-in gateway, no SSM |

**Jump host.** Host, RDS and MSK forwards go through an SSM-managed instance
inside the VPC and need the Session Manager plugin
(`brew install --cask session-manager-plugin`). An AWS connection with only
Airflow forwards works without it. The jump host setting is either a fixed
instance id (`i-…`) or a `Name` tag pattern, `*-system-node` by default, and
an empty value means any online instance. A pattern is resolved on every
connect to the first running, SSM-online instance whose `Name` matches, so EKS
nodes replaced by autoscaling are followed automatically. After a forward
drops, the pattern is resolved again but keeps the current instance while it
is still online. The chosen instance is written to the connection log.

**Airflow sign-in.** MWAA web servers are public and only accept a sign-in on
their own hostname, so they are not tunnelled. Star Command listens on
`127.0.0.1:<local port>`, and opening `http://localhost:<port>` mints a
short-lived login token with `aws mwaa create-web-login-token` and redirects
the browser to the Airflow hostname. The token is never logged, and requests
with a `Host` header other than `localhost:<port>` or `127.0.0.1:<port>` are
refused. A failed sign-in, such as expired SSO, shows under the forward in the
menu and on the page the browser lands on.

**MSK limitation.** A Kafka client contacts the bootstrap address, then
receives every broker's own hostname in the cluster metadata and connects to
those directly. An MSK forward reaches one broker on `localhost:<port>`,
which is enough for tools that talk to a single broker, but a normal client
also needs each `b-N…` hostname to resolve to a forwarded local address. Star Command
does not edit `/etc/hosts` or add loopback aliases; set that up yourself if
you need full client access.

Earlier versions kept Airflow environments in `airflow.json`. On first launch
Star Command turns each one into an Airflow forward on an AWS connection for its
profile and region, creating `AWS <name>` connections as needed, and renames
the file to `airflow.json.migrated`.

## Importing forwards from SSH config

In an SSH connection's editor page, **Import forwards from SSH config** runs
`ssh -G <destination>` and adds every `LocalForward`, `RemoteForward` and
`DynamicForward` the resolved config declares for that host, including ones
that come through `Match` blocks and `Include`d files. Forwards with the same
route as an existing one are skipped, so the button is safe to press again.

## Copying and reordering

Each forward row in the editor has a **⋯** menu: **Duplicate** inserts a copy below it on the next free local port, **Copy to** appends a copy to another connection (adjusted to that connection's type, so SOCKS or remote forwards become local outside SSH), and **Move up** / **Move down** reorder it. Connections can be dragged in the sidebar to reorder them, and duplicated from its context menu or the toolbar. Copies always start switched off so they never fight the original for a port. The menu panel follows the same order.

## Menu controls

Each connection in the menu panel has a power switch, a reconnect button
while it is wanted, a log button, and an `active/enabled` forward count. Each
forward has its own switch, a route line that copies `localhost:<port>` to the
clipboard when clicked, and an open-in-browser button once it is up. Errors
show inline under the connection or forward that produced them, and the menu
bar rocket fires while connections are up and tips over when a wanted
connection has failed.
**Disconnect All** at the bottom tears down every connection at once.

## Launch at login

The General page of the editor has a **Launch at login** toggle, backed by
`SMAppService`. It only works from an installed `Star Command.app` bundle, not
from `swift run`. If macOS requires approval, the page offers a button to open
Login Items in System Settings.

## Notifications

When a connection drops unexpectedly, Star Command posts a system notification
with the reason, and another when it reconnects. Disconnecting a connection
yourself never notifies. One drop produces one notification no matter how
many reconnect attempts follow. Turn this off under General, and expect a
permission prompt from macOS the first time a notification is posted.
Notifications are only available from the installed app bundle.

## Log window

The log button next to a connection, in the menu panel, opens a per-connection
log of connects, drops, forward failures and the last line of any tool error.
The window keeps the most recent 500 entries per connection, follows new
output until you scroll up, and has **Copy All** and **Clear** buttons. Entries
are kept in memory only and vanish when the app quits.

## Process monitor

The **System** section of the menu panel shows overall CPU, memory and the
three busiest processes, and **Open Process Monitor** opens a window with a
searchable, sortable table of processes with CPU %, memory and PID, plus host
CPU, memory and load averages. Select a row to **Quit** (SIGTERM) or
**Force Quit** (SIGKILL) it, **Pause** (SIGSTOP) and **Resume** it, or lower
its priority. The table also shows disk throughput, thread count and the TCP
ports each process is listening on, and a details line gives the path, parent
process and ports of the selected row.

When a forward fails with "Address already in use", the menu looks up which of
your processes holds the port and offers **Quit it**, then retries the forward.
The **Free a port** field in the System section does the same for any port.

The monitor only sees processes owned by your user. macOS lets an unprivileged
app list every process, but refuses to report CPU time, memory or even the
executable name for processes owned by other users, which includes
`WindowServer`, `kernel_task` and everything that runs as root. Those rows are
left out rather than shown with blank numbers, so the table is a subset of
what Activity Monitor shows. Memory is the physical footprint, matching
Activity Monitor's Memory column, and CPU % can exceed 100 on multi-threaded
processes.

## Stay awake

The **Stay awake** row in the menu holds a macOS power assertion, like
`caffeinate`, in one of two modes: keep the Mac awake but let the display
sleep, or keep both awake. Choose a duration of 1, 4 or 8 hours or until you
turn it off. The General page can also hold the Mac awake automatically while
any connection is switched on, which keeps forwards and remote sessions alive
through idle sleep. Closing the lid still sleeps a laptop that is not on power
with an external display.

## Latency

Connected SSH links show their round trip in milliseconds beside the status
dot, measured through the multiplexed connection every minute. If a probe
fails the connection is treated as dropped and reconnected. Kubernetes and AWS
connections show the time of their API probe instead, labelled "probe", and
are only probed on connect and after wake or network changes.

## Shortcut and tools

Control+Option+B opens the menu panel from anywhere. It can be switched off on
the General page. The **Tools** row starts or stops a Time Machine backup and
opens the Login Items settings page.

## Requirements

- macOS 14 or later.
- Key-based auth that works non-interactively. The app runs ssh with
  `BatchMode=yes`, so it never prompts. If a host fails with
  `Permission denied (publickey)`, load the key into your agent:
  `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.
- SSH hosts are addressed exactly like on the command line: an alias from
  `~/.ssh/config` or `user@hostname`.
- `kubectl` and `aws` are found on the usual Homebrew and system paths, and
  the editor offers your kube contexts and AWS profiles as suggestions.

## Build and run

```sh
./build.sh            # builds "build/Star Command.app"
./build.sh --install  # also copies it to /Applications
swift run             # dev loop, no app bundle
```

Config lives at `~/Library/Application Support/Star Command/config.json`.

## Releasing

Push a tag such as `v0.1.0`. The Release workflow runs the tests, builds
`Star Command.app` with that version, and attaches `StarCommand.zip` and its SHA-256 to a
GitHub release. Builds are ad-hoc signed, not notarized, so first-time users
clear the quarantine flag with
`xattr -dr com.apple.quarantine "/Applications/Star Command.app"`.

The landing page in `site/` deploys to GitHub Pages on every push to `main`
that touches it. Enable Pages with the source set to GitHub Actions; `site/CNAME`
serves it at strcmd.com.

## Sponsoring

Star Command is free. If it saves you time, you can sponsor it through
[GitHub Sponsors](https://github.com/sponsors/strcmdhq).

## License

MIT. See [LICENSE](LICENSE).
