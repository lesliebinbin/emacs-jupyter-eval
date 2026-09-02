;;; ipykernel-manager.el --- Coordinate Jupyter Eval processes -*- lexical-binding: t; -*-

(require 'json)
(require 'subr-x)
(require 'url)

(defgroup ipykernel-manager nil
  "Coordinate the Jupyter Eval kernel bridge."
  :group 'tools)

(defconst ipykernel-manager--directory
  (file-name-directory (or load-file-name (locate-library "ipykernel-manager"))))
(defconst ipykernel-manager--root-directory
  (file-name-as-directory
   (expand-file-name "../.." ipykernel-manager--directory)))
(defconst ipykernel-manager--broker-directory
  (expand-file-name "broker" ipykernel-manager--root-directory))
(defconst ipykernel-manager--handler
  (expand-file-name "broker/jupyter_eval_broker.py"
                    ipykernel-manager--root-directory))
(defconst ipykernel-manager--renderer-directory
  (expand-file-name "renderer" ipykernel-manager--root-directory))
(defconst ipykernel-manager--buffer "*ipykernel-manager*")
(defcustom ipykernel-manager-vite-port 5173
  "Port used by the manager-owned Vite development server."
  :type 'integer
  :group 'ipykernel-manager)
(defvar ipykernel-manager--publisher nil)
(defvar ipykernel-manager--subscriber nil)
(defvar ipykernel-manager--vite nil)
(defvar ipykernel-manager--connection-file nil)
(defvar ipykernel-manager--kernel-pid-file nil)
(defvar ipykernel-manager--event-port nil)
(defvar ipykernel-manager--startup-timer nil)
(defvar ipykernel-manager--frontend-timer nil)

(defun ipykernel-manager--kernel-ids ()
  "Return the installed Jupyter kernel IDs."
  (with-temp-buffer
    (unless
        (zerop
         (call-process
          "mise" nil t nil "--cd" ipykernel-manager--broker-directory
          "exec" "--" "python" ipykernel-manager--handler "list-kernels"))
      (error "Could not list Jupyter kernels: %s" (string-trim (buffer-string))))
    (goto-char (point-min))
    (json-parse-buffer :array-type 'list)))

(defun ipykernel-manager--available-port ()
  "Return an available IPv4 loopback port."
  (let ((probe (make-network-process
                :name "ipykernel-manager-port-probe"
                :host "127.0.0.1"
                :service 0
                :server t
                :family 'ipv4
                :noquery t)))
    (unwind-protect
        (process-contact probe :service)
      (delete-process probe))))

(defun ipykernel-manager--connection-file (kernel-id buffer-path)
  "Return KERNEL-ID's deterministic connection file for BUFFER-PATH."
  (let ((kernel-hash (substring (secure-hash 'sha256 kernel-id) 0 16))
        (buffer-hash
         (substring (secure-hash 'sha256 (file-truename buffer-path)) 0 16)))
    (expand-file-name
     (format "%s_%s_kernel.json" kernel-hash buffer-hash)
     (getenv "HOME"))))

(defun ipykernel-manager--kernel-pid-file (connection-file)
  "Return the launcher PID file corresponding to CONNECTION-FILE."
  (concat (file-name-sans-extension connection-file) ".pid"))

(defun ipykernel-manager--delete-connection-file (connection-file)
  "Delete CONNECTION-FILE after its kernel has completed shutdown."
  (when (file-exists-p connection-file)
    (delete-file connection-file)))

(defun ipykernel-manager--start-process (name arguments)
  "Start NAME with HANDLER ARGUMENTS."
  (make-process
   :name name
   :buffer (get-buffer-create ipykernel-manager--buffer)
   :command (append
             (list "mise" "--cd" ipykernel-manager--broker-directory
                   "exec" "--" "python" ipykernel-manager--handler)
             arguments)
   :connection-type 'pipe
   :noquery t))

(defun ipykernel-manager--start-renderer (kernel-id event-port)
  "Start the renderer for KERNEL-ID, reading events from EVENT-PORT."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "VITE_JUPYTER_EVAL_KERNEL_NAME" kernel-id)
    (setenv "VITE_JUPYTER_EVAL_EVENTS_URL"
            (format "http://127.0.0.1:%d/jupyter-eval-events" event-port))
    (make-process
     :name "jupyter-eval-renderer"
     :buffer (get-buffer-create ipykernel-manager--buffer)
     :command
     (list "mise" "--cd" ipykernel-manager--renderer-directory
           "exec" "--" "npm" "run" "dev" "--"
           "--host" "127.0.0.1"
           "--port" (number-to-string ipykernel-manager-vite-port)
           "--strictPort")
     :connection-type 'pipe
     :noquery t)))

(defun ipykernel-manager--open-frontend (attempt)
  "Open the Vite frontend after it becomes reachable, up to ATTEMPT 20."
  (setq ipykernel-manager--frontend-timer nil)
  (let ((url (format "http://127.0.0.1:%d/" ipykernel-manager-vite-port)))
    (condition-case nil
        (let ((buffer (url-retrieve-synchronously url t t 1)))
          (when buffer
            (kill-buffer buffer)
            (setq ipykernel-manager--frontend-timer nil)
            (if (fboundp 'xwidget-webkit-browse-url)
                (xwidget-webkit-browse-url url)
              (message "Jupyter Eval: Vite ready at %s; xwidget WebKit is unavailable"
                       url))))
      (error nil))
    (when (and (not ipykernel-manager--frontend-timer)
               (< attempt 20))
      (setq ipykernel-manager--frontend-timer
            (run-at-time 0.25 nil #'ipykernel-manager--open-frontend
                         (1+ attempt))))
    (when (and (not ipykernel-manager--frontend-timer)
               (= attempt 20))
      (message "Jupyter Eval: Vite did not become ready at %s" url))))

(defun ipykernel-manager--publisher-filter (_process output)
  "Report publisher request results from OUTPUT in the Emacs message log."
  (dolist (line (split-string output "\n" t))
    (condition-case nil
        (let ((result (json-parse-string line :object-type 'alist)))
          (if-let* ((error-message (alist-get 'error result)))
              (message "Jupyter Eval: execution failed: %s" error-message)
              (message "Jupyter Eval: execution submitted; request=%s"
                     (alist-get 'requestId result))))
      (json-parse-error
       (message "Jupyter Eval publisher: %s" line)))))

(defun ipykernel-manager--service-sentinel (process event)
  "Report unexpected termination of a managed bridge PROCESS."
  (when (and (memq (process-status process) '(exit signal))
             (not (process-get process 'ipykernel-manager-stopping))
             (not (zerop (process-exit-status process))))
    (message "Jupyter Eval: %s stopped: %s"
             (process-name process) (string-trim event))))

(defun ipykernel-manager--start-services (kernel-id connection-file)
  "Start publisher, subscriber, and Vite for KERNEL-ID and CONNECTION-FILE."
  (let ((event-port (ipykernel-manager--available-port)))
    (setq ipykernel-manager--connection-file connection-file
          ipykernel-manager--kernel-pid-file
          (ipykernel-manager--kernel-pid-file connection-file)
          ipykernel-manager--event-port event-port
          ipykernel-manager--publisher
          (ipykernel-manager--start-process
           "ipykernel-publisher"
           (list "publish" "--connection-file" connection-file))
          ipykernel-manager--subscriber
          (ipykernel-manager--start-process
           "ipykernel-subscriber"
           (list "subscribe" "--connection-file" connection-file
                 "--event-port" (number-to-string event-port)))
          ipykernel-manager--vite
          (ipykernel-manager--start-renderer kernel-id event-port))
    (dolist (process (list ipykernel-manager--publisher
                           ipykernel-manager--subscriber
                           ipykernel-manager--vite))
      (set-process-sentinel process #'ipykernel-manager--service-sentinel))
    (set-process-filter ipykernel-manager--publisher
                        #'ipykernel-manager--publisher-filter)
    (setq ipykernel-manager--frontend-timer
          (run-at-time 0 nil #'ipykernel-manager--open-frontend 0))
    (message
     "Jupyter Eval: connection=%s; event bridge=127.0.0.1:%d; Vite=127.0.0.1:%d"
     connection-file event-port ipykernel-manager-vite-port)))

(defun ipykernel-manager--connection-ready-p (connection-file)
  "Return non-nil when CONNECTION-FILE contains valid kernel connection JSON."
  (and (file-readable-p connection-file)
       (condition-case nil
           (with-temp-buffer
             (insert-file-contents connection-file)
             (let ((connection (json-parse-buffer :object-type 'alist)))
               (and (alist-get 'shell_port connection)
                    (alist-get 'iopub_port connection)
                    (alist-get 'key connection))))
         (json-parse-error nil))))

(defun ipykernel-manager--start-after-connection (kernel-id connection-file)
  "Start bridge services when CONNECTION-FILE is stable and valid."
  (if (ipykernel-manager--connection-ready-p connection-file)
      (progn
        (setq ipykernel-manager--startup-timer nil)
        (message "Jupyter Eval: kernel %s ready; connection=%s"
                 kernel-id connection-file)
        (ipykernel-manager--start-services kernel-id connection-file))
    (setq ipykernel-manager--startup-timer
          (run-at-time 0.2 nil #'ipykernel-manager--start-after-connection
                       kernel-id connection-file))))

(defun ipykernel-manager--kernel-sentinel (process event)
  "Begin deterministic connection-file verification after PROCESS exits."
  (when (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
    (let ((kernel-id (process-get process 'kernel-id))
          (connection-file (process-get process 'connection-file)))
      (message "Jupyter Eval: waiting for connection=%s" connection-file)
      ;; Recheck after one second so clients never consume a partially-written file.
      (setq ipykernel-manager--startup-timer
            (run-at-time 1 nil #'ipykernel-manager--start-after-connection
                         kernel-id connection-file))))
  (unless (and (eq (process-status process) 'exit)
               (zerop (process-exit-status process)))
    (message "Jupyter kernel launch failed: %s" (string-trim event))))

;;;###autoload
(defun ipykernel-manager-start (kernel-id)
  "Start KERNEL-ID for the current visited Emacs buffer."
  (interactive
   (list (completing-read "Jupyter kernel: "
                          (ipykernel-manager--kernel-ids) nil t)))
  (unless buffer-file-name
    (user-error "The current buffer must visit a file"))
  (unless (file-readable-p ipykernel-manager--handler)
    (user-error "Cannot read %s" ipykernel-manager--handler))
  (unless (executable-find "mise")
    (user-error "Cannot find mise; install it from https://mise.run"))
  (jupyter-eval-stop)
  (let ((buffer (get-buffer-create ipykernel-manager--buffer)))
    (with-current-buffer buffer
      (erase-buffer))
    (let* ((buffer-path (file-truename buffer-file-name))
           (connection-file
            (ipykernel-manager--connection-file kernel-id buffer-path))
           (process
           (ipykernel-manager--start-process
            "ipykernel-launcher"
            (list "launch-kernel" "--kernel-id" kernel-id
                  "--buffer-path" buffer-path))))
      (process-put process 'kernel-id kernel-id)
      (process-put process 'connection-file connection-file)
      (set-process-sentinel process #'ipykernel-manager--kernel-sentinel))))

;;;###autoload
(defun ipykernel-manager-send-region (beg end)
  "Send the region from BEG to END through the managed publisher."
  (interactive "r")
  (unless (process-live-p ipykernel-manager--publisher)
    (user-error "Start a kernel with ipykernel-manager-start first"))
  (process-send-string
   ipykernel-manager--publisher
   (concat
    (json-serialize
     `((code . ,(buffer-substring-no-properties beg end))))
    "\n")))

;;;###autoload
(defun jupyter-eval-stop ()
  "Stop the managed publisher, subscriber, and Vite processes."
  (interactive)
  (when (timerp ipykernel-manager--startup-timer)
    (cancel-timer ipykernel-manager--startup-timer))
  (when (timerp ipykernel-manager--frontend-timer)
    (cancel-timer ipykernel-manager--frontend-timer))
  (dolist (process (list ipykernel-manager--publisher
                         ipykernel-manager--subscriber
                         ipykernel-manager--vite))
    (when (process-live-p process)
      (process-put process 'ipykernel-manager-stopping t)
      (delete-process process)))
  (when (and ipykernel-manager--kernel-pid-file
             (file-readable-p ipykernel-manager--kernel-pid-file))
    (let ((pid (string-to-number
                (string-trim
                 (with-temp-buffer
                   (insert-file-contents ipykernel-manager--kernel-pid-file)
                   (buffer-string))))))
      (when (process-attributes pid)
        (signal-process pid 'SIGTERM)))
    (delete-file ipykernel-manager--kernel-pid-file))
  (when (and ipykernel-manager--connection-file
             (file-exists-p ipykernel-manager--connection-file))
    (let ((connection-file ipykernel-manager--connection-file))
      (ipykernel-manager--delete-connection-file connection-file)
      ;; ipykernel's shutdown path can recreate its connection file briefly.
      (run-at-time 1 nil #'ipykernel-manager--delete-connection-file
                   connection-file)))
  (setq ipykernel-manager--publisher nil
        ipykernel-manager--subscriber nil
        ipykernel-manager--vite nil
        ipykernel-manager--event-port nil
        ipykernel-manager--kernel-pid-file nil
        ipykernel-manager--frontend-timer nil
        ipykernel-manager--startup-timer nil
        ipykernel-manager--connection-file nil)
  (message "Jupyter Eval bridge processes stopped"))

(provide 'ipykernel-manager)

;;; ipykernel-manager.el ends here
