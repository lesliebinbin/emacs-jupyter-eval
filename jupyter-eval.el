;;; jupyter-eval.el --- Emacs adapter entry point -*- lexical-binding: t; -*-

;; Author: Leslie Huang
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: jupyter, tools

;;; Commentary:
;;
;; Entry point for the Jupyter Eval Emacs adapter.
;;
;; The implementation lives in `adapters/emacs/'.  When this package
;; is installed (e.g. via quelpa with `:files ("*")'), Emacs only
;; adds the package's top-level directory to `load-path', so the
;; files in `adapters/emacs/' cannot be found with `require'.  This
;; file adds that directory to `load-path' and loads the
;; implementation, so the package works both installed and from a
;; checkout.

;;; Code:

(eval-and-compile
  (add-to-list 'load-path
               (expand-file-name
                "adapters/emacs"
                (file-name-directory
                 (or load-file-name
                     buffer-file-name
                     (and (boundp 'byte-compile-current-file)
                          byte-compile-current-file))))))

(require 'jupyter-eval)

(provide 'jupyter-eval)

;;; jupyter-eval.el ends here
