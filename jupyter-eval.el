;;; jupyter-eval.el --- Coordinate the Jupyter Eval components -*- lexical-binding: t; -*-

;; Author: Leslie Huang
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: jupyter, tools

;;; Commentary:
;;
;; Coordinates the Jupyter Eval components from Emacs: launches the
;; engine kernel, starts the broker input and output processors, and
;; brings up the renderer frontend.
;;
;; The code-cells adaptation (minor mode and `code-cells'
;; integration) lives in `adapters/emacs/code-cells-adapt.el'.  When
;; this package is installed (e.g. via quelpa with `:files ("*")'),
;; Emacs only adds the package's top-level directory to `load-path',
;; so that file is loaded with the adapter directory on `load-path'
;; for the duration of the load only.

;;; Code:

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
(defconst jupyter-eval--buffer "*jupyter-eval*")
(defcustom jupyter-eval-vite-port 5173
  "Port used by the manager-owned Vite development server."
  :type 'integer
  :group 'jupyter-eval)
(defvar jupyter-eval--launcher nil)
(defvar jupyter-eval--input-processor nil)
(defvar jupyter-eval--output-processor nil)
(defvar jupyter-eval--vite nil)
(defvar jupyter-eval--connection-file nil)
(defvar jupyter-eval--kernel-pid-file nil)
(defvar jupyter-eval--event-port nil)
(defvar jupyter-eval--startup-timer nil)
(defvar jupyter-eval--frontend-timer nil)

(defun jupyter-eval--uv-command (directory script &rest arguments)
  "Return a command list running SCRIPT with uv in DIRECTORY."
  (append (list "uv" "run" "--project" directory "python" script)
          arguments))

(defun jupyter-eval--kernel-ids ()
  "Return the installed Jupyter kernel IDs."
  (with-temp-buffer
    (let ((stderr (generate-new-buffer " *jupyter-eval-list-stderr*")))
      (unwind-protect
          (unless
              (zerop
               (apply #'call-process
                      "uv" nil (list t stderr) nil
                      (jupyter-eval--uv-command
                       jupyter-eval--engine-directory
                       jupyter-eval--engine-launcher
                       "list")))
            (error "Could not list Jupyter kernels: %s"
                   (string-trim
                    (with-current-buffer stderr (buffer-string)))))
        (kill-buffer stderr)))
    (goto-char (point-min))
    (json-parse-buffer :array-type 'list)))

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

(defun jupyter-eval--delete-connection-file (connection-file)
  "Delete CONNECTION-FILE after its kernel has completed shutdown."
  (when (file-exists-p connection-file)
    (delete-file connection-file)))

(defun jupyter-eval--start-process (name command)
  "Start NAME with the given COMMAND list."
  (make-process
   :name name
   :buffer (get-buffer-create jupyter-eval--buffer)
   :command command
   :connection-type 'pipe
   :noquery t))

(defun jupyter-eval--start-renderer (kernel-id event-port)
  "Start the renderer for KERNEL-ID, reading events from EVENT-PORT."
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "VITE_JUPYTER_EVAL_KERNEL_NAME" kernel-id)
    (setenv "VITE_JUPYTER_EVAL_EVENTS_URL"
            (format "http://127.0.0.1:%d/jupyter-eval-events" event-port))
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
     :noquery t)))

(defun jupyter-eval--open-frontend (attempt)
  "Open the Vite frontend after it becomes reachable, up to ATTEMPT 20."
  (setq jupyter-eval--frontend-timer nil)
  (let ((url (format "http://127.0.0.1:%d/" jupyter-eval-vite-port)))
    (condition-case nil
        (let ((buffer (url-retrieve-synchronously url t t 1)))
          (when buffer
            (kill-buffer buffer)
            (setq jupyter-eval--frontend-timer nil)
            (if (fboundp 'xwidget-webkit-browse-url)
                (xwidget-webkit-browse-url url)
              (message "Jupyter Eval: Vite ready at %s; xwidget WebKit is unavailable"
                       url))))
      (error nil))
    (when (and (not jupyter-eval--frontend-timer)
               (< attempt 20))
      (setq jupyter-eval--frontend-timer
            (run-at-time 0.25 nil #'jupyter-eval--open-frontend
                         (1+ attempt))))
    (when (and (not jupyter-eval--frontend-timer)
               (= attempt 20))
      (message "Jupyter Eval: Vite did not become ready at %s" url))))

(defun jupyter-eval--input-processor-filter (_process output)
  "Report input processor results from OUTPUT in the Emacs message log."
  (dolist (line (split-string output "\n" t))
    (condition-case nil
        (let ((result (json-parse-string line :object-type 'alist)))
          (if-let* ((error-message (alist-get 'error result)))
              (message "Jupyter Eval: execution failed: %s" error-message)
            (message "Jupyter Eval: execution submitted; request=%s"
                     (alist-get 'requestId result))))
      (json-parse-error
       (message "Jupyter Eval input processor: %s" line)))))

(defun jupyter-eval--service-sentinel (process event)
  "Report unexpected termination of a managed bridge PROCESS."
  (when (and (memq (process-status process) '(exit signal))
             (not (process-get process 'jupyter-eval-stopping))
             (not (zerop (process-exit-status process))))
    (message "Jupyter Eval: %s stopped: %s"
             (process-name process) (string-trim event))))

(defun jupyter-eval--launcher-filter (process output)
  "Accumulate launcher OUTPUT and parse its JSON result line."
  (let ((accumulated (concat (or (process-get process 'jupyter-eval-output) "")
                             output)))
    (process-put process 'jupyter-eval-output
                 (substring accumulated (max 0 (- (length accumulated) 4096))))
    (dolist (line (split-string accumulated "\n"))
      (unless (string-empty-p line)
        (condition-case nil
            (let ((result (json-parse-string line :object-type 'alist)))
              (setq jupyter-eval--connection-file
                    (alist-get 'connectionFile result)
                    jupyter-eval--kernel-pid-file
                    (alist-get 'pidFile result)))
          (json-parse-error nil))))))

(defun jupyter-eval--start-services (kernel-id connection-file)
  "Start input/output processors and Vite for KERNEL-ID and CONNECTION-FILE."
  (let ((event-port (jupyter-eval--available-port)))
    (setq jupyter-eval--connection-file connection-file
          jupyter-eval--event-port event-port
          jupyter-eval--input-processor
          (jupyter-eval--start-process
           "jupyter-eval-input"
           (jupyter-eval--uv-command
            jupyter-eval--broker-directory jupyter-eval--broker-main
            "input" "--connection-file" connection-file))
          jupyter-eval--output-processor
          (jupyter-eval--start-process
           "jupyter-eval-output"
           (jupyter-eval--uv-command
            jupyter-eval--broker-directory jupyter-eval--broker-main
            "output" "--connection-file" connection-file
            "--event-port" (number-to-string event-port)))
          jupyter-eval--vite
          (jupyter-eval--start-renderer kernel-id event-port))
    (dolist (process (list jupyter-eval--input-processor
                           jupyter-eval--output-processor
                           jupyter-eval--vite))
      (set-process-sentinel process #'jupyter-eval--service-sentinel))
    (set-process-filter jupyter-eval--input-processor
                        #'jupyter-eval--input-processor-filter)
    (setq jupyter-eval--frontend-timer
          (run-at-time 0 nil #'jupyter-eval--open-frontend 0))
    (message
     "Jupyter Eval: connection=%s; event bridge=127.0.0.1:%d; Vite=127.0.0.1:%d"
     connection-file event-port jupyter-eval-vite-port)))

(defun jupyter-eval--connection-ready-p (connection-file)
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

(defun jupyter-eval--start-after-connection (kernel-id connection-file attempts)
  "Start bridge services when CONNECTION-FILE is stable and valid."
  (if (jupyter-eval--connection-ready-p connection-file)
      (progn
        (setq jupyter-eval--startup-timer nil)
        (message "Jupyter Eval: kernel %s ready; connection=%s"
                 kernel-id connection-file)
        (jupyter-eval--start-services kernel-id connection-file))
    (if (>= attempts 50)
        (message "Jupyter Eval: kernel %s never produced a valid connection file"
                 kernel-id)
      (setq jupyter-eval--startup-timer
            (run-at-time 0.2 nil #'jupyter-eval--start-after-connection
                         kernel-id connection-file (1+ attempts))))))

(defun jupyter-eval--kernel-sentinel (process event)
  "Begin connection-file verification after the launcher PROCESS exits."
  (setq jupyter-eval--launcher nil)
  (if (and (eq (process-status process) 'exit)
           (zerop (process-exit-status process))
           jupyter-eval--connection-file
           jupyter-eval--kernel-pid-file)
      (let ((kernel-id (process-get process 'kernel-id))
            (connection-file jupyter-eval--connection-file))
        (message "Jupyter Eval: waiting for connection=%s" connection-file)
        ;; Recheck after one second so clients never consume a partially-written file.
        (setq jupyter-eval--startup-timer
              (run-at-time 1 nil #'jupyter-eval--start-after-connection
                           kernel-id connection-file 0)))
    (message "Jupyter kernel launch failed: %s" (string-trim event))))

;;;###autoload
(defun jupyter-eval-start (&optional kernel-id)
  "Start KERNEL-ID for the current visited Emacs buffer."
  (interactive
   (let ((kernel-ids (jupyter-eval--kernel-ids)))
     (unless kernel-ids
       (user-error
        "No Jupyter kernels registered; run: uv run --project %s python launch.py register"
        jupyter-eval--engine-directory))
     (list (completing-read "Jupyter kernel: " kernel-ids nil t))))
  (unless buffer-file-name
    (user-error "The current buffer must visit a file"))
  (unless (file-readable-p jupyter-eval--engine-launcher)
    (user-error "Cannot read %s" jupyter-eval--engine-launcher))
  (unless (file-readable-p jupyter-eval--broker-main)
    (user-error "Cannot read %s" jupyter-eval--broker-main))
  (unless (executable-find "uv")
    (user-error "Cannot find uv; install it from https://docs.astral.sh/uv"))
  (unless (executable-find "mise")
    (user-error "Cannot find mise; install it from https://mise.run"))
  (jupyter-eval-stop)
  (let ((buffer (get-buffer-create jupyter-eval--buffer)))
    (with-current-buffer buffer
      (erase-buffer)))
  (setq jupyter-eval--connection-file nil
        jupyter-eval--kernel-pid-file nil)
  (let* ((buffer-path (file-truename buffer-file-name))
         (process
          (jupyter-eval--start-process
           "jupyter-eval-launcher"
           (jupyter-eval--uv-command
            jupyter-eval--engine-directory jupyter-eval--engine-launcher
            "launch" "--kernel-id" kernel-id "--buffer-path" buffer-path))))
    (process-put process 'kernel-id kernel-id)
    (set-process-filter process #'jupyter-eval--launcher-filter)
    (set-process-sentinel process #'jupyter-eval--kernel-sentinel)
    (setq jupyter-eval--launcher process)))

;;;###autoload
(defun jupyter-eval-send-region (beg end)
  "Send the region from BEG to END through the input processor."
  (interactive "r")
  (unless (process-live-p jupyter-eval--input-processor)
    (user-error "Start a kernel with jupyter-eval-start first"))
  (process-send-string
   jupyter-eval--input-processor
   (concat
    (json-serialize
     `((code . ,(buffer-substring-no-properties beg end))))
    "\n")))

;;;###autoload
(defun jupyter-eval-stop ()
  "Stop the managed kernel, broker processors, and Vite processes."
  (interactive)
  (when (timerp jupyter-eval--startup-timer)
    (cancel-timer jupyter-eval--startup-timer))
  (when (timerp jupyter-eval--frontend-timer)
    (cancel-timer jupyter-eval--frontend-timer))
  (dolist (process (list jupyter-eval--launcher
                         jupyter-eval--input-processor
                         jupyter-eval--output-processor
                         jupyter-eval--vite))
    (when (process-live-p process)
      (process-put process 'jupyter-eval-stopping t)
      (delete-process process)))
  (when (and jupyter-eval--kernel-pid-file
             (file-readable-p jupyter-eval--kernel-pid-file))
    (let ((pid (string-to-number
                (string-trim
                 (with-temp-buffer
                   (insert-file-contents jupyter-eval--kernel-pid-file)
                   (buffer-string))))))
      (when (process-attributes pid)
        (signal-process pid 'SIGTERM)))
    (delete-file jupyter-eval--kernel-pid-file))
  (when (and jupyter-eval--connection-file
             (file-exists-p jupyter-eval--connection-file))
    (let ((connection-file jupyter-eval--connection-file))
      (jupyter-eval--delete-connection-file connection-file)
      ;; ipykernel's shutdown path can recreate its connection file briefly.
      (run-at-time 1 nil #'jupyter-eval--delete-connection-file
                   connection-file)))
  (setq jupyter-eval--launcher nil
        jupyter-eval--input-processor nil
        jupyter-eval--output-processor nil
        jupyter-eval--vite nil
        jupyter-eval--event-port nil
        jupyter-eval--kernel-pid-file nil
        jupyter-eval--frontend-timer nil
        jupyter-eval--startup-timer nil
        jupyter-eval--connection-file nil)
  (message "Jupyter Eval processes stopped"))

(define-obsolete-function-alias 'run-jupyter-eval #'jupyter-eval-start "0.2.0")

(let ((load-path (cons (expand-file-name "adapters/emacs" jupyter-eval--directory)
                       load-path)))
  (require 'code-cells-adapt))

(provide 'jupyter-eval)

;;; jupyter-eval.el ends here
