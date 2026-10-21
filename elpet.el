;;; elpet.el --- An animated companion for Emacs -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: games, multimedia
;; Author: vritser
;; Maintainer: vritser
;; URL: https://github.com/vritser/elpet
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Load this file from the repository and run M-x elpet-mode.
;; GIF assets are bundled from PC2005-cloud/dsh-pet; no external runtime is needed.
;; The original artwork is noncommercial; see README.md for attribution.

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'compile)
(require 'svg)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'elpet-events)
(require 'elpet-assets)
(require 'elpet-render)
(require 'elpet-persist)
(require 'elpet-compilation)

;; `image-size' is unavailable in Emacs builds without image support, which
;; still compile the package for batch tests and non-graphical use.
(declare-function image-size "image" (spec &optional pixels frame))

(autoload 'elpet-chat "elpet-chat" nil t)
(autoload 'elpet-chat-open "elpet-chat" nil t)
(autoload 'elpet-install-pack "elpet-pack" nil t)

(defconst elpet-version "0.1.0"
  "Version of the loaded elpet package.")

(defconst elpet--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the package and its measured animation bounds.")

(defgroup elpet nil
  "An animated companion for Emacs."
  :group 'games :prefix "elpet-")

(defface elpet-bubble
  '((((background dark))
     (:foreground "#F3F1FA" :background "#30354C"
		  :box (:line-width 1 :color "#8589AC")))
    (t (:foreground "#403B55" :background "#FFF9F2"
		    :box (:line-width 1 :color "#B9ADC9"))))
  "Colors for the speech bubble above the pet."
  :group 'elpet)

(defcustom elpet-assets-directory
  (expand-file-name "assets/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory containing the original GIF animations."
  :type 'directory)

(defcustom elpet-display-type 'child-frame
  "Where to display the pet.  Use `window' if child frames are unavailable."
  :type '(choice (const child-frame) (const window)))

(defcustom elpet-width 220
  "Image width in pixels.  Re-enable the mode after changing this."
  :type 'natnum)

(defcustom elpet-trim-transparent-margins t
  "Trim measured transparent margins without changing the pet's scale.
Unknown or modified GIFs are displayed in full to avoid clipping artwork."
  :type 'boolean)

(defcustom elpet-margin 16
  "Distance in pixels from the parent's bottom right corner."
  :type 'natnum)

(defcustom elpet-sleep-delay 60
  "Seconds of inactivity before the pet sleeps."
  :type 'number)

(defcustom elpet-action-duration 10
  "Seconds between animation choices and duration of temporary reactions."
  :type 'number)

(defcustom elpet-follow-compilation t
  "Whether compilation processes drive the pet's working and result states."
  :type 'boolean)

(defconst elpet--labels
  '((idle . "陪你摸鱼") (sleeping . "打个盹…") (thinking . "让我想想…")
    (working . "一起加油！") (waiting . "等你回来") (success . "完成啦！")
    (error . "再试一次吧") (happy . "摸摸头～")))

(defvar elpet-mode nil)
(defvar elpet--last-display-error nil)

(defcustom elpet-pack-file (expand-file-name "pack.json" elpet--directory)
  "Data-only character pack manifest.  Set to nil for a legacy GIF directory."
  :type '(choice (const nil) file))

(defcustom elpet-reduced-motion nil
  "Show still frames and change actions only when the state changes."
  :type 'boolean)

(defcustom elpet-remember-position t
  "Restore the pet's normalized text-area position across mode toggles."
  :type 'boolean)

(defcustom elpet-state-file
  (locate-user-emacs-file "elpet/state.json")
  "JSON preference file, or nil to disable disk persistence."
  :type '(choice (const nil) file))

(defcustom elpet-history-limit 100
  "Maximum number of complete messages retained for the current instance."
  :type '(integer 1 10000))

(defcustom elpet-bubble-max-lines 8
  "Maximum bubble lines before scrolling, further limited by window space.
Short messages use only the height they need."
  :type '(integer 1 20))

(defvar elpet-view-mode-map (make-sparse-keymap)
  "Keymap for direct interactions with the pet.")

;; Update the existing map as well when reloading the package.
(let ((map elpet-view-mode-map))
  (define-key map (kbd "q") #'elpet-stop)
  (define-key map (kbd "SPC") #'elpet-pet)
  (define-key map (kbd "a") #'elpet-play)
  (define-key map (kbd "n") #'elpet-random-action)
  (define-key map (kbd "h") #'elpet-history)
  (define-key map (kbd "c") #'elpet-chat)
  (define-key map (kbd "r") #'elpet-reset-position)
  (dolist (event '(down-mouse-1 double-down-mouse-1 triple-down-mouse-1))
    (define-key map (vector event) #'elpet-drag))
  (define-key map [drag-mouse-1] #'ignore)
  (define-key map [mouse-1] #'elpet-pet)
  (define-key map [double-mouse-1] #'elpet-random-action)
  (define-key map [triple-mouse-1] #'elpet-random-action)
  (define-key map [mouse-3] #'elpet-menu)
  map)

(defvar elpet--click-action nil)

(defun elpet--bubble-click ()
  "Open the current bubble's associated conversation or perform a pet click."
  (interactive)
  (elpet--with-default
    (call-interactively (or elpet--bubble-action #'elpet-pet))))

(defun elpet--bubble-drag (event)
  "Drag the bubble with EVENT, opening its conversation on a stationary click."
  (interactive "e")
  (let ((elpet--click-action #'elpet--bubble-click))
    (elpet-drag event)))

(defvar elpet-bubble-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map elpet-view-mode-map)
    (define-key map [down-mouse-1] #'elpet--bubble-drag)
    (define-key map [mouse-1] #'elpet--bubble-click)
    (dolist (key '([wheel-down] [mouse-5]))
      (define-key map key #'elpet-bubble-next-lines))
    (dolist (key '([wheel-up] [mouse-4]))
      (define-key map key #'elpet-bubble-previous-lines))
    map))

(defun elpet--scroll-bubble (lines)
  "Scroll the current bubble by LINES without selecting its window."
  (elpet--with-default
    (when (and (buffer-live-p elpet--buffer) elpet--text)
      (elpet--wrap-text elpet--text)
      (let ((offset (max 0 (min (+ elpet--bubble-offset lines)
                                (- (length elpet--bubble-all-lines)
                                   (elpet--bubble-line-limit))))))
        (unless (= offset elpet--bubble-offset)
          (setq elpet--bubble-offset offset)
          ;; Give the reader time to inspect the message without adding history.
          (when-let* ((pet (elpet--resolve nil))
                      (message (elpet--best-message pet (elpet--now))))
            (setf (plist-get message :expires)
                  (max (plist-get message :expires) (+ (elpet--now) 20))))
          (elpet--draw))))))

(defun elpet-bubble-next-lines (&optional lines)
  "Show the next LINES of the speech bubble, defaulting to one."
  (interactive "p")
  (elpet--scroll-bubble (or lines 1)))

(defun elpet-bubble-previous-lines (&optional lines)
  "Show the previous LINES of the speech bubble, defaulting to one."
  (interactive "p")
  (elpet--scroll-bubble (- (or lines 1))))

(define-derived-mode elpet-view-mode special-mode "Pet"
  "Pet buffer: click or SPC to pet; double-click or n for a new action."
  (setq-local cursor-type nil
              mode-line-format nil
              header-line-format nil
              truncate-lines t
              line-spacing 0
              display-line-numbers nil
              show-trailing-whitespace nil
              left-fringe-width 0
              right-fringe-width 0)
  (add-hook 'kill-buffer-hook #'elpet-stop nil t))

(defun elpet--asset (name)
  "Return the current pack's file for animation NAME."
  (or (and elpet--pack
           (when-let* ((action (gethash name (elpet-pack-index elpet--pack))))
             (plist-get action :file)))
      (and elpet--pack (equal name "__fallback__")
           (elpet-pack-fallback elpet--pack))
      (expand-file-name (concat name ".gif") elpet-assets-directory)))

(defun elpet--choose (state)
  "Choose a weighted available STATE action, avoiding immediate repetition."
  (if elpet--pack
      (let ((choice (elpet--weighted-choice
                     (elpet--pack-actions elpet--pack state)
                     elpet--animation)))
        (if choice (plist-get choice :name) "__fallback__"))
    (let* ((pool (cl-remove-if-not
                  (lambda (name) (file-readable-p (elpet--asset name)))
                  (or (cdr (assq state elpet--animations))
                      (cdr (assq 'idle elpet--animations)))))
           (choices (or (remove elpet--animation pool) pool)))
      (unless choices
        (user-error "No GIF for %s in %s" state elpet-assets-directory))
      (nth (random (length choices)) choices))))

(defun elpet--stop-image ()
  "Cancel the current animation timer and release its image."
  (when elpet--image
    (let ((timer (image-animate-timer elpet--image)))
      (when timer (cancel-timer timer)))
    (setq elpet--image nil)))

(defun elpet--pause-animation ()
  "Pause the current image without discarding its frame."
  (when elpet--image
    (when-let* ((timer (image-animate-timer elpet--image))) (cancel-timer timer))))

(defun elpet--animation-loop-p ()
  "Return the current action's loop rule, defaulting to looping."
  (if-let* ((pack elpet--pack)
            (action (gethash elpet--animation (elpet-pack-index pack))))
      (plist-get action :loop)
    t))

(defun elpet--animation-ended-p ()
  "Return non-nil after the last frame of a non-looping action."
  (and elpet--image (not (elpet--animation-loop-p))
       (eq (plist-get (cdr elpet--image) :type) 'gif)
       (not (image-animate-timer elpet--image))
       (when-let* ((multi (image-multi-frame-p elpet--image)))
         (>= (image-current-frame elpet--image) (1- (car multi))))))

(defun elpet--resume-animation ()
  "Resume a visible GIF unless reduced motion is enabled."
  (when (and elpet--image (not elpet-reduced-motion)
             (eq (plist-get (cdr elpet--image) :type) 'gif)
             (not (image-animate-timer elpet--image))
             (not (elpet--animation-ended-p)))
    (with-current-buffer elpet--buffer
      (image-animate elpet--image (or (image-current-frame elpet--image) 0)
                     (elpet--animation-loop-p)))))

(defun elpet--crop (name)
  "Return verified, well-formed crop metadata for NAME, or nil."
  (when elpet-trim-transparent-margins
    (unless elpet--crop-data
      (setq elpet--crop-data
            (elpet--read-crops
             (if elpet--pack (elpet-pack-crops elpet--pack)
               (expand-file-name "crops.json" elpet--directory)))))
    (let* ((entry (gethash name elpet--crop-data))
           (size (and (hash-table-p entry) (gethash "size" entry)))
           (box (and (hash-table-p entry) (gethash "box" entry))))
      (when (and (proper-list-p size) (proper-list-p box)
                 (= (length size) 2) (= (length box) 4)
                 (cl-every (lambda (n) (and (integerp n) (> n 0))) size)
                 (cl-every (lambda (n) (and (integerp n) (>= n 0))) box)
                 (> (nth 2 box) 0) (> (nth 3 box) 0)
                 (<= (+ (nth 0 box) (nth 2 box)) (car size))
                 (<= (+ (nth 1 box) (nth 3 box)) (cadr size))
                 (equal (gethash "sha256" entry)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally (elpet--asset name))
                          (secure-hash 'sha256 (current-buffer)))))
        entry))))

(defun elpet--text-pixels (text)
  "Measure TEXT at the bubble's base font size."
  (if (not (display-graphic-p elpet--parent))
      (* 7 (string-width text))
    (string-pixel-width (propertize text 'face '(:height 140)))))

(defun elpet--docking-window ()
  "Return the editing window containing or docking the pet."
  (let ((windows (cl-remove elpet--window (window-list elpet--parent 'nomini))))
    (or (and elpet--manual-position
             (cl-find-if (lambda (window)
                           (pcase-let ((`(,left ,top ,right ,bottom)
                                        (window-inside-pixel-edges window)))
                             (and (<= left (car elpet--manual-position) right)
                                  (<= top (cdr elpet--manual-position) bottom)))) windows))
        (car (sort windows (lambda (a b)
                             (let ((a (window-pixel-edges a)) (b (window-pixel-edges b)))
                               (if (= (nth 2 a) (nth 2 b))
                                   (> (nth 3 a) (nth 3 b))
                                 (> (nth 2 a) (nth 2 b))))))))))

(defun elpet--bubble-line-limit ()
  "Return the number of bubble lines that fit comfortably in the parent."
  (if (not (and (frame-live-p elpet--parent)
                (display-graphic-p elpet--parent)))
      elpet-bubble-max-lines
    (let* ((window (elpet--docking-window))
           (height (if window (window-body-height window t)
                     (frame-pixel-height elpet--parent)))
           (scale (/ elpet-width 220.0))
           (sprite (or elpet--sprite-height (ceiling (* 124 scale))))
           (available (min (* height 0.45)
                           (- height sprite (* 2 elpet-margin)
                              (frame-char-height elpet--parent)))))
      (max 1 (min elpet-bubble-max-lines
                  (1+ (floor (/ (- available (* 46 scale)) (* 22 scale)))))))))

(defun elpet--text-lines (text)
  "Wrap all of TEXT to the bubble's text width."
  (let ((lines nil) (line "") break)
    (dolist (character (string-to-list (substring-no-properties text)))
      (let ((next (concat line (char-to-string character))))
        (cond ((eq character ?\n) (push (string-trim-right line) lines) (setq line "" break nil))
              ((and (> (length line) 0) (> (elpet--text-pixels next) 180))
               (cond
                ((memq character '(?\s ?\t))
                 (push (string-trim-right line) lines) (setq line ""))
                ((and break (> break 0))
                 (push (string-trim-right (substring line 0 break)) lines)
                 (setq line (string-trim-left (substring next (1+ break)))))
                (t (push (string-trim-right line) lines)
                   (setq line (char-to-string character)))))
              (t (setq line next)))
        (setq break (cl-position-if (lambda (c) (memq c '(?\s ?\t))) line :from-end t))))
    (push line lines)
    (nreverse lines)))

(defun elpet--wrap-text (text)
  "Return the visible, scrollable slice of TEXT's wrapped lines."
  (let ((key (list text elpet-width
                   (and (frame-live-p elpet--parent)
                        (frame-parameter elpet--parent 'font)))))
    (unless (equal key elpet--bubble-wrap-key)
      ;; Preserve a reader's position as streaming text grows.
      (unless (and elpet--bubble-wrap-key
                   (string-prefix-p (car elpet--bubble-wrap-key) text))
        (setq elpet--bubble-offset 0))
      (setq elpet--bubble-wrap-key key
            elpet--bubble-all-lines (elpet--text-lines text)
            elpet--bubble-max-width
            (apply #'max 0 (mapcar #'elpet--text-pixels
                                   elpet--bubble-all-lines)))))
  (let ((limit (elpet--bubble-line-limit)))
    (setq elpet--bubble-offset
          (max 0 (min elpet--bubble-offset
                      (- (length elpet--bubble-all-lines) limit))))
    (let ((lines (seq-take (nthcdr elpet--bubble-offset elpet--bubble-all-lines)
                           limit)))
      (when (< (+ elpet--bubble-offset (length lines))
               (length elpet--bubble-all-lines))
        (let ((last (car (last lines))))
          (while (and (> (length last) 0)
                      (> (elpet--text-pixels (concat last "…")) 180))
            (setq last (if (string-match "[ \t]+[^ \t]+\\'" last)
                           (substring last 0 (match-beginning 0))
                         (substring last 0 -1))))
          (setcar (last lines) (concat last "…"))))
      lines)))

(defun elpet--layout (name text)
  "Compute compact image and multiline bubble dimensions for NAME and TEXT."
  (setq elpet--image-slice nil elpet--sprite-height nil
        elpet--sprite-width elpet-width
        elpet--display-width elpet-width)
  (when-let* ((crop (elpet--crop name)))
    (pcase-let* ((`(,width ,height) (gethash "size" crop))
                 (`(,x ,y ,w ,h) (gethash "box" crop))
                 (scale (/ (float elpet-width) width)))
      (setq elpet--image-slice
            (list (/ (float x) width) (/ (float y) height)
                  (/ (float w) width) (/ (float h) height))
            elpet--sprite-width (ceiling (* w scale))
            elpet--sprite-height (ceiling (* h scale)))))
  (setq elpet--bubble-lines (elpet--wrap-text text))
  (when elpet--sprite-height
    (setq elpet--display-width
          (max elpet--sprite-width
               (ceiling (* (+ 4 (max 88 (+ 28 elpet--bubble-max-width)))
                           (/ elpet-width 220.0)))))))

(defun elpet--bubble-svg (text)
  "Build a rounded multiline speech bubble containing a preview of TEXT."
  (let* ((lines (or elpet--bubble-lines (elpet--wrap-text text)))
         (body (+ 32 (* 22 (1- (length lines)))))
         (height (ceiling (* (+ body 14) (/ elpet-width 220.0))))
         (canvas (or elpet--display-width elpet-width))
         (view-width (* canvas (/ 220.0 elpet-width)))
         (center (/ view-width 2))
         (svg (svg-create canvas height
                          :viewBox (format "0 0 %s %s" view-width (+ body 14))))
         (width (min (- view-width 4)
                     (max 88 (+ 28 elpet--bubble-max-width))))
         (left (/ (- view-width width) 2.0))
         (right (+ left width))
         (outline
          (format
           (concat "M %s 2 H %s Q %s 2 %s 13 V %s Q %s %s %s %s "
                   "H %s C %s %s %s %s %s %s Q %s %s %s %s "
                   "C %s %s %s %s %s %s H %s Q %s %s %s %s V 13 Q %s 2 %s 2 Z")
           (+ left 11) (- right 11) right right (- body 11)
           right body (- right 11) body
           (+ center 7) (+ center 5) body (+ center 3) (+ body 4)
           (+ center 1) (+ body 6) center (+ body 7) (- center 1) (+ body 6)
           (- center 3) (+ body 4) (- center 5) body (- center 7) body
           (+ left 11) left body left (- body 11) left (+ left 11)))
         (background (face-background 'elpet-bubble elpet--parent t))
         (foreground (face-foreground 'elpet-bubble elpet--parent t))
         (border (plist-get (face-attribute 'elpet-bubble :box elpet--parent t) :color)))
    (svg-node svg 'path :d outline :transform "translate(0 2)"
              :fill "#101322" :opacity 0.06 :stroke "#101322" :stroke-width 1)
    (svg-node svg 'path :d outline :transform "translate(0 1)" :fill "#101322" :opacity 0.08)
    (svg-node svg 'path :d outline :fill background :stroke border
              :stroke-opacity 0.72 :stroke-width 0.8)
    (cl-loop for line in lines for index from 0 do
             (svg-text svg line :x (+ left 14) :y (+ 22 (* index 22)) :text-anchor "start"
                       :font-size 14 :font-weight 400
                       :font-family "PingFang SC, Microsoft YaHei, Noto Sans CJK SC, sans-serif"
                       :fill foreground))
    (when (> (length elpet--bubble-all-lines) (length lines))
      (let* ((track (- body 20))
             (thumb (max 6 (* track (/ (float (length lines))
                                      (length elpet--bubble-all-lines)))))
             (top (+ 11 (* (- track thumb)
                           (/ (float elpet--bubble-offset)
                              (- (length elpet--bubble-all-lines) (length lines)))))))
        (svg-rectangle svg (- right 6) 11 2 track :rx 1 :fill foreground :opacity 0.15)
        (svg-rectangle svg (- right 6) top 2 thumb :rx 1 :fill foreground :opacity 0.6)))
    svg))

(defun elpet--bubble-image (text)
  "Render TEXT, asynchronously upgrading SVG to PNG when possible."
  (let* ((svg (elpet--bubble-svg text))
         (source (with-temp-buffer (svg-print svg) (buffer-string)))
         (converter (and (eq window-system 'ns) (image-type-available-p 'png)
                         (executable-find "rsvg-convert")))
         (key (cons converter source))
         (cached (gethash key elpet--bubble-images)))
    (or cached
        (let ((image (svg-image svg :ascent 100 :scale 1 :mask 'heuristic)))
          (when (>= (hash-table-count elpet--bubble-images) 32)
            (clrhash elpet--bubble-images))
          (puthash key image elpet--bubble-images)
          (when (and converter elpet--current-view elpet--default-instance)
            (elpet--convert-bubble converter source key))
          image))))

(defun elpet--convert-bubble (converter source key)
  "Convert SOURCE with CONVERTER asynchronously, caching the result under KEY."
  (when (process-live-p elpet--bubble-process)
    (delete-process elpet--bubble-process))
  (let* ((pet elpet--default-instance)
         (generation (elpet-instance-generation pet))
         (view elpet--current-view)
         (width (or elpet--display-width elpet-width))
         (output (generate-new-buffer " *pet-png*"))
         (errors (generate-new-buffer " *pet-png-errors*")))
    (with-current-buffer output (set-buffer-multibyte nil))
    (condition-case err
        (progn
          (setq elpet--bubble-process
                (make-process
                 :name "elpet-bubble" :buffer output :stderr errors
                 :command (list converter "--format=png" "--zoom=2")
                 :connection-type 'pipe :coding '(binary . utf-8-unix) :noquery t
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (unwind-protect
                         (when (and (elpet-instance-alive pet)
                                    (= generation (elpet-instance-generation pet))
                                    (eq process (if (eq view elpet--current-view) elpet--bubble-process
                                                  (elpet-view-bubble-process view)))
                                    (zerop (process-exit-status process)))
                           (condition-case failure
                               (let ((image (create-image
                                             (with-current-buffer output (buffer-string))
                                             'png t :width width :ascent 100 :scale 1)))
                                 (puthash key image (elpet-view-bubble-images view))
                                 (if (eq view elpet--current-view) (setq elpet--dirty t)
                                   (setf (elpet-view-dirty view) t)))
                             (error (setf (elpet-view-last-error view)
                                          (error-message-string failure)))))
                       (when (buffer-live-p output) (kill-buffer output))
                       (when (buffer-live-p errors) (kill-buffer errors)))))))
          (process-send-string elpet--bubble-process source)
          (process-send-eof elpet--bubble-process))
      (error
       (setq elpet--last-error (error-message-string err))
       (when (buffer-live-p output) (kill-buffer output))
       (when (buffer-live-p errors) (kill-buffer errors))))))

(defun elpet--insert-bubble (text)
  "Insert the preview of TEXT and record its pixel height."
  (setq elpet--bubble-lines (or elpet--bubble-lines (elpet--wrap-text text)))
  (if (image-type-available-p 'svg)
      (progn
        (setq elpet--bubble-height
              (ceiling (* (+ 46 (* 22 (1- (length elpet--bubble-lines))))
                          (/ elpet-width 220.0))))
        (insert-image (elpet--bubble-image text) text)
        (insert "\n"))
    (let* ((columns (max 1 (/ (or elpet--display-width elpet-width)
                              (frame-char-width))))
           (padding (max 0 (/ (- columns 2 (apply #'max
                                                  (mapcar #'string-width elpet--bubble-all-lines)))
                              2))))
      (dolist (line elpet--bubble-lines)
        (insert (make-string padding ?\s)
                (propertize (concat " " line " ") 'face 'elpet-bubble) "\n"))
      (insert (make-string (max 0 (/ (1- columns) 2)) ?\s) "▾\n")
      (setq elpet--bubble-height
            (* (1+ (length elpet--bubble-lines)) (frame-char-height))))))

(defun elpet--resize ()
  "Fit the child frame to the speech bubble and current animation."
  (when (frame-live-p elpet--frame)
    ;; With no right fringe, redisplay reserves a character column for
    ;; end-of-line/truncation glyphs, even when the cursor is hidden.
    ;; Keep that column outside the image canvas or its right edge is cut.
    (let ((frame-resize-pixelwise t))
      (set-frame-size elpet--frame
                      (+ (or elpet--display-width elpet-width)
                         (frame-char-width elpet--frame))
                      (+ elpet--bubble-height
                         (or elpet--sprite-height
                             (ceiling (cdr (image-size elpet--image t))))
                         (frame-char-height elpet--frame)) t))
    (elpet--position)))

(defun elpet--play (state &optional name)
  "Display STATE using NAME, with static and missing-asset fallbacks."
  (let* ((name (or name (elpet--choose state)))
         (message (and (elpet--resolve nil)
                       (elpet--best-message elpet--default-instance (elpet--now))))
         (text (or (plist-get message :text) (alist-get state elpet--labels) "陪着你"))
         (file (elpet--asset name))
         (image (if (equal (downcase (or (file-name-extension file) "")) "gif")
                    (create-image file 'gif nil :width elpet-width :ascent 'center :scale 1)
                  (create-image file nil nil :width elpet-width :ascent 'center :scale 1))))
    (unless image (error "Unable to load animation %s" name))
    (elpet--stop-image)
    (elpet--layout name text)
    (unless message (elpet--record-status text))
    (setq elpet--state state elpet--animation name elpet--image image
          elpet--text text elpet--bubble-action (plist-get message :action)
          elpet--dirty nil
          elpet--next-action (+ (elpet--now) elpet-action-duration))
    (elpet--draw)
    (when (and (not elpet-reduced-motion)
               (or (null elpet--default-instance) (elpet--display-visible-p))
               (eq (plist-get (cdr image) :type) 'gif))
      (elpet--resume-animation))))

(defun elpet--draw ()
  "Redraw the current bubble and image without restarting animation."
  (when (buffer-live-p elpet--buffer)
    (elpet--layout elpet--animation elpet--text)
    (with-current-buffer elpet--buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (elpet--insert-bubble elpet--text)
        (let ((bubble-end (point))
              (padding (/ (- elpet--display-width elpet--sprite-width) 2)))
          (when (> padding 0)
            (insert (propertize " " 'display `(space :width (,padding)))))
          (insert-image elpet--image elpet--animation nil elpet--image-slice)
          (add-text-properties (point-min) (point-max)
                               (list 'keymap elpet-view-mode-map 'mouse-face nil 'help-echo nil))
          (add-text-properties
           (point-min) bubble-end
           (list 'keymap elpet-bubble-mode-map
                 'help-echo
                 (format "Scroll to read (lines %d–%d of %d). %s"
                         (1+ elpet--bubble-offset)
                         (+ elpet--bubble-offset (length elpet--bubble-lines))
                         (length elpet--bubble-all-lines)
                         (if elpet--bubble-action "Click to open the conversation."
                           "Click to pet.")))))
        (goto-char (point-min))))
    (elpet--resize)))

(defun elpet--effective-state (now idle-seconds)
  "Resolve the state at NOW given IDLE-SECONDS of user inactivity."
  (if (elpet--resolve nil)
      (elpet--reduce elpet--default-instance now idle-seconds elpet-sleep-delay)
    ;; Keep the internal helper usable by existing callers and baseline tests.
    (when (and elpet--override (<= (cdr elpet--override) now))
      (setq elpet--override nil))
    (cond (elpet--override (car elpet--override))
          ((and elpet-follow-compilation elpet--compilations) 'working)
          ((>= idle-seconds elpet-sleep-delay) 'sleeping) (t 'idle))))

(defun elpet--position ()
  "Place the pet inside a text area, keeping mode lines unobstructed."
  (when (and (frame-live-p elpet--frame) (frame-live-p elpet--parent))
    (let* ((window (elpet--docking-window))
           (width (frame-pixel-width elpet--frame))
           (height (frame-pixel-height elpet--frame))
           (areas (mapcar #'window-inside-pixel-edges (window-list elpet--parent 'nomini)))
           (restored (and (not elpet--manual-position) elpet--position-data
                          (elpet--restore-position elpet--position-data areas width height)))
           (position
            (if (or elpet--manual-position restored)
                (elpet--nearest-position
                 (or elpet--manual-position restored) areas width height)
              (elpet--fit-position (window-inside-pixel-edges window)
                                       width height))))
      (if (not position)
          ;; Do not cover another window's mode line when the pane is tiny.
          (progn (make-frame-invisible elpet--frame t) (elpet--pause-animation))
        (set-frame-position elpet--frame (car position) (cdr position))
        (when (and (not elpet--hidden) (eq (frame-visible-p elpet--parent) t)
                   (not (frame-visible-p elpet--frame)))
          (save-selected-window (make-frame-visible elpet--frame)))
        (unless elpet--hidden (elpet--resume-animation))))))

(defun elpet--fit-position (edges width height)
  "Fit WIDTH by HEIGHT inside text-area EDGES, or return nil if too small."
  (pcase-let ((`(,left ,top ,right ,bottom) edges))
    (when (and (<= width (- right left)) (<= height (- bottom top)))
      (cons (max left (- right width elpet-margin))
            (max top (- bottom height elpet-margin))))))

(defun elpet--window-size-change (frame)
  "Reposition immediately when the parent FRAME's window layout changes."
  (elpet--with-default
   (when (and elpet-mode (eq frame elpet--parent))
     (setq elpet--dirty t)
     (when elpet--position-data (setq elpet--manual-position nil))
     (elpet--position))))

(defun elpet--nearest-position (desired areas width height)
  "Clamp DESIRED to the nearest of text AREAS fitting WIDTH and HEIGHT."
  (let (best distance)
    (dolist (edges areas best)
      (pcase-let ((`(,left ,top ,right ,bottom) edges))
        (when (and (<= width (- right left)) (<= height (- bottom top)))
          (let* ((x (max left (min (car desired) (- right width))))
                 (y (max top (min (cdr desired) (- bottom height))))
                 (d (+ (expt (- x (car desired)) 2)
                       (expt (- y (cdr desired)) 2))))
            (when (or (null distance) (< d distance))
              (setq best (cons x y) distance d))))))))

(defun elpet-drag (event)
  "Drag the floating pet with mouse EVENT, or handle a stationary click.
Screen pixel coordinates avoid a changing origin as the child moves.
Side-window mode uses normal click bindings and cannot be dragged."
  (interactive "e")
  (elpet--with-default
   (when (frame-live-p elpet--frame)
     (let ((start (mouse-absolute-pixel-position))
           (origin (cons (frame-parameter elpet--frame 'left)
                         (frame-parameter elpet--frame 'top)))
           (elpet--dragging t)
           moved done next)
       (when (and (numberp (car start)) (numberp (cdr start)))
         (track-mouse
           (while (not done)
             (setq next (read-event))
             (cond
              ((or (eq (car-safe next) 'mouse-movement)
                   (and (consp next) (eq (event-basic-type next) 'mouse-1)))
               (let ((point (mouse-absolute-pixel-position)))
                 (when (and (numberp (car point)) (numberp (cdr point))
                            (frame-live-p elpet--frame))
                   (let ((dx (- (car point) (car start)))
                         (dy (- (cdr point) (cdr start))))
                     ;; Small hand movements still count as clicks.
                     (when (or moved (>= (+ (* dx dx) (* dy dy)) 16))
                       (setq moved t
                             elpet--manual-position
                             (cons (+ (car origin) dx) (+ (cdr origin) dy)))
                       (elpet--position)))))
               (unless (eq (car-safe next) 'mouse-movement)
                 (setq done t)
                 (unless moved
                   (if (or (memq 'double (event-modifiers event))
                           (memq 'triple (event-modifiers event)))
                       (elpet-random-action)
                     (funcall (or elpet--click-action #'elpet-pet))))))
              ;; Crossing frames must not change the editing window.
              ((eq (car-safe next) 'switch-frame))
              (t
               (setq done t)
               (push next unread-command-events))))))))
   (elpet--save-position)))

(defun elpet-reset-position ()
  "Return the pet to automatic docking and forget its saved position."
  (interactive)
  (elpet--with-default
   (setq elpet--manual-position nil elpet--position-data nil)
   (elpet--position)
   (elpet--save-preferences)))

(defun elpet--tick ()
  "Update the display from current facts, without accepting stale callbacks."
  (elpet--with-default
   (when elpet-mode
     (condition-case err
         (if (not (and (buffer-live-p elpet--buffer)
                       (frame-live-p elpet--parent)
                       (or elpet--hidden
                           (and (window-live-p elpet--window)
                                (eq (window-buffer elpet--window) elpet--buffer)))))
             (elpet-stop)
           (when (and elpet-reduced-motion elpet--image)
             (when-let* ((timer (image-animate-timer elpet--image))) (cancel-timer timer)))
           (when (or elpet--hidden
                     (not (eq (frame-visible-p elpet--parent) t)))
             (when (elpet--resolve nil)
               (maphash (lambda (_ request)
                          (when (eq (plist-get request :status) 'playing)
                            (elpet--transition elpet--default-instance request 'cancelled)))
                        (elpet-instance-requests elpet--default-instance))))
           (elpet--reconcile-compilations)
           (when (elpet--animation-ended-p)
             (when-let* ((request (elpet--current-request)))
               (when (eq (plist-get request :status) 'playing)
                 (elpet--transition elpet--default-instance request 'finished))))
           (let* ((idle (current-idle-time))
                  (now (elpet--now))
                  (state (elpet--effective-state now (if idle (float-time idle) 0)))
                  (message (and (elpet--resolve nil)
                                (elpet--best-message elpet--default-instance now)))
                  (text (or (plist-get message :text) (alist-get state elpet--labels)))
                  (visible (and (not elpet--hidden)
                                (eq (frame-visible-p elpet--parent) t)))
                  (request (elpet--current-request))
                  (name (and request (plist-get request :animation))))
             (cond
              ((not visible)
               (elpet--stop-image)
               (when (frame-live-p elpet--frame) (make-frame-invisible elpet--frame t)))
              ((not elpet--dragging)
               (when (or (not elpet--image) (not (eq state elpet--state))
                         (and request (not (plist-get request :rendered)))
                         (and name (not (equal name elpet--animation)))
                         (and (not elpet-reduced-motion) (not request)
                              (>= now elpet--next-action)))
                 (elpet--play state name)
                 (when request (setf (plist-get request :rendered) t
                                     (plist-get request :actual-animation) elpet--animation)))
               (when (or elpet--dirty (not (equal text elpet--text))
                         (not (eq (plist-get message :action) elpet--bubble-action))
                         (not (equal (elpet--theme-key) elpet--pending-bubble)))
                 (unless message (elpet--record-status text))
                 (setq elpet--text text elpet--dirty nil
                       elpet--bubble-action (plist-get message :action)
                       elpet--pending-bubble (elpet--theme-key))
                 (elpet--draw))
               (elpet--position)
               (when (and request (elpet--display-visible-p)
                          (eq (plist-get request :status) 'accepted))
                 (elpet--transition elpet--default-instance request 'playing))))))
       (error
        (setq elpet--last-error (error-message-string err)
              elpet--last-display-error elpet--last-error)
        (when (elpet--resolve nil)
          (maphash (lambda (_ request)
                     (when (memq (plist-get request :status) '(accepted playing))
                       (elpet--transition elpet--default-instance request 'failed)))
                   (elpet-instance-requests elpet--default-instance)))
        (elpet-stop)
        (message "elpet stopped: %s" (error-message-string err)))))))

(defun elpet--current-request ()
  "Return the newest live playback request for the default instance."
  (when (elpet--resolve nil)
    (let ((request (elpet--best-request elpet--default-instance)))
      (and request (eq (plist-get request :state)
                       (elpet--effective-state (elpet--now) 0)) request))))

(defun elpet--display-visible-p ()
  "Return non-nil when the pet can actually be displayed."
  (and (not elpet--hidden)
       (if elpet--frame (eq (frame-visible-p elpet--frame) t)
         (window-live-p elpet--window))))

(defun elpet--theme-key ()
  "Return the current bubble colors and scale for cache invalidation."
  (list elpet-width
        (face-background 'elpet-bubble elpet--parent t)
        (face-foreground 'elpet-bubble elpet--parent t)
        (face-attribute 'elpet-bubble :box elpet--parent t)
        (frame-char-height elpet--parent)))

;;;###autoload
(defun elpet-set-state (state &optional seconds)
  "Show STATE for SECONDS, defaulting to `elpet-action-duration'.
With the mode disabled this is a no-op.  Return a cancellable playback ID."
  (interactive
   (list (intern (completing-read "Pet state: " elpet--animations nil t))))
  (unless (memq state elpet--states) (user-error "Unknown pet state: %s" state))
  (when elpet-mode
    (elpet--with-default
     (if (elpet--resolve nil)
         (let ((id (elpet--request elpet--default-instance state
                                       (or seconds elpet-action-duration))))
           (elpet--tick)
           id)
       (elpet--play state)
       (setq elpet--override
             (cons state (+ (elpet--now) (or seconds elpet-action-duration))))))))

(defun elpet-pet ()
  "Give the pet some attention."
  (interactive)
  (elpet-set-state 'happy))

(defun elpet-random-action ()
  "Play another available idle activity without opening a menu."
  (interactive)
  (elpet-set-state 'idle))

(defun elpet--action-names ()
  "Return names of readable actions in the current pack or GIF directory."
  (if elpet--pack
      (let (names)
        (maphash (lambda (name action)
                   (when (file-readable-p (plist-get action :file))
                     (push name names)))
                 (elpet-pack-index elpet--pack))
        (sort (delete-dups names) #'string<))
    (mapcar #'file-name-base (directory-files elpet-assets-directory nil "\\.gif\\'"))))

(defun elpet-play (name &optional pet seconds)
  "Request animation NAME in PET for SECONDS and return a playback ID.
Interactively, select an available animation for the default displayed pet."
  (interactive (elpet--with-default
                (list (completing-read "Animation: " (elpet--action-names) nil t))))
  (let ((instance (elpet--resolve pet)))
    (unless (or instance elpet-mode) (user-error "Enable elpet-mode first"))
    (elpet--with-default
     (unless (member name (elpet--action-names))
       (user-error "Unknown animation: %s" name))
     (if instance
         (let ((id (elpet--request instance 'happy
                                       (or seconds elpet-action-duration) name)))
           (when (eq instance elpet--default-instance) (elpet--tick))
           id)
       (elpet--play 'happy name)
       (setq elpet--override (cons 'happy elpet--next-action))))))

(defun elpet-menu (event)
  "Show the pet's context menu at mouse EVENT."
  (interactive "e")
  (let ((choice (x-popup-menu
                 event '("Elpet" ("Pet" ("摸摸头" . happy)
                                  ("想一想" . thinking)
                                  ("打个盹" . sleeping)
                                  ("Chat" . chat)
                                  ("关闭宠物" . stop))))))
    (when choice
      (pcase choice
        ('stop (elpet-stop))
        ('chat (elpet-chat))
        (_ (elpet-set-state choice))))))

(defun elpet--frame-deleted (frame)
  "Clean up when the pet or its parent FRAME is deleted."
  (elpet--with-default
   (when (memq frame (list elpet--frame elpet--parent))
     ;; The frame's deletion is already in progress; do not delete it again.
     (setq elpet--frame nil)
     (elpet-stop))))

(defun elpet--cleanup ()
  "Release all timers, hooks, processes, and display resources."
  (remove-hook 'kill-emacs-hook #'elpet--save-default-preferences)
  (remove-hook 'compilation-start-hook #'elpet--compilation-start)
  (remove-hook 'compilation-finish-functions #'elpet--compilation-finish)
  (remove-hook 'delete-frame-functions #'elpet--frame-deleted)
  (remove-hook 'window-size-change-functions #'elpet--window-size-change)
  (when elpet--unsubscribe (funcall elpet--unsubscribe))
  (setq elpet--unsubscribe nil)
  (when (timerp elpet--timer) (cancel-timer elpet--timer))
  (setq elpet--timer nil)
  (when (process-live-p elpet--bubble-process) (delete-process elpet--bubble-process))
  (setq elpet--bubble-process nil)
  (elpet--stop-image)
  ;; Clear references before deleting frames; deletion hooks can reenter cleanup.
  (let ((frame elpet--frame) (window elpet--window) (buffer elpet--buffer))
    (setq elpet--frame nil elpet--window nil elpet--buffer nil)
    (when (frame-live-p frame) (delete-frame frame t))
    (when (and (window-live-p window) (window-parameter window 'window-side))
      (delete-window window))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (remove-hook 'kill-buffer-hook #'elpet-stop t))
      (kill-buffer buffer)))
  (clrhash elpet--bubble-images)
  (setq elpet--parent nil elpet--state nil elpet--override nil
        elpet--animation nil elpet--compilations nil elpet--bubble-height 0
        elpet--bubble-max-width 0
        elpet--manual-position nil elpet--image-slice nil
        elpet--sprite-height nil elpet--sprite-width nil elpet--display-width nil))

(defun elpet--destroy-display (pet)
  "Release the display owned by invalidated PET."
  (when (elpet-instance-view pet)
    (if (eq elpet--current-view (elpet-instance-view pet)) (elpet--cleanup)
      (elpet--with-view (elpet-instance-view pet) (elpet--cleanup))))
  (when (eq pet elpet--default-instance) (setq elpet-mode nil)))

(add-hook 'elpet--destroy-functions #'elpet--destroy-display)

(defun elpet--start ()
  "Create the pet's display and start its timers."
  (unless (and (display-graphic-p) (image-type-available-p 'gif))
    (user-error "The pet needs graphical Emacs with GIF support"))
  (unless (and (> elpet-width 0) (> elpet-action-duration 0)
               (>= elpet-sleep-delay 0) (>= elpet-margin 0))
    (user-error "Invalid elpet size, margin or timing settings"))
  (unless (and (integerp elpet-history-limit) (> elpet-history-limit 0)
               (integerp elpet-bubble-max-lines) (> elpet-bubble-max-lines 0))
    (user-error "Invalid history or bubble line limit"))
  (elpet--restore-preferences)
  (setq elpet--pack
        (and elpet-pack-file
             ;; Honor the original asset-directory option for existing setups.
             (or (not (equal (expand-file-name elpet-pack-file)
                             (expand-file-name "pack.json" elpet--directory)))
                 (equal (file-truename elpet-assets-directory)
                        (file-truename (expand-file-name "assets/" elpet--directory))))
             (elpet-load-pack elpet-pack-file)))
  (setf (elpet-instance-pack elpet--default-instance) elpet--pack)
  (elpet-register-source "compilation" nil elpet--default-instance)
  (elpet--choose 'idle)
  (setq elpet--parent (selected-frame)
        elpet--buffer (generate-new-buffer " *elpet*"))
  (with-current-buffer elpet--buffer (elpet-view-mode))
  (pcase elpet-display-type
    ('child-frame
     (setq elpet--frame
           (condition-case nil
               (make-frame
                `((parent-frame . ,elpet--parent) (minibuffer . nil)
		  (name . "elpet") (undecorated . t) (no-accept-focus . t)
		  (no-focus-on-map . t) (no-other-frame . t)
		  (skip-taskbar . t) (desktop-dont-save . t)
		  (visibility . nil) (border-width . 0) (internal-border-width . 0)
		  (left-fringe . 0) (right-fringe . 0) (menu-bar-lines . 0)
		  (tool-bar-lines . 0) (tab-bar-lines . 0)
		  (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
		  (width . 28) (height . 9) (min-width . 1) (min-height . 1)
		  (background-color . ,(face-background 'default elpet--parent t))))
             (error nil)))
     ;; This symbol is installed by the NS frame-transparency C patch.
     ;; Use a string for detection so loading this file does not intern it.
     (when (and elpet--frame (eq window-system 'ns) (intern-soft "ns-alpha-glyphs"))
       (modify-frame-parameters
        elpet--frame
        '((alpha-background . 0) (ns-background-blur . 0)
          (ns-alpha-elements . (ns-alpha-all)))))
     (if elpet--frame
         (progn
           (setq elpet--window (frame-root-window elpet--frame))
           (set-window-buffer elpet--window elpet--buffer)
           (set-window-parameter elpet--window 'mode-line-format 'none)
           (set-window-parameter elpet--window 'header-line-format 'none)
           (set-window-parameter elpet--window 'no-other-window t))
       (setq elpet--window
             (display-buffer-in-side-window
              elpet--buffer '((side . right) (slot . 0) (window-width . 30))))))
    ('window
     (setq elpet--window
           (display-buffer-in-side-window
            elpet--buffer '((side . right) (slot . 0) (window-width . 30)))))
    (_ (user-error "Unknown elpet-display-type: %s" elpet-display-type)))
  (set-window-dedicated-p elpet--window t)
  (elpet--play 'idle)
  (add-hook 'kill-emacs-hook #'elpet--save-default-preferences)
  (add-hook 'compilation-start-hook #'elpet--compilation-start)
  (add-hook 'compilation-finish-functions #'elpet--compilation-finish)
  (add-hook 'delete-frame-functions #'elpet--frame-deleted)
  (add-hook 'window-size-change-functions #'elpet--window-size-change)
  (let* ((pet elpet--default-instance)
         (generation (elpet-instance-generation pet))
         (view elpet--current-view))
    (setq elpet--unsubscribe
          (elpet-subscribe
           (lambda (_event)
             (when (and (elpet-instance-alive pet)
                        (= generation (elpet-instance-generation pet)))
               (if (eq view elpet--current-view) (setq elpet--dirty t)
                 (setf (elpet-view-dirty view) t)))) pet))
    (setq elpet--timer
          (run-at-time 1 1
                       (lambda ()
                         (when (and (elpet-instance-alive pet)
                                    (= generation (elpet-instance-generation pet)))
                           (elpet--tick)))))))

;;;###autoload
(define-minor-mode elpet-mode
  "Toggle the animated Emacs companion.
The pet belongs to the frame selected when enabled.  No DSH server,
Electron or network connection is required."
  :global t :group 'elpet
  (let ((enable elpet-mode))
    (if elpet--default-instance
        (progn
          (elpet--with-default (elpet--save-preferences))
          (elpet-destroy elpet--default-instance))
      (elpet--cleanup))
    (setq elpet-mode enable)
    (when enable
      (condition-case err
          (progn
            (setq elpet--default-instance (elpet-create))
            (setf (elpet-instance-view elpet--default-instance) (elpet--make-view))
            (elpet--with-default (save-selected-window (elpet--start))))
        (error
         (setq elpet--last-display-error (error-message-string err))
         (elpet-destroy elpet--default-instance)
         (setq elpet-mode nil)
         (signal (car err) (cdr err)))))))

(defun elpet-stop ()
  "Disable the pet and release its resources."
  (interactive)
  (elpet-mode -1))

(defun elpet--save-position ()
  "Remember the current position as a normalized text-area offset."
  (when (and elpet-remember-position elpet--manual-position
             (frame-live-p elpet--frame) (frame-live-p elpet--parent))
    (let* ((areas (mapcar #'window-inside-pixel-edges
                          (window-list elpet--parent 'nomini)))
           (width (frame-pixel-width elpet--frame))
           (height (frame-pixel-height elpet--frame))
           (fitted (elpet--nearest-position elpet--manual-position areas width height))
           (index (and fitted (cl-position-if
			       (lambda (area)
				 (equal fitted (elpet--nearest-position fitted (list area) width height)))
			       areas))))
      (when index
        (setq elpet--position-data
              (append (elpet--position-record fitted (nth index areas) width height)
                      (list :pane index)))))))

(defun elpet--save-default-preferences ()
  "Save the default display's preferences before Emacs exits."
  (elpet--with-default (elpet--save-preferences)))

(defun elpet--save-preferences ()
  "Persist display preferences when a real default instance exists."
  (when (and elpet--default-instance elpet--parent)
    (elpet--save-position)
    (elpet--write-preferences
     (list :schema-version 1 :width elpet-width
           :reduced-motion (if elpet-reduced-motion t :false)
           :pack-file elpet-pack-file
           :position (and elpet-remember-position elpet--position-data)))))

(defun elpet--restore-preferences ()
  "Restore saved position and otherwise uncustomized display defaults."
  (let ((preferences (elpet--read-preferences)))
    (when preferences
      (setq elpet--position-data
            (and elpet-remember-position (plist-get preferences :position)))
      (dolist (entry '((elpet-width . :width)
                       (elpet-reduced-motion . :reduced-motion)
                       (elpet-pack-file . :pack-file)))
        (let* ((symbol (car entry)) (key (cdr entry))
               (value (plist-get preferences key)))
          (when (and (plist-member preferences key)
                     (not (get symbol 'saved-value))
                     (not (get symbol 'customized-value))
                     (equal (symbol-value symbol) (eval (car (get symbol 'standard-value)) t))
                     (pcase key
                       (:width (and (integerp value) (<= 32 value 2000)))
                       (:reduced-motion (memq value '(nil t)))
                       (:pack-file (or (null value) (and (stringp value) (file-readable-p value))))))
            (set symbol value)))))))

(defun elpet--record-status (text)
  "Record changed status TEXT once, keeping redraws out of history."
  (when (and (elpet--resolve nil) (not (equal text elpet--text)))
    (elpet--remember elpet--default-instance
                         (list :id (elpet--new-id elpet--default-instance "status")
                               :source "status" :text text :time (elpet--now)))))

(defun elpet-history (&optional pet)
  "Show PET's full message history in a separate buffer."
  (interactive)
  (let ((instance (or (elpet--resolve pet) (user-error "Pet is not active"))))
    (with-current-buffer (get-buffer-create "*elpet history*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (message (reverse (elpet-instance-history instance)))
          (insert (format "[%s] %s\n%s\n\n"
                          (format-time-string "%H:%M:%S" (seconds-to-time (plist-get message :time)))
                          (plist-get message :source) (plist-get message :text))))
        (special-mode)
        (goto-char (point-max)))
      (display-buffer (current-buffer)))))

(defun elpet-hide ()
  "Hide or show the companion without discarding active tasks."
  (interactive)
  (unless elpet-mode (user-error "Pet is not active"))
  (elpet--with-default
   (setq elpet--hidden (not elpet--hidden))
   (if (and elpet--hidden (not elpet--frame))
       (when (window-live-p elpet--window)
         (delete-window elpet--window)
         (setq elpet--window nil))
     (when (and (not elpet--hidden) (not elpet--frame)
                (not (window-live-p elpet--window)))
       (setq elpet--window
             (display-buffer-in-side-window elpet--buffer
                                            '((side . right) (slot . 0) (window-width . 30))))))
   (elpet--tick)))

(defun elpet-capabilities (&optional pet)
  "Return display capabilities and fallback reasons for PET."
  (let* ((instance (elpet--resolve pet))
         (view (and instance (elpet-instance-view instance)))
         (graphical (display-graphic-p (and view (elpet-view-parent view)))))
    (list :graphical graphical :gif (and graphical (image-type-available-p 'gif))
          :svg (and graphical (image-type-available-p 'svg))
          :png (and graphical (image-type-available-p 'png))
          :converter (executable-find "rsvg-convert")
          :background-transparency (and (eq window-system 'ns) (intern-soft "ns-alpha-glyphs") t)
          :mouse-click-through 'unverified
          :backend (cond ((null view) 'none)
                         ((elpet-view-frame view) 'child-frame) (t 'window))
          :fallback-reason (cond ((not graphical) "A graphical session is required")
                                 ((not (image-type-available-p 'svg)) "Text bubbles: SVG unavailable")
                                 ((and view (not (elpet-view-frame view))) "Regular side window")))))

(defun elpet-doctor ()
  "Display capability and resource diagnostics for the default instance."
  (interactive)
  (with-help-window "*elpet diagnostics*"
    (princ (format "elpet %s\nEmacs %s\nExecutable: %s\nWindow system: %s\n\n"
                   elpet-version
                   emacs-version (expand-file-name invocation-name invocation-directory) window-system))
    (princ (format "%S\n\nLast display error: %s\n" (elpet-capabilities)
                   (or elpet--last-display-error "none")))
    (when-let* ((pet (elpet--resolve nil)) (view (elpet-instance-view pet)))
      (princ (format "Instance: %s (generation %d)\nSources: %d; subscribers: %d\nTimer: %s; converter: %s\nLast error: %s\n"
                     (elpet-instance-id pet) (elpet-instance-generation pet)
                     (hash-table-count (elpet-instance-sources pet))
                     (length (elpet-instance-subscribers pet))
                     (timerp (elpet-view-timer view))
                     (and (process-live-p (elpet-view-bubble-process view)) t)
                     (or (elpet-view-last-error view) "none"))))))

(provide 'elpet)
;;; elpet.el ends here
