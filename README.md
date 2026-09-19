# Pragtical Remote SSH Plugin

This plugin enables the Pragtical editor to work with remote workspaces over an SSH connection. It integrates remote file editing, file system navigation, and terminal routing directly into your local editor interface.

---

## Overview

The plugin operates by establishing a secure SSH tunnel to a remote host and communicating with a lightweight headless server running on that host. By intercepting core file-system APIs inside Pragtical, the plugin redirects file-loading, saving, and directory-listing operations to the remote host over a serialized connection, bypassing local directories.

---

## How It Works

The architecture consists of two main parts:

```txt

┌─────────────────────────────────┐          SSH Tunnel          ┌──────────────────────────────────┐
│        Pragtical (Local)        │    (Port Forwarding: 8080)   │         Remote Server            │
│                                 │                              │                                  │
│  ┌───────────┐   ┌───────────┐  │  ┌────────────────────────┐  │  ┌────────────────────────────┐  │
│  │ init.lua  │─> │bridge.lua │──┼─>│ local port 8080 (TCP)  │──┼─>│   ~/.pragtical/bin/        │  │
│  └───────────┘   └───────────┘  │  └────────────────────────┘  │  │   headless-server          │  │
│    (Intercepts     (Framing &   │                              │  └────────────────────────────┘  │
│     API Calls)      Sockets)    │                              │        (Nim Executable)          │
└─────────────────────────────────┘                              └──────────────────────────────────┘
```

1. **The Client Bridge (Lua):** Runs inside your local Pragtical editor. It intercepts standard file operations (such as `system.list_dir`, `system.get_file_info`, `Doc:load`, and `Doc:save`) and routes them through a multiplexed TCP connection over an SSH tunnel. It uses a custom MessagePack implementation for binary serialization.
2. **The Headless Server (Nim):** Runs on the remote machine. This lightweight compiled program executes file-system operations and process spawning, returning serialized results back to the client. 
3. **Network Protocol:** Communication is performed over a TCP connection forwarded via SSH. To ensure stability, messages are packaged using a 4-byte big-endian length prefix followed by a MessagePack-encoded payload.

---

## Key Features

* **Remote File System Interception:** Transparently open, edit, and save remote files as if they were local.
* **Metadata & List Cache:** Utilizes Time-To-Live (TTL) cache structures for directory structures and file metadata to reduce synchronous network latency during UI redraws.
* **Integrated Terminal Routing:** Automatically overrides local terminal initialization to launch an SSH shell session positioned inside your active remote working directory.
* **Polling Suppressions:** Disables background file-watching (`DirWatch`) and recursive workspace polling (`Project:files`) on remote workspaces to prevent excessive CPU and network consumption.
* **SSH Config Suggestions:** Parses your local `~/.ssh/config` file to provide auto-completion suggestions when entering a host.
* **Remote New File Creation:** The `Remote: New File` command creates a new file on the remote host directly from the command palette (always available while connected), creates it through the bridge, refreshes the sidebar, and opens it for editing. The Treeview's built-in `New File` action is also routed through the bridge so it works on remote paths.
* **Workspace Refresh:** The `Remote: Refresh` command clears the directory/metadata caches and the Treeview sidebar cache so the sidebar re-queries the remote host — useful after files are created or modified outside the editor.
* **Auto-Refresh Around the Terminal:** Since background polling is suppressed, the sidebar automatically refreshes when focus leaves a remote terminal view and periodically (every few seconds) while a remote terminal is the active view, so files created in the SSH terminal appear without a manual refresh.
* **Consistent Tab Titles:** Remote document tabs show just the file's basename (e.g. `file.txt`), uniformly whether the file lives at the remote root or inside a subdirectory.

---

## Prerequisites & Requirements

Before setting up the plugin, ensure your environment meets the following conditions:

* **Operating System Support:** This plugin has been developed and tested primarily on **Linux (Ubuntu)** environments. 
* **SSH Public Key Authentication:** Your SSH public key **must already be configured** on the remote server (e.g., inside `~/.ssh/authorized_keys`). The plugin only initiates connection pipelines; it does not manage key distribution or password authentication.
* **Local SSH Configurations:** The plugin depends on a ssh config file. Host aliases should be defined in your local `~/.ssh/config` file.
* **Nim Compiler (For Compiling Server):** If compiling from source, the Nim compiler must be installed on your build machine.

---

## Compilation & Deployment

The toolchain requires the compilation of the remote headless server and the installation of the Lua files into your Pragtical configuration.

### 1. Clone the Repository
```bash
git clone <repository-url> pragtical-remote-ssh
cd pragtical-remote-ssh
```

### 2. Build the Remote Headless Server
You can use the prebuilt binary at `built-binaries/ubuntu-24/x86_64/`. If you want to compile the server yourself, run the build script. By default, it targets Linux environments:

```bash
# Compiles the Nim headless server with danger and orc options
./build.sh
```

To cross-compile the executable for a Windows target using MinGW:
```bash
./build.sh --windows
```

The compiled binary will be located in: `built-binaries/ubuntu-24/x86_64/headless-server` (or `headless-server.exe` for Windows).

### 3. Deploy the Headless Server to the Remote Host
Edit the target host variable inside `copy-headless-to-remote.sh`:
```bash
# Open and update the HOST variable with your SSH config host alias
HOST="your-ssh-host-alias"
```

Run the deployment script to transfer the binary:
```bash
chmod +x copy-headless-to-remote.sh
./copy-headless-to-remote.sh
```
This script creates a directory structure at `~/.pragtical/bin/` on the remote server and secure-copies the compiled `headless-server` binary into it.

### 4. Install the Local Pragtical Plugin
Run the installation script to copy the Lua files to your local Pragtical directory:
```bash
chmod +x copy-plugin-to-pragtical.sh
./copy-plugin-to-pragtical.sh
```
This transfers `init.lua`, `bridge.lua`, and `messagepack.lua` into `~/.config/pragtical/plugins/remote-ssh/`.

---

## Usage

Restart Pragtical and use the command palette (`Ctrl+Shift+P` or `Cmd+Shift+P`) to interact with the plugin:

### Connecting to a Host
1. Open the command palette and run: `Remote: Connect SSH`
2. Select your SSH host from the autocomplete suggestions (parsed from your SSH config) or type it manually.
3. The plugin will launch the SSH tunnel, start the remote agent, and verify the connection.

### Changing Directories
1. Run the command: `Remote: Change Directory`
2. Input the absolute path of the remote directory you want to open.
3. The workspace sidebar (Treeview) and status bar will refresh to reflect your remote folder structure.

### Creating a New File
1. Run the command: `Remote: New File` (available in the palette only while a remote session is active).
2. Enter the filename relative to the remote working directory (e.g. `notes.txt` or `src/main.lua`). Path autocompletion is offered from the remote listing.
3. The file is created on the remote host, the sidebar is refreshed so it appears immediately, and the file is opened in a new tab.

> The Treeview context-menu **New File** action also works on remote paths: it is routed through the bridge rather than attempting a local disk write. The remote working directory must be writable by the SSH user (a `cannot open` error indicates a server-side permission issue — run `Remote: Change Directory` to a writable directory).

### Refreshing the Workspace
1. Run the command: `Remote: Refresh`.
2. The remote directory/metadata caches and the Treeview sidebar cache are cleared; the sidebar re-queries the remote host on its next draw.

> You normally don't need this: the sidebar auto-refreshes when focus leaves a remote terminal and every few seconds while a remote terminal is the active view. Use it manually after making changes on the remote host through some other channel.

### Disconnecting
1. Run the command: `Remote: Disconnect`
2. Active remote document views will close, the SSH process will terminate, and the local workspace environment will reset.

## Running test
```sh
PRAGTICAL_USERDIR=/tmp/pragtical_test_user /home/kels7/.local/bin/pragtical test tests/
```
Run from plugin root. First run: mkdir -p /tmp/pragtical_test_user (one-time, clean userdir so installed plugin won't load).

