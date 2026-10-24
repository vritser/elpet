;;; elpet-chat.el --- Optional gptel conversations -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; One dedicated conversation, using gptel's configured backend and model.
;; Only explicit send commands make requests.  Saved sessions are JSON data.

;;; Code:
(require 'elpet-events)
(require 'json)
(require 'subr-x)
(require 'face-remap)

(declare-function gptel-request "gptel-request" (&optional prompt &rest args))
(declare-function gptel-abort "gptel-request" (buffer))
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-system-prompt)
(defvar gptel-use-tools)
(defvar gptel-tools)
(defvar gptel-use-context)
(declare-function markdown-mode "markdown-mode" ())
(declare-function markdown-toggle-markup-hiding "markdown-mode" (&optional arg))
(defvar markdown-fontify-code-blocks-natively)
(defvar markdown-hide-urls)
(defvar markdown-hide-markup)

(defface elpet-chat-user '((t (:inherit font-lock-keyword-face :weight bold)))
  "Conversation label for user messages." :group 'elpet)
(defface elpet-chat-pet '((t (:inherit success :weight bold)))
  "Conversation label for pet messages." :group 'elpet)
(defface elpet-chat-title
  '((t (:inherit variable-pitch :height 1.8 :weight bold)))
  "Title of the pet conversation." :group 'elpet)
(defface elpet-chat-meta '((t (:inherit shadow :height 0.9 :weight normal)))
  "Secondary information in conversations." :group 'elpet)

;; Fontification may remove rear-nonsticky text properties, but not this fallback.
(put 'elpet-chat-transcript 'rear-nonsticky t)

(defcustom elpet-chat-persona
  "You are a friendly Emacs companion. Reply naturally in the user's language. Keep replies concise unless asked for detail."
  "Default system prompt for new pet conversations."
  :type 'string :group 'elpet)

(cl-defstruct (elpet-chat--request (:constructor elpet-chat--make-request))
  buffer id prompt (response "") status error timer preview)

(defvar elpet-chat--buffer nil)
(defvar elpet-chat--buffers nil)
(defvar-local elpet-chat--turns nil)
(defvar-local elpet-chat--input nil)
(defvar-local elpet-chat--active nil)
(defvar-local elpet-chat--last nil)
(defvar-local elpet-chat--persona nil)
(defvar-local elpet-chat--pet nil)
(defvar-local elpet-chat--source nil)
(defvar-local elpet-chat--epoch nil)
(defvar-local elpet-chat--sequence 0)
(defvar-local elpet-chat--serial 0)
(defvar-local elpet-chat--appearance nil)
(defvar-local elpet-chat--window-margins nil)

(defvar elpet-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'elpet-chat-send)
    (define-key map (kbd "C-c RET") #'elpet-chat-send)
    (define-key map (kbd "C-c C-k") #'elpet-chat-stop)
    (define-key map (kbd "C-c C-r") #'elpet-chat-retry)
    (define-key map (kbd "C-c C-p") #'elpet-chat-set-persona)
    (define-key map (kbd "C-c C-s") #'elpet-chat-save)
    (define-key map (kbd "C-c C-v") #'elpet-chat-toggle-markup)
    map))

(define-minor-mode elpet-chat-mode
  "Pet conversation controls over Markdown or plain text.
Type beside the final unnumbered YOU label, then use \\[elpet-chat-send] to send.
\\[elpet-chat-stop] stops, \\[elpet-chat-retry] retries the current
draft, \\[elpet-chat-set-persona] sets the persona, and
\\[elpet-chat-save] saves completed turns and the draft as JSON data.
\\[elpet-chat-toggle-markup] toggles Markdown markers when markdown-mode is
installed."
  :lighter " Pet Chat"
  (if elpet-chat-mode
      (progn
        (unless elpet-chat--appearance
          (setq elpet-chat--appearance
                (mapcar (lambda (variable)
                          (list variable (local-variable-p variable)
                                (symbol-value variable)))
                        '(header-line-format mode-line-format line-spacing left-margin-width
                          right-margin-width display-line-numbers
                          visual-line-mode truncate-lines word-wrap)))
          (setq elpet-chat--window-margins
                (mapcar (lambda (window) (cons window (window-margins window)))
                        (get-buffer-window-list (current-buffer) nil t))))
        (visual-line-mode 1)
        (setq-local line-spacing 0.22
                    left-margin-width 9 right-margin-width 2
                    display-line-numbers nil
                    header-line-format '(:eval (elpet-chat--header-line))
                    mode-line-format
                    '(" " (:propertize "Pet Chat" face elpet-chat-meta) "  %p"))
        (add-hook 'kill-buffer-hook #'elpet-chat--cleanup nil t)
        (add-hook 'before-change-functions #'elpet-chat--protect-transcript nil t)
        (cl-pushnew (current-buffer) elpet-chat--buffers)
        (dolist (window (get-buffer-window-list (current-buffer) nil t))
          (set-window-margins window left-margin-width right-margin-width)))
    (elpet-chat--cleanup)
    (when elpet-chat--appearance
      (visual-line-mode
       (if (caddr (assq 'visual-line-mode elpet-chat--appearance)) 1 -1))
      (pcase-dolist (`(,variable ,local ,value) elpet-chat--appearance)
        (if local (set (make-local-variable variable) value)
          (kill-local-variable variable)))
      (dolist (window (get-buffer-window-list (current-buffer) nil t))
        (let ((margins (if-let* ((saved (assq window elpet-chat--window-margins)))
                           (cdr saved)
                         (cons left-margin-width right-margin-width))))
          (set-window-margins window (car margins) (cdr margins))))
      (setq elpet-chat--appearance nil elpet-chat--window-margins nil))
    (remove-hook 'before-change-functions #'elpet-chat--protect-transcript t)
    (remove-hook 'kill-buffer-hook #'elpet-chat--cleanup t)))

(defun elpet-chat--header-line ()
  "Return the conversation identity and current request status."
  (let ((status (cond (elpet-chat--active "Responding")
                      ((null elpet-chat--last) "Ready")
                      ((eq (elpet-chat--request-status elpet-chat--last) 'cancelled)
                       "Stopped")
                      (t "Needs attention")))
        (face (cond (elpet-chat--active 'elpet-chat-pet)
                    (elpet-chat--last 'warning)
                    (t 'elpet-chat-meta))))
    (list " " (propertize " ELPET " 'face 'elpet-chat-user)
          "  " (propertize status 'face face))))

(defun elpet-chat--setup ()
  "Set up optional Markdown rendering and the conversation controls."
  (if (require 'markdown-mode nil t)
      (progn
        (markdown-mode)
        (setq-local markdown-fontify-code-blocks-natively t markdown-hide-urls t)
        (markdown-toggle-markup-hiding 1)
        ;; Remapping stays local; other Markdown buffers keep their own faces.
        (cl-loop for level from 1 to 6 for scale in '(1.35 1.2 1.12 1.05 1.0 1.0) do
                 (face-remap-add-relative (intern (format "markdown-header-face-%d" level))
                                          :height scale :weight 'bold)))
    (text-mode))
  (elpet-chat-mode 1))

(defun elpet-chat-toggle-markup ()
  "Toggle Markdown syntax visibility without changing conversation content."
  (interactive)
  (elpet-chat--check)
  (unless (derived-mode-p 'markdown-mode)
    (user-error "Install markdown-mode to enable formatted chat"))
  (let ((inhibit-read-only t))
    (markdown-toggle-markup-hiding (if markdown-hide-markup -1 1))))

(defun elpet-chat--require-gptel ()
  "Load the optional transport, or report how to enable it."
  (unless (require 'gptel nil t)
    (user-error "Pet chat requires gptel; install and configure it first"))
  (unless (and (fboundp 'gptel-request) (fboundp 'gptel-abort))
    (user-error "This gptel version lacks the request/abort API")))

(defun elpet-chat--check ()
  "Check that the current buffer is a pet conversation."
  (unless elpet-chat-mode
    (user-error "Run this command in a pet chat buffer")))

(defun elpet-chat--draft ()
  "Return the editable draft in the current conversation."
  (if (and (markerp elpet-chat--input) (marker-position elpet-chat--input))
      (buffer-substring-no-properties elpet-chat--input (point-max)) ""))

(defun elpet-chat--protect-transcript (begin _end)
  "Keep completed messages before BEGIN immutable while allowing draft edits.
Use a change guard because Markdown fontification manages sticky properties."
  (when (and (not inhibit-read-only) (markerp elpet-chat--input)
             (< begin elpet-chat--input))
    (signal 'text-read-only nil)))

(defun elpet-chat--render (draft)
  "Render completed turns and DRAFT without changing the selected window."
  (let ((inhibit-read-only t))
    (remove-overlays (point-min) (point-max) 'elpet-chat-role t)
    (erase-buffer)
    (insert "\n" (propertize "Pet Chat" 'font-lock-face 'elpet-chat-title
                             'rear-nonsticky t) "\n")
    (insert (propertize
             (if elpet-chat--turns
                 (format "%s  /  %d %s"
                         (if (bound-and-true-p gptel-model) gptel-model "Conversation")
                         (/ (length elpet-chat--turns) 2)
                         (if (= (length elpet-chat--turns) 2) "exchange" "exchanges"))
               "A little company, right here in Emacs.")
             'font-lock-face 'elpet-chat-meta 'rear-nonsticky t) "\n\n")
    (cl-loop for turn in elpet-chat--turns for n from 0 do
             (elpet-chat--insert-label (if (cl-evenp n) 'user 'pet) (1+ (/ n 2)))
             (insert turn "\n\n"))
    (when elpet-chat--last
      (insert (propertize
               (if (eq (elpet-chat--request-status elpet-chat--last) 'cancelled)
                   "Reply stopped" "Could not finish the reply")
               'font-lock-face 'warning 'rear-nonsticky t) "\n")
      (when-let* ((error (elpet-chat--request-error elpet-chat--last)))
        (insert error "\n"))
      (unless (string-empty-p (elpet-chat--request-response elpet-chat--last))
        (insert (propertize "Partial reply - not included in conversation history"
                            'font-lock-face 'elpet-chat-meta 'rear-nonsticky t) "\n\n"
                (elpet-chat--request-response elpet-chat--last) "\n"))
      (insert "\n"))
    (if elpet-chat--active
        (elpet-chat--insert-label 'user (1+ (/ (length elpet-chat--turns) 2)))
      (elpet-chat--insert-label 'input))
    (setq elpet-chat--input (copy-marker (point)))
    (insert draft)
    (when elpet-chat--active
      (insert "\n\n")
      (elpet-chat--insert-label 'pet (1+ (/ (length elpet-chat--turns) 2))))
    (add-text-properties (point-min) elpet-chat--input
                         '(read-only t front-sticky (read-only)
                           category elpet-chat-transcript))
    (setq buffer-read-only nil)
    (set-buffer-modified-p nil)))

(defun elpet-chat--insert-label (role &optional turn)
  "Display ROLE beside the next message or draft without inserting text.
ROLE is `user', `pet', or `input'; TURN numbers a completed or pending exchange.
An input label has no exchange number."
  ;; A margin overlay leaves Markdown at the true beginning of its line.
  ;; Neither endpoint advances when the first draft or reply text is inserted.
  (let* ((pet (eq role 'pet))
         (label (concat " "
                        (propertize (if pet "PET" "YOU")
                                    'face (if pet 'elpet-chat-pet 'elpet-chat-user))
                        (when turn
                          (propertize (format " %02d" turn) 'face 'elpet-chat-meta))))
         (overlay (make-overlay (point) (point) nil nil nil)))
    (overlay-put overlay 'elpet-chat-role t)
    (overlay-put overlay 'before-string
                 (propertize " " 'display `((margin left-margin) ,label)))))

(defun elpet-chat--attach (&optional pet)
  "Attach the current conversation to PET, or the currently displayed pet."
  (let ((target (elpet--resolve pet)))
    (unless (eq target elpet-chat--pet)
      (when elpet-chat--pet
        (elpet-unregister-source elpet-chat--source elpet-chat--pet))
      (setq elpet-chat--pet target elpet-chat--sequence 0)
      (when target
        (setq elpet-chat--epoch
              (elpet-register-source
               elpet-chat--source
               (list :priority 40 :kinds (cons 'say elpet--activity-phases)) target))))))

;;;###autoload
(defun elpet-chat ()
  "Open the pet's dedicated conversation.  Opening never sends a request."
  (interactive)
  (elpet-chat--require-gptel)
  (unless (buffer-live-p elpet-chat--buffer)
    (let ((backend gptel-backend) (model gptel-model))
      (setq elpet-chat--buffer (generate-new-buffer "*elpet chat*"))
      (with-current-buffer elpet-chat--buffer
        (elpet-chat--setup)
        (setq-local gptel-backend backend gptel-model model)
        (setq elpet-chat--persona elpet-chat-persona
              elpet-chat--source (symbol-name (gensym "pet-chat-")))
        (elpet-chat--render ""))))
  (with-current-buffer elpet-chat--buffer
    (unless elpet-chat-mode (elpet-chat-mode 1))
    (elpet-chat--attach))
  (pop-to-buffer elpet-chat--buffer))

(defun elpet-chat--event (request kind)
  "Publish lifecycle KIND for REQUEST to the attached pet."
  (when (and elpet-chat--pet (elpet--resolve elpet-chat--pet))
    (cl-incf elpet-chat--sequence)
    (elpet-emit
     (list :schema-version 1 :pet-id (elpet-instance-id elpet-chat--pet)
           :source-id elpet-chat--source :source-epoch elpet-chat--epoch
           :sequence elpet-chat--sequence
           :event-id (format "%s-%d" (elpet-chat--request-id request)
                             elpet-chat--sequence)
           :activity-id (elpet-chat--request-id request) :kind kind :state 'thinking)
     elpet-chat--pet)))

(defun elpet-chat--current-p (request)
  "Whether REQUEST still owns its live conversation."
  (and (buffer-live-p (elpet-chat--request-buffer request))
       (eq request (buffer-local-value 'elpet-chat--active
                                       (elpet-chat--request-buffer request)))))

(defun elpet-chat--say (request final)
  "Show REQUEST's response, recording history only when FINAL."
  (when (and elpet-chat--pet (elpet--resolve elpet-chat--pet)
             (not (string-empty-p (elpet-chat--request-response request))))
    (setf (elpet-chat--request-preview request)
          (elpet-say
           (elpet-chat--request-response request)
           (list :source elpet-chat--source :replace-key "reply" :history final
                 :priority 40 :seconds (if final 20 10) :action 'elpet-chat :format 'markdown)
           elpet-chat--pet))))

(defun elpet-chat--preview (request)
  "Flush a throttled bubble preview if REQUEST is still active."
  (setf (elpet-chat--request-timer request) nil)
  (when (elpet-chat--current-p request)
    (with-current-buffer (elpet-chat--request-buffer request)
      (elpet-chat--say request nil))))

(defun elpet-chat--finish (request status &optional error)
  "Finish REQUEST with STATUS and optional ERROR exactly once."
  (when (elpet-chat--current-p request)
    (with-current-buffer (elpet-chat--request-buffer request)
      ;; Invalidate first: cancellation can synchronously call the callback.
      (setq elpet-chat--active nil)
      (when (timerp (elpet-chat--request-timer request))
        (cancel-timer (elpet-chat--request-timer request)))
      (setf (elpet-chat--request-timer request) nil
            (elpet-chat--request-status request) status
            (elpet-chat--request-error request) error)
      (when (and elpet-chat--pet (elpet-chat--request-preview request))
        (elpet-cancel (elpet-chat--request-preview request) elpet-chat--pet))
      (if (eq status 'finished)
          (progn
            (setq elpet-chat--turns
                  (append elpet-chat--turns
                          (list (elpet-chat--request-prompt request)
                                (elpet-chat--request-response request)))
                  elpet-chat--last nil)
            (elpet-chat--say request t))
        (setq elpet-chat--last request))
      (elpet-chat--event request status)
      (elpet-chat--render
       (if (eq status 'finished) "" (elpet-chat--request-prompt request)))
      (force-mode-line-update))))

(defun elpet-chat--callback (request response info)
  "Handle gptel RESPONSE and INFO for REQUEST without selecting a window."
  (when (elpet-chat--current-p request)
    (with-current-buffer (elpet-chat--request-buffer request)
      (cond
       ((stringp response)
        (setf (elpet-chat--request-response request)
              (concat (elpet-chat--request-response request) response))
        (let* ((inhibit-read-only t)
               (end (point-max))
               (following (cl-remove-if-not
                           (lambda (window) (>= (window-point window) end))
                           (get-buffer-window-list (current-buffer) nil t))))
          (save-excursion (goto-char end) (insert response))
          (dolist (window following) (set-window-point window (point-max))))
        (unless (elpet-chat--request-timer request)
          (setf (elpet-chat--request-timer request)
                (run-at-time 0.2 nil #'elpet-chat--preview request)))
        ;; gptel removes :stream when the backend falls back to one response.
        (unless (plist-get info :stream)
          (elpet-chat--callback request t info)))
       ((eq response t)
        (if (string-empty-p (string-trim (elpet-chat--request-response request)))
            (elpet-chat--finish request 'failed "Empty response")
          (elpet-chat--finish request 'finished)))
       ((eq response 'abort) (elpet-chat--finish request 'cancelled))
       ((null response)
        (elpet-chat--finish
         request 'failed (format "%s" (or (plist-get info :error)
                                          (plist-get info :status) "Request failed"))))
       ;; Reasoning and tool notifications are never conversation text.
       ))))

(defun elpet-chat-send ()
  "Send the current draft using gptel's configured model and backend."
  (interactive)
  (elpet-chat--check)
  (when elpet-chat--active (user-error "Stop the current reply before sending again"))
  (elpet-chat--require-gptel)
  (let ((prompt (string-trim (elpet-chat--draft))))
    (when (string-empty-p prompt) (user-error "Type a message beside the final YOU label first"))
    (elpet-chat--attach)
    (let ((request (elpet-chat--make-request
                    :buffer (current-buffer) :prompt prompt :status 'started
                    :id (format "request-%d" (cl-incf elpet-chat--serial)))))
      (setq elpet-chat--active request elpet-chat--last nil)
      (elpet-chat--render prompt)
      (setq buffer-read-only t)
      (force-mode-line-update)
      (elpet-chat--event request 'started)
      (condition-case err
          (let ((gptel-use-tools nil) (gptel-tools nil) (gptel-use-context nil))
            (gptel-request
             (append elpet-chat--turns (list prompt))
             :buffer (current-buffer) :stream t :system elpet-chat--persona
             :transforms nil
             :callback (lambda (response info)
                         (elpet-chat--callback request response info))))
        (quit (elpet-chat--finish request 'cancelled))
        (error (elpet-chat--finish request 'failed (error-message-string err)))))))

(defun elpet-chat-stop ()
  "Stop only this conversation's request, retaining the prompt for retry."
  (interactive)
  (elpet-chat--check)
  (when elpet-chat--active
    (elpet-chat--finish elpet-chat--active 'cancelled)
    (with-demoted-errors "Pet chat cancellation: %S"
      (gptel-abort (current-buffer)))))

(defun elpet-chat-retry ()
  "Retry the retained draft after a stopped or failed reply.
Edits to the draft are respected.  Incomplete replies are not model context."
  (interactive)
  (elpet-chat--check)
  (unless elpet-chat--last (user-error "There is no failed or stopped reply to retry"))
  (elpet-chat-send))

(defun elpet-chat-set-persona (persona)
  "Set the current conversation's PERSONA, leaving other chats unchanged."
  (interactive (list (read-string "Pet persona: " elpet-chat--persona)))
  (elpet-chat--check)
  (when elpet-chat--active (user-error "Stop the current reply before changing persona"))
  (setq elpet-chat--persona persona))

(defun elpet-chat-save (file)
  "Save completed turns, persona, and the draft to JSON FILE.
Backend configuration, credentials, and incomplete replies are not saved."
  (interactive "FSave pet conversation: ")
  (elpet-chat--check)
  (when elpet-chat--active (user-error "Stop the reply before saving this conversation"))
  (let ((data (json-encode
               `((schema-version . 1) (persona . ,elpet-chat--persona)
                 (turns . ,(vconcat elpet-chat--turns))
                 (draft . ,(elpet-chat--draft)))))
        (coding-system-for-write 'utf-8-unix))
    (write-region data nil file nil 'silent nil (called-interactively-p 'interactive))))

;;;###autoload
(defun elpet-chat-open (file)
  "Restore a pet conversation from JSON FILE using the current gptel setup."
  (interactive "fOpen pet conversation: ")
  (let* ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol)
         (data (json-read-file file))
         (turns (alist-get 'turns data))
         (persona (alist-get 'persona data)) (draft (alist-get 'draft data)))
    (unless (and (equal (alist-get 'schema-version data) 1)
                 (stringp persona) (stringp draft) (proper-list-p turns)
                 (cl-evenp (length turns)) (cl-every #'stringp turns))
      (user-error "Invalid pet conversation file"))
    (when (and (buffer-live-p elpet-chat--buffer)
               (buffer-local-value 'elpet-chat--active elpet-chat--buffer))
      (user-error "Stop the current reply before opening a conversation"))
    (when (and (called-interactively-p 'interactive)
               (buffer-live-p elpet-chat--buffer)
               (with-current-buffer elpet-chat--buffer
                 (or elpet-chat--turns (not (string-empty-p (elpet-chat--draft)))))
               (not (yes-or-no-p "Replace the current pet conversation? ")))
      (user-error "Conversation unchanged"))
    (elpet-chat)
    (with-current-buffer elpet-chat--buffer
      (setq elpet-chat--turns turns elpet-chat--persona persona
            elpet-chat--last nil)
      (elpet-chat--render draft))))

(defun elpet-chat--cleanup ()
  "Release this conversation's request and source when its buffer dies."
  (when elpet-chat--active
    ;; Also runs after the minor-mode variable has been cleared on disable.
    (elpet-chat--finish elpet-chat--active 'cancelled)
    (with-demoted-errors "Pet chat cancellation: %S" (gptel-abort (current-buffer))))
  (when elpet-chat--pet
    (elpet-unregister-source elpet-chat--source elpet-chat--pet))
  (setq elpet-chat--pet nil)
  (setq elpet-chat--buffers (delq (current-buffer) elpet-chat--buffers)))

(defun elpet-chat--pet-destroyed (pet)
  "Detach conversations from PET and invalidate their outstanding replies."
  (dolist (buffer elpet-chat--buffers)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq pet elpet-chat--pet)
          (elpet-chat-stop)
          (setq elpet-chat--pet nil))))))

(add-hook 'elpet--destroy-functions #'elpet-chat--pet-destroyed)

(provide 'elpet-chat)
;;; elpet-chat.el ends here
