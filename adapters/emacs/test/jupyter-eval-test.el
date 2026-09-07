;;; jupyter-eval-test.el --- Tests for jupyter-eval -*- lexical-binding: t; -*-

(require 'ert)

;; Put the repo root (two levels up) on `load-path' so the root
;; jupyter-eval.el is found whether running via Eldev or batch.
(let ((dir (file-name-directory
            (or (and (boundp 'byte-compile-current-file) byte-compile-current-file)
                load-file-name
                buffer-file-name))))
  (add-to-list 'load-path (expand-file-name "../../.." dir)))

(require 'jupyter-eval)

(ert-deftest jupyter-eval-provides-features ()
  (should (featurep 'jupyter-eval))
  (should (featurep 'code-cells-adapt)))

(ert-deftest jupyter-eval-defines-commands ()
  (should (fboundp 'jupyter-eval-start))
  (should (fboundp 'jupyter-eval-send-region))
  (should (fboundp 'jupyter-eval-stop))
  (should (fboundp 'jupyter-eval-stop-all)))

(ert-deftest jupyter-eval-allocates-loopback-port ()
  (should (integerp (jupyter-eval--available-port))))

(ert-deftest jupyter-eval-minor-mode-hooked ()
  (should (memq #'code-cells-adapt-mode python-mode-hook))
  (should (memq #'code-cells-adapt-mode python-ts-mode-hook)))

(ert-deftest jupyter-eval-path-constants ()
  (should (file-exists-p jupyter-eval--engine-launcher))
  (should (file-exists-p jupyter-eval--broker-main)))

(ert-deftest jupyter-eval-capabilities-are-random-and-private ()
  (let* ((first (jupyter-eval--random-token))
         (second (jupyter-eval--random-token))
         (session (jupyter-eval--make-session
                   :id "session"
                   :generation "generation"
                   :capability first
                   :source-path "/tmp/example.py"
                   :label "python - example.py"
                   :kernel-id "python"
                   :event-port 8766))
         (public (jupyter-eval--public-session session)))
    (should (= (length first) 64))
    (should-not (equal first second))
    (should-not (assq 'capability public))))

(ert-deftest jupyter-eval-routes-regions-by-source-buffer ()
  (let ((jupyter-eval--sessions (make-hash-table :test #'equal))
        sent-process
        sent-payload)
    (with-temp-buffer
      (setq buffer-file-name "/tmp/jupyter-eval-one.py")
      (insert "print('one')")
      (puthash (file-truename buffer-file-name)
               (jupyter-eval--make-session
                :id "one"
                :source-path (file-truename buffer-file-name)
                :input-processor 'input-one
                :output-processor 'output-one)
               jupyter-eval--sessions)
      (cl-letf (((symbol-function 'process-live-p)
                 (lambda (process)
                   (memq process '(input-one output-one))))
                ((symbol-function 'process-send-string)
                 (lambda (process payload)
                   (setq sent-process process
                         sent-payload payload))))
        (jupyter-eval-send-region (point-min) (point-max))))
    (should (eq sent-process 'input-one))
    (should (string-match-p "print('one')" sent-payload))))

(ert-deftest jupyter-eval-stopping-one-session-preserves-another ()
  (let* ((jupyter-eval--sessions (make-hash-table :test #'equal))
         (one (jupyter-eval--make-session
               :id "one" :source-path "/tmp/one.py"
               :label "python - one.py"))
         (two (jupyter-eval--make-session
               :id "two" :source-path "/tmp/two.py"
               :label "python - two.py")))
    (puthash "/tmp/one.py" one jupyter-eval--sessions)
    (puthash "/tmp/two.py" two jupyter-eval--sessions)
    (cl-letf (((symbol-function 'jupyter-eval--write-registry) #'ignore))
      (jupyter-eval--stop-session one))
    (should-not (gethash "/tmp/one.py" jupyter-eval--sessions))
    (should (eq two (gethash "/tmp/two.py" jupyter-eval--sessions)))))

;;; jupyter-eval-test.el ends here
