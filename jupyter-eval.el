;;; jupyter-eval.el --- Coordinate the Jupyter Eval components -*- lexical-binding: t; -*-

;; Author: Leslie Huang
;; Version: 0.3.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: jupyter, tools

;;; Commentary:
;;
;; Coordinates buffer-associated Jupyter sessions.  Kernels and brokers are
;; session-local while a single renderer serves discovery and session pages.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)

(defgroup jupyter-eval nil
  "Coordinate the Jupyter Eval kernel bridge."
  :group 'tools)

(defconst jupyter-eval--directory
  (file-name-directory
   (or (and (boundp 'byte-compile-current-file)
            byte-compile-current-file
            (string-match-p "/jupyter-eval\\.elc?$" byte-compile-current-file)
            byte-compile-current-file)
       (and load-file-name
            (string-match-p "/jupyter-eval\\.elc?$" load-file-name)
            load-file-name)
       buffer-file-name)))
(defconst jupyter-eval--root-directory
  (file-name-as-directory (directory-file-name jupyter-eval--directory)))
(defconst jupyter-eval--broker-directory
  (expand-file-name "broker" jupyter-eval--root-directory))
(defconst jupyter-eval--broker-main
  (expand-file-name "main.py" jupyter-eval--broker-directory))
(defconst jupyter-eval--engine-directory
  (expand-file-name "engines/python" jupyter-eval--root-directory))
(defconst jupyter-eval--engine-launcher
  (expand-file-name "launch.py" jupyter-eval--engine-directory))
(defconst jupyter-eval--renderer-directory
  (expand-file-name "renderer" jupyter-eval--root-directory))
(defconst jupyter-eval--runtime-directory "/tmp/jupyter-eval/")
(defconst jupyter-eval--registry-file
  (expand-file-name "sessions.json" jupyter-eval--runtime-directory))
(defconst jupyter-eval--buffer "*jupyter-eval*")

(defcustom jupyter-eval-vite-port 5173
  "Port used by the manager-owned Vite development server."
  :type 'integer
  :group 'jupyter-eval)

(cl-defstruct (jupyter-eval--session
               (:constructor jupyter-eval--make-session))
  id generation capability source-path label kernel-id launcher
  input-processor output-processor connection-file kernel-pid-file
  event-port startup-timer frontend-timer stopping)

(defvar jupyter-eval--sessions (make-hash-table :test #'equal))
(defvar jupyter-eval--vite nil)

(defun jupyter-eval--uv-command (directory script &rest arguments)
  "Return a command list running SCRIPT with uv in DIRECTORY."
  (append (list "uv" "run" "--project" directory "python" script)
          arguments))

(defun jupyter-eval--kernel-ids ()
  "Return the installed Jupyter kernel IDs."
  (let ((stderr-file (make-temp-file "jupyter-eval-kernelspec")))
    (unwind-protect
        (with-temp-buffer
          (let ((status (call-process "jupyter" nil (list t stderr-file) nil
                                      "kernelspec" "list" "--json")))
            (unless (zerop status)
              (error "Could not list Jupyter kernels: %s"
                     (string-trim
                      (with-temp-buffer
                        (insert-file-contents stderr-file)
                        (buffer-string)))))
            (goto-char (point-min))
            (mapcar #'symbol-name
                    (mapcar #'car
                            (alist-get 'kernelspecs
                                       (json-parse-buffer :object-type 'alist))))))
      (delete-file stderr-file))))

(defun jupyter-eval--renderer-deps-p ()
  "Return non-nil when the renderer dependencies are installed."
  (file-directory-p
   (expand-file-name "node_modules" jupyter-eval--renderer-directory)))

(defun jupyter-eval--ensure-renderer-deps ()
  "Install renderer dependencies when missing, prompting first."
  (unless (jupyter-eval--renderer-deps-p)
    (if noninteractive
        (message
         "Jupyter Eval: renderer dependencies missing; run: mise --cd %s exec -- npm ci"
         jupyter-eval--renderer-directory)
      (when (y-or-n-p
             (format
              "Jupyter Eval: renderer dependencies are missing in %s. Install them now? "
              jupyter-eval--renderer-directory))
        (message "Jupyter Eval: installing renderer dependencies...")
        (let ((default-directory jupyter-eval--renderer-directory))
          (unless (zerop (call-process "mise" nil (get-buffer-create jupyter-eval--buffer)
                                       nil "exec" "--" "npm" "ci"))
            (user-error "Renderer dependency install failed; see buffer %s"
                        jupyter-eval--buffer)))
        (unless (jupyter-eval--renderer-deps-p)
          (user-error "Renderer install did not produce node_modules in %s"
                      jupyter-eval--renderer-directory))))))

(defun jupyter-eval--available-port ()
  "Return an available IPv4 loopback port."
  (let ((probe (make-network-process
                :name "jupyter-eval-port-probe"
                :host "127.0.0.1"
                :service 0
                :server t
                :family 'ipv4
                :noquery t)))
    (unwind-protect
        (process-contact probe :service)
      (delete-process probe))))

(defun jupyter-eval--random-token ()
  "Return a cryptographically random hexadecimal token."
  (with-temp-buffer
    (unless (zerop (call-process "openssl" nil t nil "rand" "-hex" "32"))
      (error "Could not generate a Jupyter Eval capability"))
    (string-trim (buffer-string))))

(defun jupyter-eval--source-path ()
  "Return the canonical path identifying the current source buffer."
  (unless buffer-file-name
    (user-error "The current buffer must visit a file"))
  (file-truename buffer-file-name))

(defun jupyter-eval--current-session ()
  "Return the session associated with the current source buffer."
  (and buffer-file-name
       (gethash (file-truename buffer-file-name) jupyter-eval--sessions)))

(defun jupyter-eval--session-current-p (session)
  "Return non-nil when SESSION is still the registered generation."
  (eq session
      (gethash (jupyter-eval--session-source-path session)
               jupyter-eval--sessions)))

(defun jupyter-eval--session-live-p (session)
  "Return non-nil when SESSION has live input and output processors."
  (and session
       (process-live-p (jupyter-eval--session-input-processor session))
       (process-live-p (jupyter-eval--session-output-processor session))))

(defun jupyter-eval--public-session (session)
  "Return the public discovery representation of SESSION."
  `((id . ,(jupyter-eval--session-id session))
    (generation . ,(jupyter-eval--session-generation session))
    (label . ,(jupyter-eval--session-label session))
    (kernelName . ,(jupyter-eval--session-kernel-id session))
    (eventUrl . ,(format "http://127.0.0.1:%d/jupyter-eval-events"
                         (jupyter-eval--session-event-port session)))))

(defun jupyter-eval--write-registry ()
  "Atomically write public discovery metadata for managed sessions."
  (make-directory jupyter-eval--runtime-directory t)
  (let ((temporary (make-temp-file
                    (expand-file-name ".sessions-" jupyter-eval--runtime-directory))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert
             (json-serialize
              `((sessions
                 . ,(vconcat
                     (let (sessions)
                       (maphash
                        (lambda (_source session)
                          (when (jupyter-eval--session-event-port session)
                            (push (jupyter-eval--public-session session) sessions)))
                        jupyter-eval--sessions)
                       (nreverse sessions))))))))
          (rename-file temporary jupyter-eval--registry-file t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun jupyter-eval--start-process (name command)
  "Start NAME with the given COMMAND list."
  (make-process
   :name name
   :buffer (get-buffer-create jupyter-eval--buffer)
   :command command
   :connection-type 'pipe
   :noquery t))

(defun jupyter-eval--renderer-sentinel (process event)
  "Record termination EVENT for renderer PROCESS."
  (when (memq (process-status process) '(exit signal))
    (when (eq process jupyter-eval--vite)
      (setq jupyter-eval--vite nil))
    (unless (process-get process 'jupyter-eval-stopping)
      (message "Jupyter Eval: renderer stopped: %s" (string-trim event)))))

(defun jupyter-eval--ensure-renderer ()
  "Ensure the shared renderer process is running."
  (unless (process-live-p jupyter-eval--vite)
    (setq jupyter-eval--vite
          (make-process
           :name "jupyter-eval-renderer"
           :buffer (get-buffer-create jupyter-eval--buffer)
           :command
           (list "mise" "--cd" jupyter-eval--renderer-directory
                 "exec" "--" "npm" "run" "dev" "--"
                 "--host" "127.0.0.1"
                 "--port" (number-to-string jupyter-eval-vite-port)
                 "--strictPort")
           :connection-type 'pipe
           :noquery t))
    (set-process-sentinel jupyter-eval--vite #'jupyter-eval--renderer-sentinel)))

(defun jupyter-eval--session-url (session interactive)
  "Return SESSION URL, including capability when INTERACTIVE is non-nil."
  (concat
   (format "http://127.0.0.1:%d/sessions/%s"
           jupyter-eval-vite-port (jupyter-eval--session-id session))
   (if interactive
       (format "#capability=%s" (jupyter-eval--session-capability session))
     "")))

(defun jupyter-eval--open-frontend (session attempt)
  "Open SESSION frontend after it becomes reachable, up to ATTEMPT 20."
  (setf (jupyter-eval--session-frontend-timer session) nil)
  (when (jupyter-eval--session-current-p session)
    (let ((probe-url (format "http://127.0.0.1:%d/" jupyter-eval-vite-port)))
      (condition-case nil
          (let ((buffer (url-retrieve-synchronously probe-url t t 1)))
            (when buffer
              (kill-buffer buffer)
              (if (fboundp 'xwidget-webkit-browse-url)
                  (xwidget-webkit-browse-url
                   (jupyter-eval--session-url session t))
                (browse-url (jupyter-eval--session-url session nil)))
              (setq attempt 20)))
        (error nil))
      (when (< attempt 20)
        (setf (jupyter-eval--session-frontend-timer session)
              (run-at-time 0.25 nil #'jupyter-eval--open-frontend
                           session (1+ attempt))))
      (when (and (= attempt 20)
                 (not (jupyter-eval--session-frontend-timer session)))
        (message "Jupyter Eval: renderer ready for %s"
                 (jupyter-eval--session-label session))))))

(defun jupyter-eval--input-processor-filter (process output)
  "Report input PROCESS results from OUTPUT."
  (let ((session (process-get process 'jupyter-eval-session)))
    (dolist (line (split-string output "\n" t))
      (condition-case nil
          (let ((result (json-parse-string line :object-type 'alist)))
            (if-let* ((error-message (alist-get 'error result)))
                (message "Jupyter Eval [%s]: execution failed: %s"
                         (jupyter-eval--session-label session) error-message)
              (message "Jupyter Eval [%s]: execution submitted; request=%s"
                       (jupyter-eval--session-label session)
                       (alist-get 'requestId result))))
        (json-parse-error
         (message "Jupyter Eval input processor: %s" line))))))

(defun jupyter-eval--delete-connection-file (connection-file)
  "Delete CONNECTION-FILE after its kernel has completed shutdown."
  (when (and connection-file (file-exists-p connection-file))
    (delete-file connection-file)))

(defun jupyter-eval--stop-session (session &optional reason)
  "Stop SESSION without affecting other sessions and report REASON."
  (when (and session (not (jupyter-eval--session-stopping session)))
    (setf (jupyter-eval--session-stopping session) t)
    (dolist (timer (list (jupyter-eval--session-startup-timer session)
                         (jupyter-eval--session-frontend-timer session)))
      (when (timerp timer)
        (cancel-timer timer)))
    (dolist (process (list (jupyter-eval--session-launcher session)
                           (jupyter-eval--session-input-processor session)
                           (jupyter-eval--session-output-processor session)))
      (when (process-live-p process)
        (process-put process 'jupyter-eval-stopping t)
        (delete-process process)))
    (let ((pid-file (jupyter-eval--session-kernel-pid-file session)))
      (when (and pid-file (file-readable-p pid-file))
        (let ((pid (string-to-number
                    (string-trim
                     (with-temp-buffer
                       (insert-file-contents pid-file)
                       (buffer-string))))))
          (when (process-attributes pid)
            (signal-process pid 'SIGTERM)))
        (delete-file pid-file)))
    (let ((connection-file (jupyter-eval--session-connection-file session)))
      (when connection-file
        (jupyter-eval--delete-connection-file connection-file)
        (run-at-time 1 nil #'jupyter-eval--delete-connection-file
                     connection-file)))
    (when (jupyter-eval--session-current-p session)
      (remhash (jupyter-eval--session-source-path session)
               jupyter-eval--sessions))
    (jupyter-eval--write-registry)
    (message "Jupyter Eval [%s] stopped%s"
             (jupyter-eval--session-label session)
             (if reason (format ": %s" reason) ""))))

(defun jupyter-eval--service-sentinel (process event)
  "Stop only the session owning unexpectedly terminated PROCESS."
  (when (and (memq (process-status process) '(exit signal))
             (not (process-get process 'jupyter-eval-stopping)))
    (let ((session (process-get process 'jupyter-eval-session)))
      (when (and session (jupyter-eval--session-current-p session))
        (jupyter-eval--stop-session
         session
         (format "%s stopped: %s" (process-name process) (string-trim event)))))))

(defun jupyter-eval--launcher-filter (process output)
  "Accumulate launcher PROCESS OUTPUT and update its session."
  (let ((accumulated (concat (or (process-get process 'jupyter-eval-output) "")
                             output))
        (session (process-get process 'jupyter-eval-session)))
    (process-put process 'jupyter-eval-output
                 (substring accumulated (max 0 (- (length accumulated) 4096))))
    (dolist (line (split-string accumulated "\n"))
      (unless (string-empty-p line)
        (condition-case nil
            (let ((result (json-parse-string line :object-type 'alist)))
              (setf (jupyter-eval--session-connection-file session)
                    (alist-get 'connectionFile result)
                    (jupyter-eval--session-kernel-pid-file session)
                    (alist-get 'pidFile result)))
          (json-parse-error nil))))))

(defun jupyter-eval--start-services (session)
  "Start the input and output brokers for SESSION."
  (let* ((event-port (jupyter-eval--available-port))
         (suffix (substring (jupyter-eval--session-id session) 0 8))
         (connection-file (jupyter-eval--session-connection-file session))
         (input
          (jupyter-eval--start-process
           (format "jupyter-eval-input-%s" suffix)
           (jupyter-eval--uv-command
            jupyter-eval--broker-directory jupyter-eval--broker-main
            "input" "--connection-file" connection-file)))
         (output
          (jupyter-eval--start-process
           (format "jupyter-eval-output-%s" suffix)
           (jupyter-eval--uv-command
            jupyter-eval--broker-directory jupyter-eval--broker-main
            "output" "--connection-file" connection-file
            "--event-port" (number-to-string event-port)
            "--allowed-origin"
            (format "http://127.0.0.1:%d" jupyter-eval-vite-port)
            "--session-id" (jupyter-eval--session-id session)
            "--generation" (jupyter-eval--session-generation session)
            "--interactive-capability"
            (jupyter-eval--session-capability session)))))
    (setf (jupyter-eval--session-event-port session) event-port
          (jupyter-eval--session-input-processor session) input
          (jupyter-eval--session-output-processor session) output)
    (dolist (process (list input output))
      (process-put process 'jupyter-eval-session session)
      (set-process-sentinel process #'jupyter-eval--service-sentinel))
    (set-process-filter input #'jupyter-eval--input-processor-filter)
    (jupyter-eval--write-registry)
    (setf (jupyter-eval--session-frontend-timer session)
          (run-at-time 0 nil #'jupyter-eval--open-frontend session 0))
    (message "Jupyter Eval [%s]: event bridge=127.0.0.1:%d"
             (jupyter-eval--session-label session) event-port)))

(defun jupyter-eval--connection-ready-p (connection-file)
  "Return non-nil when CONNECTION-FILE contains valid kernel connection JSON."
  (and connection-file
       (file-readable-p connection-file)
       (condition-case nil
           (with-temp-buffer
             (insert-file-contents connection-file)
             (let ((connection (json-parse-buffer :object-type 'alist)))
               (and (alist-get 'shell_port connection)
                    (alist-get 'iopub_port connection)
                    (alist-get 'key connection))))
         (json-parse-error nil))))

(defun jupyter-eval--start-after-connection (session attempts)
  "Start SESSION services when its connection file is ready."
  (when (jupyter-eval--session-current-p session)
    (let ((connection-file (jupyter-eval--session-connection-file session)))
      (if (jupyter-eval--connection-ready-p connection-file)
          (progn
            (setf (jupyter-eval--session-startup-timer session) nil)
            (jupyter-eval--start-services session))
        (if (>= attempts 50)
            (jupyter-eval--stop-session
             session "kernel never produced a valid connection file")
          (setf (jupyter-eval--session-startup-timer session)
                (run-at-time 0.2 nil #'jupyter-eval--start-after-connection
                             session (1+ attempts))))))))

(defun jupyter-eval--kernel-sentinel (process event)
  "Continue startup after launcher PROCESS exits, or report EVENT."
  (let ((session (process-get process 'jupyter-eval-session)))
    (setf (jupyter-eval--session-launcher session) nil)
    (when (jupyter-eval--session-current-p session)
      (if (and (eq (process-status process) 'exit)
               (zerop (process-exit-status process))
               (jupyter-eval--session-connection-file session)
               (jupyter-eval--session-kernel-pid-file session))
          (setf (jupyter-eval--session-startup-timer session)
                (run-at-time 1 nil #'jupyter-eval--start-after-connection
                             session 0))
        (jupyter-eval--stop-session
         session (format "kernel launch failed: %s" (string-trim event)))))))

(defun jupyter-eval--validate-environment ()
  "Validate the external tools and package files needed at runtime."
  (unless (file-readable-p jupyter-eval--engine-launcher)
    (user-error "Cannot read %s" jupyter-eval--engine-launcher))
  (unless (file-readable-p jupyter-eval--broker-main)
    (user-error "Cannot read %s" jupyter-eval--broker-main))
  (dolist (tool '("uv" "jupyter" "mise" "openssl"))
    (unless (executable-find tool)
      (user-error "Cannot find required executable: %s" tool)))
  (jupyter-eval--ensure-renderer-deps))

;;;###autoload
(defun jupyter-eval-start (&optional kernel-id)
  "Start KERNEL-ID for the current buffer, or reopen its live session."
  (interactive
   (let ((session (jupyter-eval--current-session)))
     (if (jupyter-eval--session-live-p session)
         (list nil)
       (let ((kernel-ids (jupyter-eval--kernel-ids)))
         (unless kernel-ids
           (user-error
            "No Jupyter kernels registered; run the engine register command"))
         (list (completing-read "Jupyter kernel: " kernel-ids nil t))))))
  (let* ((source-path (jupyter-eval--source-path))
         (existing (gethash source-path jupyter-eval--sessions)))
    (if (jupyter-eval--session-live-p existing)
        (progn
          (jupyter-eval--ensure-renderer)
          (jupyter-eval--open-frontend existing 0))
      (when existing
        (jupyter-eval--stop-session existing "replacing stale generation"))
      (unless (and (stringp kernel-id) (not (string-empty-p kernel-id)))
        (user-error "A kernel ID is required for a new session"))
      (jupyter-eval--validate-environment)
      (jupyter-eval--ensure-renderer)
      (let* ((id (substring (jupyter-eval--random-token) 0 32))
             (session
              (jupyter-eval--make-session
               :id id
               :generation (jupyter-eval--random-token)
               :capability (jupyter-eval--random-token)
               :source-path source-path
               :label (format "%s - %s"
                              kernel-id (file-name-nondirectory source-path))
               :kernel-id kernel-id)))
        (puthash source-path session jupyter-eval--sessions)
        (let ((process
               (jupyter-eval--start-process
                (format "jupyter-eval-launcher-%s" (substring id 0 8))
                (jupyter-eval--uv-command
                 jupyter-eval--engine-directory jupyter-eval--engine-launcher
                 "launch" "--kernel-id" kernel-id "--buffer-path" source-path
                 "--session-id" id))))
          (setf (jupyter-eval--session-launcher session) process)
          (process-put process 'jupyter-eval-session session)
          (set-process-filter process #'jupyter-eval--launcher-filter)
          (set-process-sentinel process #'jupyter-eval--kernel-sentinel))))))

;;;###autoload
(defun jupyter-eval-send-region (beg end)
  "Send the region from BEG to END through this buffer's session."
  (interactive "r")
  (let ((session (jupyter-eval--current-session)))
    (unless (jupyter-eval--session-live-p session)
      (user-error "Start a kernel for this buffer with jupyter-eval-start first"))
    (process-send-string
     (jupyter-eval--session-input-processor session)
     (concat
      (json-serialize
       `((code . ,(buffer-substring-no-properties beg end))))
      "\n"))))

;;;###autoload
(defun jupyter-eval-stop ()
  "Stop the current buffer's Jupyter Eval session."
  (interactive)
  (if-let* ((session (jupyter-eval--current-session)))
      (jupyter-eval--stop-session session)
    (message "Jupyter Eval: current buffer has no managed session")))

;;;###autoload
(defun jupyter-eval-stop-all ()
  "Stop every managed Jupyter Eval session."
  (interactive)
  (let (sessions)
    (maphash (lambda (_source session) (push session sessions))
             jupyter-eval--sessions)
    (dolist (session sessions)
      (jupyter-eval--stop-session session)))
  (message "Jupyter Eval: all sessions stopped"))

(define-obsolete-function-alias 'run-jupyter-eval #'jupyter-eval-start "0.2.0")

(let ((load-path (cons (expand-file-name "adapters/emacs" jupyter-eval--directory)
                       load-path)))
  (require 'code-cells-adapt))

(provide 'jupyter-eval)

;;; jupyter-eval.el ends here
