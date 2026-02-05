;;; remote-agent.el --- Production-grade remote file access for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Your Name
;; Author: ERA Maintainers
;; Version: 0.5
;; Package-Requires: ((emacs "27.1"))
;; Keywords: files, remote, hpc
;; URL: https://github.com/era-emacs-tools/era

;; This file is NOT part of GNU Emacs.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'base64)
(require 'seq)
(require 'tramp)


;; Removed -q to prevent breaking your SSH ProxyCommand.
(with-eval-after-load 'tramp
  (add-to-list 'tramp-methods
               '("ra"
                 (tramp-login-program "ssh")
                 (tramp-login-args (("-l" "%u") ("-p" "%p") ("%c") ("-e" "none") ("%h")))
                 (tramp-async-args (("-q")))
                 (tramp-remote-shell "/bin/sh")
                 (tramp-remote-shell-login ("-l"))
                 (tramp-remote-shell-args ("-c")))))

;; Disable VC (Git) for /ra: paths to prevent freezing
(defun ra--disable-vc-for-path (orig-fun path &rest args)
  (if (string-match-p "^/ra:" (or path ""))
      nil
    (apply orig-fun path args)))
(advice-add 'vc-registered :around #'ra--disable-vc-for-path)

;; --- Customization ----------------------------------------------------------

(defgroup remote-agent nil
  "Remote file access via Rust agent."
  :group 'files
  :prefix "ra-")

(defcustom ra-agent-path "~/.emacs.d/remote-agent"
  "Local path to compiled remote agent binary."
  :type 'string
  :group 'remote-agent)

(defcustom ra-agent-remote-path "~/.local/bin/remote-agent"
  "Remote path where agent binary is stored."
  :type 'string
  :group 'remote-agent)

(defcustom ra-agent-timeout 30
  "Timeout in seconds for agent operations."
  :type 'integer
  :group 'remote-agent)

(defcustom ra-auto-revert-interval 3
  "Polling interval (seconds) for RA file auto-revert."
  :type 'number
  :group 'remote-agent)

(defcustom ra-chunk-size (* 256 1024)
  "Chunk size for streaming large files (256KB default)."
  :type 'integer
  :group 'remote-agent)

(defcustom ra-agent-auth-token nil
  "Optional auth token for agent (set as RA_AGENT_TOKEN on remote)."
  :type 'string
  :group 'remote-agent)

;; --- Connection State -------------------------------------------------------

(cl-defstruct ra-connection
  "Represents a connection to a remote host."
  process
  host
  (request-id 0)
  (pending-requests (make-hash-table :test 'eql))
  (buffer "")
  (handshake-received nil)
  (last-activity (current-time))
  (hpc-info nil)
  (login-node nil))

(defvar ra--connections (make-hash-table :test 'equal)
  "Active connections. Key: normalized host string. Value: ra-connection struct.")

(defvar ra--deployment-cache (make-hash-table :test 'equal)
  "Cache of deployed agent versions per host.")

(defvar ra--auto-revert-timers (make-hash-table :test 'eq)
  "Timers for RA buffer auto-revert.")

;; --- Protocol Constants -----------------------------------------------------

(defconst ra--protocol-version 2
  "Current protocol version.")

(defconst ra--file-name-regexp "^/ra:\\([^@]+\\)@\\([^:]+\\):\\(.*\\)$"
  "Regexp for /ra:user@host:/path URIs.")

;; --- Core I/O Functions -----------------------------------------------------

(defun ra--get-connection (host)
  "Get or create connection to HOST (normalizing via login-node if needed)."
  (let ((normalized-host (or (ra--find-login-node host) host)))
    (let ((conn (gethash normalized-host ra--connections)))
      (cond
       ((and conn (process-live-p (ra-connection-process conn)))
        (setf (ra-connection-last-activity conn) (current-time))
        conn)
       (t
        (ra--start-connection host normalized-host))))))

(defun ra--start-connection (host normalized-host)
  "Start new connection to HOST with proper SSH invocation."
  (message "[RA] Connecting to %s (via %s)..." host normalized-host)

  ;; Removed -q and LogLevel=QUIET to fix "nc" error
  (let* ((ssh-args `("ssh"
                     "-o" "ConnectTimeout=10"
                     "-T"
                     ,normalized-host
                     "env" "SHELL=/bin/sh" "bash" "--noprofile" "--norc" "-c"
                     ,(format "exec %s" ra-agent-remote-path)))  ;; <--- GOOD: Uses the variable
         (proc (make-process
                :name (format "ra-%s" host)
                :buffer nil
                :command ssh-args
                :coding 'no-conversion
                :connection-type 'pipe
                :filter #'ra--process-filter
                :sentinel #'ra--process-sentinel))
         (conn (make-ra-connection
                :process proc
                :host host
                :pending-requests (make-hash-table :test 'eql)
                :buffer ""
                :handshake-received nil
                :login-node (unless (equal host normalized-host) normalized-host))))

    (puthash normalized-host conn ra--connections)

    ;; Handshake timeout logic handled in ra--with-connection now
    conn))

(defun ra--process-filter (proc string)
  "Handle incoming data from remote agent."
  (let* ((conn (ra--find-connection-by-proc proc)))
    (when conn
      (setf (ra-connection-buffer conn)
            (concat (ra-connection-buffer conn) string))
      (unless (ra-connection-handshake-received conn)
        (ra--process-handshake conn))
      (ra--process-messages conn))))

(defun ra--find-connection-by-proc (proc)
  (cl-loop for conn being the hash-values of ra--connections
           when (eq (ra-connection-process conn) proc)
           return conn))

(defun ra--process-handshake (conn)
  "Parse initial handshake, robustly ignoring SSH banner/debug noise."
  (let ((buf (ra-connection-buffer conn)))
    ;; Scan for the start of the JSON object (ascii 123 is '{')
    (let ((json-start (string-match-p "{" buf)))
      (when (and json-start (>= json-start 4))
        ;; Discard noise
        (when (> json-start 4)
          (setq buf (substring buf (- json-start 4)))
          (setf (ra-connection-buffer conn) buf))

        (let* ((len-bytes (substring buf 0 4))
               (len (+ (lsh (aref len-bytes 0) 24)
                       (lsh (aref len-bytes 1) 16)
                       (lsh (aref len-bytes 2) 8)
                       (aref len-bytes 3))))

          (when (>= (length buf) (+ 4 len))
            (let ((msg (substring buf 4 (+ 4 len))))
              (setf (ra-connection-buffer conn) (substring buf (+ 4 len)))
              (setf (ra-connection-handshake-received conn) t)

              (condition-case err
                  (let ((handshake (json-parse-string msg :object-type 'alist)))
                    (message "[RA] Connected to %s (agent v%s)"
                             (ra-connection-host conn)
                             (alist-get 'agent_version handshake "unknown"))

                    (when ra-agent-auth-token
                      (let ((token (alist-get 'auth_token handshake)))
                        (unless (and token (string= token ra-agent-auth-token))
                          (error "[RA] Auth token mismatch on %s" (ra-connection-host conn)))))

                    (ra--detect-hpc-environment conn handshake))
                (error
                 (message "[RA] Handshake error: %s" (error-message-string err))
                 (delete-process (ra-connection-process conn)))))))))))

(defun ra--process-messages (conn)
  "Process length-prefixed RPC messages."
  (let ((buf (ra-connection-buffer conn)))
    (while (>= (length buf) 4)
      (let* ((len-bytes (substring buf 0 4))
             (len (+ (lsh (aref len-bytes 0) 24)
                     (lsh (aref len-bytes 1) 16)
                     (lsh (aref len-bytes 2) 8)
                     (aref len-bytes 3))))

        (if (< (length buf) (+ 4 len))
            (return) ; Wait for more data
          (let ((msg (substring buf 4 (+ 4 len))))
            (setf (ra-connection-buffer conn) (substring buf (+ 4 len)))
            (condition-case err
                (ra--dispatch-response conn (json-parse-string msg :object-type 'alist))
              (error (message "[RA] JSON error: %s" (error-message-string err))))
            (setq buf (ra-connection-buffer conn))))))))

(defun ra--dispatch-response (conn response)
  (let ((id (alist-get 'id response))
        (req (gethash id (ra-connection-pending-requests conn))))
    (when req
      (remhash id (ra-connection-pending-requests conn))
      (let ((callback (plist-get req :callback))
            (error-cb (plist-get req :error-callback)))
        (if-let ((err (alist-get 'error response)))
            (funcall error-cb (format "Remote error: %s" (alist-get 'message err "")))
          (funcall callback (alist-get 'result response)))))))

(defun ra--send-request (conn method params &optional callback error-callback)
  "Send async RPC request. Returns request ID."
  (let* ((req-id (cl-incf (ra-connection-request-id conn)))
         (req-json (json-encode `((id . ,req-id) (method . ,method) (params . ,params))))
         (utf8-req (encode-coding-string req-json 'utf-8))
         (len (length utf8-req))
         (header (unibyte-string (lsh len -24)
                                 (lsh (logand len #xff0000) -16)
                                 (lsh (logand len #xff00) -8)
                                 (logand len #xff))))

    (puthash req-id
             (list :callback callback
                   :error-callback (or error-callback
                                       (lambda (err) (message "[RA] Error: %s" err))))
             (ra-connection-pending-requests conn))

    (process-send-string (ra-connection-process conn) header)
    (process-send-string (ra-connection-process conn) utf8-req)
    req-id))

;; --- HPC Environment Detection ---------------------------------------------

(defun ra--detect-hpc-environment (conn handshake)
  (let ((normalized-host (or (ra-connection-login-node conn) (ra-connection-host conn))))
    (if-let ((cached (gethash normalized-host ra--deployment-cache)))
        (setf (ra-connection-hpc-info conn) (plist-get cached :hpc-info))
      (ra--send-request
       conn "hpc_info" nil
       (lambda (info)
         (setf (ra-connection-hpc-info conn) info)
         (puthash normalized-host
                  (list :hpc-info info
                        :agent-sha256 (alist-get 'agent_sha256 handshake ""))
                  ra--deployment-cache))
       (lambda (err) (message "[RA] HPC detection failed: %s" err))))))

;; --- File Handler -----------------------------------------------------------

(defun ra-file-handler (operation &rest args)
  (let ((inhibit-file-name-handlers
         (cons 'ra-file-handler
               (and (eq inhibit-file-name-operation operation) inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))

    (pcase operation
      ('file-exists-p
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--stat-exists conn (nth 2 parsed))))))

      ('file-readable-p
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--stat-exists conn (nth 2 parsed))))))

      ('file-writable-p
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (condition-case nil
                 (let ((stat (ra--sync-request conn "stat" `((path . ,(nth 2 parsed))))))
                   (and (not (string= (alist-get 'type stat) "directory")) t))
               (error nil))))))

      ('file-directory-p
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (condition-case nil
                 (string= (alist-get 'type (ra--sync-request conn "stat" `((path . ,(nth 2 parsed)))))
                          "directory")
               (error nil))))))

      ('file-symlink-p
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (condition-case nil
                 (let* ((stat (ra--sync-request conn "stat" `((path . ,(nth 2 parsed)))))
                        (type (alist-get 'type stat)))
                   (or (string= type "symlink") (alist-get 'symlink_target stat)))
               (error nil))))))

      ('file-attributes
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (condition-case nil
                 (ra--convert-stat (ra--sync-request conn "stat" `((path . ,(nth 2 parsed)))))
               (error nil))))))

      ('directory-files
       (let* ((parsed (ra--parse-uri (car args)))
              (full (nth 1 args)) (match (nth 2 args)))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (let ((entries (ra--sync-request conn "list_dir" `((path . ,(nth 2 parsed))))))
               (mapcar (lambda (e)
                         (if full (format "/ra:%s@%s:%s/%s" (nth 0 parsed) (nth 1 parsed) (nth 2 parsed) (alist-get 'name e))
                           (alist-get 'name e)))
                       (if match (seq-filter (lambda (e) (string-match match (alist-get 'name e))) entries) entries)))))))

      ('make-directory
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (ra--sync-request conn "mkdir" `((path . ,(nth 2 parsed)) (recursive . ,t)))))))

      ('delete-directory
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--sync-request conn "delete" `((path . ,(nth 2 parsed))))))))

      ('delete-file
       (let ((parsed (ra--parse-uri (car args))))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--sync-request conn "delete" `((path . ,(nth 2 parsed))))))))

      ('rename-file
       (let* ((parsed-src (ra--parse-uri (car args)))
              (parsed-dst (ra--parse-uri (nth 1 args))))
         (unless (string= (nth 1 parsed-src) (nth 1 parsed-dst)) (error "Cannot rename across hosts"))
         (ra--with-connection (nth 1 parsed-src)
           (lambda (conn)
             (ra--sync-request conn "rename" `((path . ,(nth 2 parsed-src)) (new_path . ,(nth 2 parsed-dst))))))))

      ('insert-file-contents
       (let* ((filename (car args))
              (parsed (ra--parse-uri filename))
              (replace (nth 4 args)))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--stream-file conn (nth 2 parsed) filename replace)))))

      ('write-region
       (let* ((start (car args)) (end (nth 1 args)) (filename (nth 2 args))
              (append (nth 3 args)) (visited (nth 4 args))
              (parsed (ra--parse-uri filename)))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn) (ra--stream-write conn start end (nth 2 parsed) append visited filename)))))

      ('file-name-all-completions
       (let* ((parsed (ra--parse-uri (car args)))
              (dir (nth 2 parsed)))
         (ra--with-connection (nth 1 parsed)
           (lambda (conn)
             (let ((entries (ra--sync-request conn "list_dir" `((path . ,dir)))))
               (mapcar (lambda (e) (alist-get 'name e)) entries))))))

      ('expand-file-name
       (let* ((name (car args))
              (default (nth 1 args)))
         (if (string-match-p "^/ra:" name)
             (replace-regexp-in-string ":~" ":/home/user" name)
           (apply operation args))))

      ;; Explicitly ignore VC/Git operations to prevent freezing
      ('vc-registered nil)

      (_ (apply operation args)))))

;; --- Helpers & Patches ------------------------------------------------------

(defun ra--sync-request (conn method params)
  "Blocking request wrapper."
  (let ((result nil) (error nil) (done nil))
    (ra--send-request conn method params
                      (lambda (res) (setq result res done t))
                      (lambda (err) (setq error err done t)))
    (let ((c 0))
      (while (and (not done) (< c (* ra-agent-timeout 10)))
        ;; 🛠️ FIX 4: CHECK IF PROCESS DIED! Prevents infinite freeze.
        (unless (process-live-p (ra-connection-process conn))
          (signal 'file-error (list "Connection died" (ra-connection-host conn))))
        (accept-process-output (ra-connection-process conn) 0.1)
        (setq c (1+ c))))
    (cond (error (signal 'file-error (list "Remote error" error)))
          ((not done) (signal 'file-error (list "Timeout" method)))
          (t result))))

(defun ra--stat-exists (conn path)
  (condition-case nil (and (ra--sync-request conn "stat" `((path . ,path))) t) (error nil)))

(defun ra--parse-uri (filename)
  (if (string-match ra--file-name-regexp filename)
      (let ((path (match-string 3 filename)))
        (when (string-match-p "\\.\\." path) (error "Path traversal detected"))
        (list (match-string 1 filename) (match-string 2 filename) path))
    (error "Invalid remote path: %s" filename)))

(defun ra--find-login-node (host)
  "Use 'ssh -G' to resolve ProxyJump/ProxyCommand reliably."
  (with-temp-buffer
    (call-process "ssh" nil t nil "-G" host)
    (goto-char (point-min))
    (let ((proxy-jump nil) (proxy-cmd nil))
      (when (re-search-forward "^proxyjump \\(.*\\)" nil t) (setq proxy-jump (match-string 1)))
      (goto-char (point-min))
      (when (re-search-forward "^proxycommand \\(.*\\)" nil t) (setq proxy-cmd (match-string 1)))
      (cond
       ((and proxy-jump (not (string= proxy-jump "none"))) proxy-jump)
       ((and proxy-cmd (string-match "ssh .* \\([^ ]+\\)$" proxy-cmd)) (match-string 1 proxy-cmd))
       (t nil)))))

(defun ra--convert-stat (stat)
  "Convert agent stat to Emacs file-attributes format."
  (list (alist-get 'mode stat)
        nil nil nil
        (alist-get 'size stat)
        (seconds-to-time (alist-get 'atime stat))
        (seconds-to-time (alist-get 'mtime stat))
        (seconds-to-time (alist-get 'ctime stat))
        nil
        (alist-get 'symlink_target stat)))

;; --- Streaming & Progress ---------------------------------------------------

(defun ra--stream-file (conn remote-path local-filename replace)
  "Stream remote file with progress."
  (let* ((stat (ra--sync-request conn "stat" `((path . ,remote-path))))
         (size (alist-get 'size stat))
         (chunk-size ra-chunk-size)
         (buffer (current-buffer))
         (inhibit-read-only t))
    (when replace (erase-buffer))
    (if (> size (* 10 1024 1024))
        (unless (y-or-n-p (format "File is %.1f MB. Download?" (/ size 1048576.0)))
          (signal 'quit nil)))
    (let ((pr (make-progress-reporter "Downloading" 0 size)))
      (cl-loop for offset from 0 below size by chunk-size do
               (let* ((chunk (ra--sync-request conn "read_chunk" `((path . ,remote-path) (offset . ,offset) (length . ,chunk-size))))
                      (data (base64-decode-string (alist-get 'data chunk))))
                 (with-current-buffer buffer (goto-char (point-max)) (insert data))
                 (progress-reporter-update pr (+ offset (length data)))))
      (progress-reporter-done pr)
      (list local-filename size))))

(defun ra--stream-write (conn start end remote-path append visited local-filename)
  "Stream buffer region to remote file."
  (let* ((data (if (and start end) (buffer-substring-no-properties start end) (buffer-string)))
         (size (length data))
         (chunk-size ra-chunk-size))
    (let ((pr (make-progress-reporter "Uploading" 0 size)))
      (cl-loop for offset from 0 below size by chunk-size do
               (let* ((chunk (substring data offset (min (+ offset chunk-size) size)))
                      (b64 (base64-encode-string chunk))
                      (final (>= (+ offset chunk-size) size)))
                 (ra--sync-request conn "write_chunk"
                                   `((path . ,remote-path) (offset . ,offset) (data . ,b64) (final . ,final)))
                 (progress-reporter-update pr offset)))
      (progress-reporter-done pr))
    (when visited
      (let ((stat (ra--sync-request conn "stat" `((path . ,remote-path)))))
        (set-visited-file-modtime (seconds-to-time (alist-get 'mtime stat)))))
    size))

;; --- Auto-revert Helpers ----------------------------------------------------

(defun ra--auto-revert-start (buffer)
  "Start auto-revert timer for BUFFER if RA buffer and auto-revert-mode is on."
  (when (and buffer
             (with-current-buffer buffer
               (and auto-revert-mode
                    (buffer-file-name)
                    (string-match-p ra--file-name-regexp (buffer-file-name))))
             (not (get-buffer-process buffer)))
    (let ((timer (run-with-timer ra-auto-revert-interval ra-auto-revert-interval
                                 (lambda (buf)
                                   (with-current-buffer buf
                                     (when (and auto-revert-mode
                                                (buffer-file-name)
                                                (string-match-p ra--file-name-regexp (buffer-file-name)))
                                       (condition-case nil
                                           (let* ((uri (buffer-file-name))
                                                  (parsed (ra--parse-uri uri))
                                                  (host (nth 1 parsed))
                                                  (conn (ra--get-connection host))
                                                  (stat (ra--sync-request conn "stat" `((path . ,(nth 2 parsed)))))
                                                  (new-mtime (seconds-to-time (alist-get 'mtime stat))))
                                             (unless (equal new-mtime (buffer-modified-timestamp))
                                               (auto-revert-handler t)))
                                         (error nil)))) buffer)))
      (set-buffer-modified-timestamp nil)
      (puthash buffer timer ra--auto-revert-timers))))

(advice-add 'ra-file-handler :after
            (lambda (orig-fun operation &rest args)
              (when (eq operation 'insert-file-contents)
                (let ((buf (current-buffer)))
                  (ra--auto-revert-start buf)))))

(add-hook 'kill-buffer-hook
          (lambda ()
            (let ((fname (buffer-file-name)))
              (when (and fname (string-match-p ra--file-name-regexp fname))
                (let ((timer (gethash (current-buffer) ra--auto-revert-timers)))
                  (when timer (cancel-timer timer))
                  (remhash (current-buffer) ra--auto-revert-timers))))))

;; --- Activation -------------------------------------------------------------

;; Ensure our handler takes precedence over Tramp
(defun ra--register-handler ()
  (add-to-list 'file-name-handler-alist `(,ra--file-name-regexp . ra-file-handler))
  (let ((entry (assoc ra--file-name-regexp file-name-handler-alist)))
    (setq file-name-handler-alist (cons entry (delq entry file-name-handler-alist)))))

(ra--register-handler)
(with-eval-after-load 'tramp
  (ra--register-handler))

(provide 'remote-agent)
)

;;; remote-agent.el ends here
