# Emacs Remote Agent (ERA)

**Remote Editing for Emacs (VS Code Remote-SSH style)**

ERA is a remote file editing backend for Emacs designed specifically for **HPC clusters, high-latency networks, and restricted server environments**. It replaces standard TRAMP SSH connections with a high-speed, asynchronous Rust agent.

> **⚠️ Beta Release (v0.5)**
> This project is currently in a public review phase. Please audit the codebase for potential security concerns or edge cases before the final v1.0 release. Please report any findings via GitHub Issues.

## Acknowledgments & Methodology

**AI-Assisted Development**
This project was developed using an iterative "AI-Cross-Check" methodology. Code and architecture were generated, refined, and debugged by cross-comparing solutions from multiple Large Language Models (LLMs) to ensure robustness and security.

### Methodology:
First, a thematic outline was created, which was subsequently converted into working sections of code, by rounds of prompting. This code was then cross checked iteratively between Qwen3 and Gemini 3 Pro, in order to filter out code hallucinations, lazy code, and security problems. A robust version was then tested and further critiqued/debugged by both models.

* **Models Used:**
    * **Gemini 3 Pro (Google):** Core architecture design, Elisp client implementation, and TRAMP protocol integration.
    * **Qwen 2.5/3 (Alibaba Cloud):** Rust backend optimization, HPC hardening, and security auditing.



## Why Use This?

If you work on HPC clusters or distant servers, you likely face these problems:
* **TRAMP is slow:** It sends shell commands (`ls`, `test`, `cat`) over SSH, which causes UI freezes on high-latency connections.
* **Treemacs Freezes:** expanding large remote folders usually hangs Emacs while TRAMP parses `ls` output.
* **Connection drops:** Standard SSH connections die when the network hiccups.

**ERA solves this by:**
1.  **Running a lightweight Rust binary** on the server (consuming <5MB RAM).
2.  **Using a single SSH connection** with a binary JSON-RPC protocol (no repetitive shell command overhead).
3.  **No Open Ports:** Communicates entirely over SSH Standard I/O (Stdin/Stdout), bypassing firewall restrictions.
4.  **Asynchronous I/O:** Emacs never freezes while reading or writing large files.

## Architecture

Unlike TRAMP (which acts like a shell user) ERA uses this Architecture**:

1.  **A Client:** An Emacs Lisp package hooks into `file-name-handler-alist`. When you open `/ra:host:/path`, it intercepts the call.
2.  **A Transport:** Emacs launches a secure SSH process: `ssh host ~/.local/bin/remote-agent`.
3.  **An Agent:** A compiled Rust binary on the server listens on Stdin. It performs file system operations (read, write, list) locally and streams the results back as JSON.

More details can be found in the ARCHITECTURE.md file.

## Installation

### 1. Server-Side (The Rust Agent)
You need to compile the agent for your remote server.

**Option A: Compile on the Remote Server (Easiest)**
If your remote server has `cargo` (Rust) installed:

```bash
# SSH into your server
ssh user@your-cluster

# Clone this repo or copy the source files
git clone [https://github.com/era-emacs-tools/ERA.git](https://github.com/era-emacs-tools/ERA.git)
cd emacs-remote-agent

# Build the release binary
cargo build --release

# Install to your user binary folder (No root required!)
mkdir -p ~/.local/bin
mv target/release/emacs-remote-agent ~/.local/bin/remote-agent
```


**Option B: Cross-Compile Locally**
If you cannot install Rust on the server, compile it on your machine for the target architecture (usually x86_64-unknown-linux-musl) and scp the binary to ~/.local/bin/remote-agent on the server.

### 2. Client-Side (Emacs)

Add the Elisp client to your Emacs configuration.

Copy remote-agent.el to your load path (e.g., ~/.emacs.d/lisp/).

Add the following to your init.el or config.el:
    
    (add-to-list 'load-path "~/.emacs.d/lisp/")
    (require 'remote-agent)

    ;; Optional: Customize the path if you installed the binary somewhere else
    ;; (setq ra-agent-remote-path "~/bin/remote-agent")



## Usage
### Connecting

To open a remote file, use the /ra: prefix instead of /ssh: or /scp:.

Format: /ra:user@hostname:/path/to/file

### The "HPC Workflow"

ERA is designed for the "Decoupled" workflow common in scientific computing:

Edit Files: Use Emacs with /ra: to edit code, config files, and scripts. Auto-save and Auto-revert work instantly.

Run Commands: Open a separate terminal (or M-x vterm / M-x ra-shell) to run sbatch, python, or cargo.

Note: ERA does not currently support running shell commands (like M-x grep) directly through the agent. Use a dedicated terminal for execution.

## Security & Safety

Encryption: All data is transmitted over standard SSH. It inherits all your SSH key configurations and security policies.

Path Traversal Protection: The agent explicitly blocks access to /dev, /proc, and /sys to prevent accidents.

Idle Timeout: The agent includes a "Suicide Switch." If Emacs disconnects or stops sending requests for 5 minutes, the remote binary automatically exits to prevent "zombie" processes on the cluster.

Resource Usage: The agent is designed to run on Login Nodes without triggering high-usage alerts.

## Known Limitations

Magit: It is recommended to disable Magit for /ra: buffers. Git checks over high-latency networks are slow, regardless of the backend. Use git from the command line.

Shell Commands: Functions like M-x shell-command or M-x grep are not supported.

## License

MIT License
