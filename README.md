# docker-workspace

Shared base for the project devcontainers: `Dockerfile.base` and
`Dockerfile.godot` build the base images, `post-create-base.sh` and
`post-start-base.sh` run inside containers as lifecycle hooks, and
`devcontainer.sh` / `devcontainer-up.sh` / `devcontainer-down.sh` are the
canonical host-side lifecycle scripts that each project carries a copy of at
its root. `.bashrc-root` and `.bashrc-user` are the container-side shell
profiles.

## SSH agent forwarding

Project devcontainers bind-mount a host ssh-agent socket pinned at a fixed
path, declared in each project's `.devcontainer/compose.yml`:

```yaml
environment:
  SSH_AUTH_SOCK: /tmp/ssh-agent.sock
volumes:
  - type: bind
    source: /tmp/ssh-agent.sock
    target: /tmp/ssh-agent.sock
    bind:
      create_host_path: false
```

The `create_host_path: false` guard makes a container start fail loudly
("bind source path does not exist") when the socket is missing, instead of
letting dockerd silently create the path as a root-owned directory (see
Pitfall below).

Three host-side layers keep that socket alive. All of them are installed by
running any project's `.devcontainer/install-ssh-agent.sh` once per machine:

1. **Boot:** a crontab `@reboot` entry runs `~/.ssh/ensure-ssh-agent.sh`,
   which starts an agent pinned to `/tmp/ssh-agent.sock` at boot. Note that
   cron does not order `@reboot` entries, so if the same machine has another
   `@reboot` bootstrap that can start containers, see step 2 of the setup
   below.
2. **Container start:** each project's `.devcontainer/init-home.sh`
   (`initializeCommand`, runs on the host on every `devcontainer up`) calls
   the same script, so the socket exists even if cron never ran.
3. **Shells:** a `~/.bashrc` block reuses or restarts the pinned agent in
   interactive terminals and adds your key (this is where the passphrase
   prompt happens, once per agent lifetime). It prefers a GPG agent that
   already holds keys, and falls back to the pinned classic agent otherwise.

`ensure-ssh-agent.sh` is idempotent and lock-guarded via `flock` (safe to
run from several places at once), and never replaces a live agent. Note
that only `devcontainer up` runs the pinner automatically; starting a
container with raw `docker restart` or `docker compose up` does not, and
relies on the socket already being pinned.

On GPG-preferring machines the pinned classic agent holds no keys (the
bashrc block switches SSH_AUTH_SOCK to the GPG socket and never adds keys
to the pinned agent). If containers on such a machine need working SSH,
populate the pinned agent manually with
`SSH_AUTH_SOCK=/tmp/ssh-agent.sock ssh-add`.

### New machine setup

1. From any project checkout, run `./.devcontainer/install-ssh-agent.sh`
   (on Windows, inside WSL). It rewrites the bashrc block, installs
   `~/.ssh/ensure-ssh-agent.sh`, registers the crontab entry below if cron
   is available, and pins the agent immediately:

   ```
   @reboot /home/<you>/.ssh/ensure-ssh-agent.sh >> /home/<you>/.ssh/ensure-ssh-agent.log 2>&1
   ```

   If `/tmp/ssh-agent.sock` already exists as a root-owned directory on
   this machine (see Pitfall below), run `sudo rm -rf /tmp/ssh-agent.sock`
   first; the installer's final pinning step will otherwise fail and print
   that same fix.

2. If the machine already has its own `@reboot` bootstrap script (for
   example a machine that boots the switchboard arbiter), also call
   `"$HOME/.ssh/ensure-ssh-agent.sh"` at the top of that script, before
   anything that can start a container. Running it from both places is
   safe; the lock serializes them and a live agent is never replaced.
3. If the machine has no cron at boot (some WSL distros), layer 2 above
   still covers every `devcontainer up`; just avoid auto-starting
   containers by other means (raw `docker compose up`, restart policies)
   before the socket is pinned.

### Pitfall: Docker turns the socket into a root-owned directory

If any container with the mount starts while `/tmp/ssh-agent.sock` does not
exist (classic case: an `@reboot` service brings up a devcontainer after a
reboot, before your first login shell), dockerd creates the missing
bind-mount source as a **root-owned directory**. Because `/tmp` is sticky,
your user cannot delete it.

With the current bashrc block installed, new shells detect this and print
the fix directly:

```
 ❌  /tmp/ssh-agent.sock exists but is not a socket (a container start likely beat the agent to it).
     Fix:  sudo rm -rf /tmp/ssh-agent.sock   then open a new terminal.
```

On machines still running the pre-hardening block, the same condition
surfaced as this cascade (kept here so the symptoms are searchable):

```
unix_listener:: command not found
rm: cannot remove '/tmp/ssh-agent.sock': Is a directory
 ❌  Failed to add SSH key to agent
Error connecting to agent: Permission denied
```

Recovery:

```bash
sudo rm -rf /tmp/ssh-agent.sock
~/.ssh/ensure-ssh-agent.sh
```

Run the second command as your normal user, never via sudo (it refuses
sudo, since a root-owned socket at the sticky /tmp path would be unusable).
It re-pins the socket in every configuration (on GPG-agent machines a new
terminal alone will not recreate it, since the bashrc block switches to the
GPG socket and never touches the pinned path). On classic-agent machines,
also open a new terminal so the bashrc block re-adds your key. Finally,
recreate any container that mounted the directory so it re-mounts the real
socket: use the project's `./devcontainer-up.sh` (it tears the container
down first) or `docker restart <container>`. Bare `devcontainer up` against
an already-running container is a no-op and will not remount the socket.

The boot-time and container-start layers above exist precisely to prevent
this race.
