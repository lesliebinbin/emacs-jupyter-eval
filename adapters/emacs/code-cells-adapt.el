;;; code-cells-adapt.el --- Route code-cells evaluation through Jupyter Eval -*- lexical-binding: t; -*-

;; Author: Leslie Huang
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: jupyter, tools

;;; Commentary:
;;
;; Adapts `code-cells' evaluation to the Jupyter Eval coordinator in the
;; package root `jupyter-eval.el'.  The public API is `jupyter-eval-start',
;; `jupyter-eval-send-region', `jupyter-eval-stop', and
;; `jupyter-eval-stop-all'.

;;; Code:

;;;###autoload
(define-minor-mode code-cells-adapt-mode
  "Route code-cells evaluation through Jupyter Eval."
  :lighter " JEval")

(defvar code-cells-eval-region-commands)

(with-eval-after-load 'code-cells
  (add-to-list 'code-cells-eval-region-commands
               '(code-cells-adapt-mode . jupyter-eval-send-region)))

(add-hook 'python-mode-hook #'code-cells-adapt-mode)
(add-hook 'python-ts-mode-hook #'code-cells-adapt-mode)

(define-obsolete-function-alias 'jupyter-eval-mode #'code-cells-adapt-mode "0.2.0")

(provide 'code-cells-adapt)

;;; code-cells-adapt.el ends here
