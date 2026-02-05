# ERA Architecture & Internals

This document details the internal design, communication protocol, and safety mechanisms of the Emacs Remote Agent (ERA).

## 1. Design

ERA operates on a **Request/Response** model over a persistent **Standard I/O (Stdin/Stdout)** stream. Unlike TRAMP, which opens a new SSH connection for many operations, ERA maintains a single, long-running SSH process.

### The Components

1.  **Client (Elisp):**
    * Intercepts Emacs file operations via `file-name-handler-alist`.
    * Encodes requests as JSON-RPC.
    * Manages the SSH process lifecycle.
    * Handles "Virtual" buffers (like directory listings) that don't exist on disk.

2.  **Transport (SSH):**
    * Standard OpenSSH process spawned with `make-process`.
    * Arguments: `ssh -T <host> ~/.local/bin/remote-agent`.
    * **Security:** Relying on SSH ensures traffic is encrypted and authenticated using the user's existing SSH config/keys. No new auth protocols are invented.

3.  **Agent (Rust):**
    * A single-binary executable.
    * Event Loop: Reads Stdin -> Parses JSON -> Executes FS Operation -> Writes JSON to Stdout.
    * **Stateless:** Each request is independent (mostly).
    * **Privilege:** Runs entirely in userspace (no root required).

## 2. Protocol

The communication protocol is a **Length-Prefixed JSON** stream. This prevents issues with "partial reads" or TCP fragmentation where a JSON object might be split into two packets.

**Format:**
`[4-Byte Big-Endian Length Integer] [JSON Payload]`

**Example Exchange:**

*Request (Emacs -> Agent):*

```json
{
  "id": 1,
  "method": "read_chunk",
  "params": {
    "path": "/home/user/data.csv",
    "offset": 0,
    "length": 262144
  }
}
```


*Response (Agent -> Emacs):*

```json
{
  "id": 1,
  "result": {
    "data": "VGhpcyBpcyBhIHRlc3QgZmlsZQ==...", // Base64 encoded
    "bytes_read": 262144
  },
  "error": null
}
```


## 3. Advanced Features & Logic
### A. Chunked File Transfer ("Large File" Solution)

Reading a 5GB file into RAM at once would crash the agent or Emacs.

    Logic:

        Emacs calls stat to get the file size.

        If size > 10MB, it prompts the user.

        If confirmed, Emacs enters a while loop.

        It requests read_chunk with offset=0, length=256KB.

        It appends the decoded Base64 data to the buffer.

        It increments the offset and repeats until EOF.

    Safety: Memory usage remains constant (~5MB) regardless of file size.

### B. Atomic Writes (Safety against Crashes)

Writing directly to a file is dangerous; if the connection drops halfway, the file is corrupted.

    Logic:

        The agent writes chunks to a hidden temporary file: .filename.ra_partial.

        Only when the final: true flag is received in the last chunk does the agent execute fs::rename().

        Result: The destination file is updated atomically. It is either the old version or the fully completed new version, never a half-written corruption.

### C. Symlink Handling

HPC clusters often rely heavily on symlinks (e.g., /home -> /gpfs/u/home).

    Logic: The stat command in Rust explicitly checks fs::symlink_metadata.

    If it detects a symlink, it returns type: "symlink" and includes the symlink_target path.

    This allows Emacs to properly display -> arrows in Dired and follow links correctly.

### D. The "Suicide Switch" (Idle Timeout)

To prevent "zombie" processes on shared login nodes.

    Mechanism: A background thread in Rust checks the time since the last valid request.

    Threshold: 300 seconds (5 minutes).

    Action: If idle > 300s, the process calls exit(0).

    Recovery: Emacs automatically detects the process death. The next time the user tries to open a file, Emacs transparently relaunches a new agent instance.

## 4. Security Measures

    Input Sanitation:

        The get_path function explicitly rejects paths starting with /dev, /proc, or /sys.

        This prevents accidental reading of system streams (like /dev/zero) that could cause infinite loops.

    No Network Listener:

        The agent does not bind to a TCP port (like 0.0.0.0:8080).

        This makes it invisible to port scanners on the cluster and immune to external connection attempts.

    User Isolation:

        The agent runs as the SSH user. It cannot access files that the user does not have permission to read at the OS level.
