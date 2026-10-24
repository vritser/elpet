;;; elpet-markdown.el --- Small Markdown presentation for bubbles -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Turn common Markdown into styled display text, without modifying the source,
;; running modes, evaluating code, or fetching links and images.  Unclosed inline
;; syntax stays literal until a later streaming update completes it.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defun elpet-markdown--inline (text &optional face depth)
  "Render inline TEXT with inherited FACE and bounded nesting DEPTH."
  (save-match-data
    (let ((position 0) (depth (or depth 0)) parts)
      (while (and (< depth 8)
                  (string-match "\\\\[[:punct:]]\\|`+\\|\\*+\\|_+\\|!?\\[" text position))
        (let* ((start (match-beginning 0))
               (end (match-end 0))
               (token (match-string 0 text))
               (rendered nil))
          (push (propertize (substring text position start) 'face face) parts)
          (cond
           ((eq (aref token 0) ?\\)
            (setq rendered (propertize (substring token 1) 'face face)))
           ((member token '("[" "!["))
            (when (and (string-match "!?\\[\\([^]\n]*\\)\\](\\([^()\n ]+\\))" text start)
                       (= (match-beginning 0) start))
              (let ((label (match-string 1 text)))
                (setq end (match-end 0)
                      rendered (elpet-markdown--inline
                                label (if (equal token "[")
                                          (append '(:underline t) face) face)
                                (1+ depth))))))
           ((or (eq (aref token 0) ?`)
                (and (<= (length token) 3) (< end (length text))
                     (not (memq (aref text end) '(?\s ?\t)))
                     (not (and (eq (aref token 0) ?_) (> start 0)
                               (string-match-p "[[:alnum:]]" (substring text (1- start) start))))))
            (let ((search end) close close-end
                  (code (eq (aref token 0) ?`))
                  (pattern (concat (regexp-quote (substring token 0 1)) "+")))
              (while (and (not close) (string-match pattern text search))
                (setq search (match-end 0))
                (when (and (equal (match-string 0 text) token)
                           (> (match-beginning 0) end)
                           (or code
                               (and (not (memq (aref text (1- (match-beginning 0))) '(?\s ?\t)))
                                    (not (and (eq (aref token 0) ?_)
                                              (< search (length text))
                                              (string-match-p "[[:alnum:]]" (substring text search (1+ search))))))))
                  (setq close (match-beginning 0) close-end search)))
              (when close
                (let* ((body (substring text end close))
                       (style (append (if code '(:family "monospace")
                                        (pcase (length token)
                                          (1 '(:slant italic))
                                          (2 '(:weight bold))
                                          (3 '(:weight bold :slant italic)))) face)))
                  (setq end close-end
                        rendered (if code (propertize body 'face style)
                                   (elpet-markdown--inline body style (1+ depth)))))))))
          (push (or rendered (propertize token 'face face)) parts)
          (setq position end)))
      (push (propertize (substring text position) 'face face) parts)
      (apply #'concat (nreverse parts)))))

(defun elpet-markdown-render (text)
  "Return styled display text for the Markdown subset in TEXT.
Support ATX headings, emphasis, inline and fenced code, lists, blockquotes,
and inline links/images (labels only).  Unsupported syntax remains literal.
The original TEXT and its properties are never changed."
  (save-match-data
    (let (lines fence fence-length)
      (dolist (line (split-string (substring-no-properties text) "\n" nil))
        (cond
         (fence
          (if (and (string-match "\\` \\{0,3\\}\\(`+\\|~+\\)[ \t]*\\'" line)
                   (= (aref (match-string 1 line) 0) fence)
                   (>= (length (match-string 1 line)) fence-length))
              (setq fence nil)
            (push (propertize line 'face '(:family "monospace")) lines)))
         ((string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\(.*\\)\\'" line)
          (let ((delimiter (match-string 1 line)) (info (match-string 2 line)))
            (if (and (eq (aref delimiter 0) ?`) (string-search "`" info))
                (push (elpet-markdown--inline line) lines)
              (setq fence (aref delimiter 0) fence-length (length delimiter)))))
         ((string-match "\\` \\{0,3\\}#\\{1,6\\}[ \t]+\\(.*\\)" line)
          (push (elpet-markdown--inline
                 (replace-regexp-in-string "[ \t]+#+[ \t]*\\'" "" (match-string 1 line))
                 '(:weight bold)) lines))
         (t
          (setq line (replace-regexp-in-string "\\`\\([ \t]*\\)[*+-][ \t]+" "\\1• " line))
          (setq line (replace-regexp-in-string "\\` \\{0,3\\}>[ \t]?" "│ " line))
          (push (elpet-markdown--inline line) lines))))
      (mapconcat #'identity (nreverse lines) "\n"))))

(provide 'elpet-markdown)
;;; elpet-markdown.el ends here
