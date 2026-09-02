;;; jupyter-eval-test.el --- Tests for jupyter-eval -*- lexical-binding: t; -*-

(require 'ert)
(require 'jupyter-eval)

(ert-deftest jupyter-eval-runs-through-managed-bridge ()
  (should (eq (symbol-function 'run-jupyter-eval)
              'ipykernel-manager-start))
  (should (eq (symbol-function 'jupyter-eval-send-region)
              'ipykernel-manager-send-region)))

(ert-deftest jupyter-eval-allocates-loopback-port ()
  (should (integerp (ipykernel-manager--available-port))))
