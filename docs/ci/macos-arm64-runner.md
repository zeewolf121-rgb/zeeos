# Self-hosted macOS ARM64 runner (Phase 0 decision D9)

aarch64 ISO builds and aarch64 boot/install tests run on a self-hosted Apple Silicon Mac. Builds run in a rootful Fedora aarch64 container inside a `podman machine` VM (kiwi-ng needs loop devices). VM tests use QEMU with HVF acceleration.

## Requirements

- Apple Silicon Mac, macOS 15 or later, always on and on wired network.
- 16 GB RAM or more (8 GB goes to the podman VM), 150 GB free disk.
- A **dedicated, non-admin macOS user** (`zeeos-runner`) that runs nothing else.

## Security rules

- Use this runner **only while the repo is private**. A self-hosted runner on a public repo runs code from fork PRs. If the repo goes public, first restrict the runner group and require approval for fork workflows, or remove the runner.
- Register it to `zeewolf121-rgb/zeeos` only, never at account/org level for all repos.
- No signing keys on this machine. Release signing (ADR-0007) runs only on GitHub-hosted runners.
- The registration token from GitHub is short-lived. Don't save it anywhere, and never commit it.

## Setup (once, as the owner)

1. Create the user: System Settings → Users & Groups → add `zeeos-runner` (standard account). Log in as that user for the remaining steps.
2. Install the tools:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install podman qemu jq gh
   ```
3. Create the build VM:
   ```bash
   podman machine init --rootful --cpus 6 --memory 8192 --disk-size 120 zeeos
   podman machine start zeeos
   podman run --rm --privileged registry.fedoraproject.org/fedora:44 uname -m   # expect aarch64
   ```
4. Register the runner: GitHub → repo **Settings → Actions → Runners → New self-hosted runner → macOS / ARM64**. Run the download and `./config.sh` commands it shows, inside `~/actions-runner`. When asked for labels, add `zeeos-aarch64` (it keeps `self-hosted`, `macOS`, `ARM64`).
5. Run it as a service, so it starts at boot:
   ```bash
   cd ~/actions-runner && ./svc.sh install && ./svc.sh start
   ```
6. Keep the Mac awake: System Settings → Energy → prevent automatic sleeping when the display is off. Also set the podman machine to start at login, for example with a LaunchAgent that runs `podman machine start zeeos`.
7. Check: the runner shows **Idle** under Settings → Actions → Runners. Then run the `runner-check` workflow from the Actions tab (added by the Phase 1 runner issue).

Workflows target it with `runs-on: [self-hosted, macOS, ARM64, zeeos-aarch64]`. Until the runner is online, aarch64 jobs stay on `ubuntu-24.04-arm` (slow TCG tests), so nothing waits forever in the queue.
