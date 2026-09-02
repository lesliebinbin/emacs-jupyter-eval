;;; jupyter-eval.el --- Jupyter output frontend for Emacs -*- lexical-binding: t; -*-

;; Author: Leslie Huang
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: jupyter, tools

;;; Commentary:

;; Starts the managed Jupyter kernel, IOPub subscriber, and Vite frontend.

;;; Code:

(require 'ipykernel-manager)

;;;###autoload
(defalias 'run-jupyter-eval #'ipykernel-manager-start
  "Start the managed Jupyter Eval services for the current buffer.")

;;;###autoload
(defalias 'jupyter-eval-send-region #'ipykernel-manager-send-region
  "Send the active region to the managed Jupyter kernel.")

(with-eval-after-load 'code-cells
  (add-to-list 'code-cells-eval-region-commands
               '(jupyter-eval-mode . jupyter-eval-send-region)))

(define-minor-mode jupyter-eval-mode
  "Route code-cells evaluation through Jupyter Eval."
  :lighter " JEval")

(add-hook 'python-mode-hook #'jupyter-eval-mode)
(add-hook 'python-ts-mode-hook #'jupyter-eval-mode)

(provide 'jupyter-eval)

;;; jupyter-eval.el ends here
