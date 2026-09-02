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
  (should (fboundp 'jupyter-eval-stop)))

(ert-deftest jupyter-eval-allocates-loopback-port ()
  (should (integerp (jupyter-eval--available-port))))

(ert-deftest jupyter-eval-minor-mode-hooked ()
  (should (memq #'code-cells-adapt-mode python-mode-hook))
  (should (memq #'code-cells-adapt-mode python-ts-mode-hook)))

(ert-deftest jupyter-eval-path-constants ()
  (should (file-exists-p jupyter-eval--engine-launcher))
  (should (file-exists-p jupyter-eval--broker-main)))

;;; jupyter-eval-test.el ends here
