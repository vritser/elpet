;;; elpet-test.el --- Tests for the Emacs companion -*- lexical-binding: t; -*-

(require 'ert)
(require 'elpet)

(ert-deftest elpet-bundled-assets-exist ()
  (dolist (entry elpet--animations)
    (dolist (name (cdr entry))
      (should (file-readable-p (elpet--asset name))))))

(ert-deftest elpet-choice-handles-singletons ()
  (let ((elpet--animation nil))
    (should (equal (elpet--choose 'idle) "daiji-huxi-xiuxian")))
  (let ((elpet--animation "daiji-huxi-xiuxian"))
    (should (equal (elpet--choose 'idle) "daiji-huxi-xiuxian")))
  (let ((elpet--animation "da-keshui-bei-jingxing"))
    (should (equal (elpet--choose 'sleeping) "da-keshui-bei-jingxing"))))

(ert-deftest elpet-missing-assets-report-useful-error ()
  (let ((elpet-assets-directory (make-temp-file "pet-no-assets" t)))
    (unwind-protect
        (should-error (elpet--choose 'idle) :type 'user-error)
      (delete-directory elpet-assets-directory))))

(ert-deftest elpet-state-priorities-and-expiry ()
  (let ((elpet--override '(happy . 20))
        (elpet--compilations '(compiling))
        (elpet-follow-compilation t)
        (elpet-sleep-delay 60))
    (should (eq (elpet--effective-state 10 100) 'happy))
    (should (eq (elpet--effective-state 20 100) 'working))
    (should-not elpet--override)
    (setq elpet--compilations nil)
    (should (eq (elpet--effective-state 21 60) 'sleeping))
    (should (eq (elpet--effective-state 21 0) 'idle))))

(ert-deftest elpet-disabled-hooks-do-not-open-pet ()
  (let ((elpet-mode nil)
        (elpet--override nil)
        (elpet--compilations nil))
    (elpet-set-state 'success)
    (elpet--compilation-start 'unused)
    (should-not elpet--override)
    (should-not elpet--compilations)))

(ert-deftest elpet-start-failure-cleans-up ()
  (let ((elpet-mode nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (should-error (elpet-mode 1) :type 'user-error))
    (should-not elpet-mode)
    (should-not elpet--timer)
    (should-not elpet--buffer)
    (should-not (memq #'elpet--compilation-start compilation-start-hook))))

(ert-deftest elpet-concurrent-compilations-wait-for-last-result ()
  (let* ((first (generate-new-buffer " pet-compile-1"))
         (last (generate-new-buffer " pet-compile-2"))
         (elpet-mode t)
         (elpet-follow-compilation t)
         (elpet--compilations '(first last))
         result)
    (unwind-protect
        (cl-letf (((symbol-function 'process-buffer)
                   (lambda (p) (if (eq p 'first) first last)))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'elpet-set-state)
                   (lambda (state &optional _) (setq result state))))
          (elpet--compilation-finish first "finished\n")
          (should-not result)
          (should (equal elpet--compilations '(last)))
          (elpet--compilation-finish last "exited abnormally with code 1\n")
          (should (eq result 'error))
          (should-not elpet--compilations))
      (kill-buffer first)
      (kill-buffer last))))

(ert-deftest elpet-cleanup-cancels-both-timers ()
  (let* ((animation-timer (run-at-time 300 nil #'ignore))
         (elpet--timer (run-at-time 300 nil #'ignore))
         (state-timer elpet--timer)
         (elpet--image '(image :type gif))
         (elpet--buffer nil)
         (elpet--frame nil)
         (elpet--window nil))
    (cl-letf (((symbol-function 'image-animate-timer)
               (lambda (_) animation-timer)))
      (elpet--cleanup))
    (should-not (memq animation-timer timer-list))
    (should-not (memq state-timer timer-list))
    (should-not elpet--image)))

(ert-deftest elpet-animation-refreshes-its-own-buffer ()
  (with-temp-buffer
    (let ((elpet--bubble-images (make-hash-table :test #'equal))
          (elpet--buffer (current-buffer))
          (elpet--image nil)
          (elpet--state nil)
          (elpet--animation nil)
          (elpet--next-action 0)
          animation-buffer)
      (cl-letf (((symbol-function 'create-image) (lambda (&rest _) '(image :type gif)))
                ((symbol-function 'insert-image) (lambda (&rest _) (insert "pet")))
                ((symbol-function 'image-animate)
                 (lambda (&rest _) (setq animation-buffer (current-buffer)))))
        (with-temp-buffer (elpet--play 'idle "daiji-huxi-xiuxian"))
        (should (eq animation-buffer elpet--buffer))))))

(ert-deftest elpet-child-frame-preserves-parent-and-hides-mode-line ()
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (let ((elpet-state-file nil)
          (parent-window (selected-window))
          (parent-buffer (current-buffer))
          (parent-mode-line mode-line-format)
          (elpet-display-type 'child-frame)
          (other (generate-new-buffer " pet-parent-switch")))
      (unwind-protect
          (progn
            (delete-other-windows parent-window)
            (elpet-mode 1)
            (elpet--with-default
             (sit-for 0.3)
             (when (and (eq window-system 'ns) (intern-soft "ns-alpha-glyphs"))
               (should (= (frame-parameter elpet--frame 'alpha-background) 0))
               (should (= (frame-parameter elpet--frame 'ns-background-blur) 0))
               (should (equal (frame-parameter elpet--frame 'ns-alpha-elements)
                              '(ns-alpha-all))))
             (should (eq (selected-window) parent-window))
             (should (= (window-mode-line-height elpet--window) 0))
             (let ((body (window-inside-pixel-edges parent-window)))
               (should (<= (+ (frame-parameter elpet--frame 'top)
                              (frame-pixel-height elpet--frame))
                           (nth 3 body))))
             (let ((small (split-window parent-window -5 'below)))
               (unwind-protect
                   (progn
                     (elpet--position)
                     (should-not (frame-visible-p elpet--frame)))
		 (delete-window small)))
             (elpet--position)
             (sit-for 0.3)
             (should (eq (frame-visible-p elpet--frame) t))
             (should (< (frame-pixel-width elpet--frame) elpet-width))
             (sleep-for 0.4)
             (should (> (image-current-frame elpet--image) 0))
             (let* ((body (window-inside-pixel-edges parent-window))
                    (desired (cons (+ (car body) 20) (+ (cadr body) 20))))
               (setq elpet--manual-position desired)
               (elpet--position)
               (elpet-set-state 'happy)
               (elpet--tick)
               (should (= (frame-parameter elpet--frame 'left) (car desired)))
               (should (= (frame-parameter elpet--frame 'top) (cdr desired)))
               (elpet-reset-position)
               (should-not elpet--manual-position))
             ;; PNG conversion is asynchronous; wait for output, then redraw.
             (when (process-live-p elpet--bubble-process)
               (let ((deadline (+ (float-time) 3)))
		 (while (and (process-live-p elpet--bubble-process) (< (float-time) deadline))
                   (accept-process-output elpet--bubble-process 0.05))))
             (elpet--tick)
             (with-current-buffer elpet--buffer
               (when (image-type-available-p 'svg)
		 (should (eq (plist-get (cdr (get-text-property (point-min) 'display))
					:type)
                             (if (and (eq window-system 'ns)
                                      (image-type-available-p 'png)
                                      (executable-find "rsvg-convert"))
				 'png 'svg))))
               (should (<= (+ elpet--bubble-height
                              (or elpet--sprite-height
				  (cdr (image-size elpet--image t))))
                           (window-body-height elpet--window t)))
               (should (<= (cdr (window-text-pixel-size
				 elpet--window (point-min) (point-max) nil 10000))
                           (window-body-height elpet--window t))))
             (switch-to-buffer other)
             (sit-for 0.3)
             (should (eq (window-buffer elpet--window) elpet--buffer))
             (should (= (window-mode-line-height elpet--window) 0))
             (should (equal (buffer-local-value 'mode-line-format parent-buffer)
                            parent-mode-line))))
	(elpet-stop)
	(set-window-buffer parent-window parent-buffer)
	(kill-buffer other)))))

(ert-deftest elpet-child-frame-shows-bubble-right-edge ()
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (save-window-excursion
    (let ((elpet-state-file nil)
          (elpet-display-type 'child-frame)
          (elpet-trim-transparent-margins t)
          (elpet-width 220))
      (unwind-protect
          (progn
            (delete-other-windows)
            (elpet-mode 1)
            (elpet--with-default
             (dolist (font-height '(120 200))
               (set-face-attribute 'default elpet--frame :height font-height)
               (dolist (width '(180 220 440))
                 (setq elpet-width width)
                 (dolist (state '(idle working happy))
                   (elpet--play state "daiji-huxi-xiuxian")
                   (redisplay t)
                   (let* ((bubble (with-current-buffer elpet--buffer
                                    (get-text-property (point-min) 'display)))
                          (size (image-size bubble t))
                          (right-edge (posn-at-x-y (1- (car size))
                                                   (/ (cdr size) 2)
                                                   elpet--window)))
                     ;; A matching frame width alone is insufficient: with
                     ;; no fringe, Emacs can clip the image for its EOL glyph.
                     (should (equal (posn-object right-edge) bubble))))))))
        (elpet-stop)))))

(ert-deftest elpet-image-clicks-use-pet-commands ()
  ;; This test needs a real image backend: it verifies that `insert-image's
  ;; own keymap does not mask the pet's click map.
  (skip-unless (image-type-available-p 'gif))
  (with-temp-buffer
    (let ((elpet--buffer (current-buffer))
          (elpet--image nil)
          (elpet--state nil)
          (elpet--animation nil)
          (elpet--next-action 0)
          requested-state)
      (cl-letf (((symbol-function 'image-animate) #'ignore)
                ((symbol-function 'elpet-set-state)
                 (lambda (state &optional _) (setq requested-state state))))
        ;; Use real `insert-image': its image keymap used to mask pet clicks.
        (elpet--play 'idle "daiji-huxi-xiuxian")
        (dolist (position (list (point-min) (1- (point-max))))
          (let ((map (get-text-property position 'keymap)))
            (should (eq (lookup-key map [down-mouse-1])
                        (if (= position (point-min)) #'elpet--bubble-drag
                          #'elpet-drag)))
            (call-interactively (lookup-key map [mouse-1]))
            (should (eq requested-state 'happy))
            (call-interactively (lookup-key map [double-mouse-1]))
            (should (eq requested-state 'idle))))))))

(ert-deftest elpet-docking-stays-inside-text-area ()
  (let ((elpet-margin 16))
    ;; A bottom-right split: its bottom edge already excludes its mode line.
    (should (equal (elpet--fit-position '(400 250 800 600) 220 180)
                   '(564 . 404)))
    ;; Use all available space when margins do not fit.
    (should (equal (elpet--fit-position '(400 250 620 430) 220 180)
                   '(400 . 250)))
    ;; Never spill into a neighboring pane or its mode line.
    (should-not (elpet--fit-position '(400 250 619 600) 220 180))
    (should-not (elpet--fit-position '(400 250 800 429) 220 180))))

(defun elpet-test--gesture (press points events)
  "Exercise PRESS with sampled POINTS and subsequent EVENTS."
  (let ((elpet--frame (selected-frame))
        (elpet--manual-position nil)
        (elpet--dragging nil)
        (unread-command-events nil)
        positions action)
    (cl-letf (((symbol-function 'mouse-absolute-pixel-position)
               (lambda () (or (pop points) (error "Unexpected pointer read"))))
              ((symbol-function 'frame-parameter)
               (lambda (_ key) (if (eq key 'left) 100 150)))
              ((symbol-function 'read-event)
               (lambda (&rest _) (or (pop events) (error "Unexpected event read"))))
              ((symbol-function 'elpet--position)
               (lambda () (push elpet--manual-position positions)))
              ((symbol-function 'elpet-pet) (lambda () (setq action 'pet)))
              ((symbol-function 'elpet-random-action)
               (lambda () (setq action 'random))))
      (elpet-drag press))
    (should-not elpet--dragging)
    (list elpet--manual-position (nreverse positions) action unread-command-events)))

(ert-deftest elpet-drag-keeps-screen-origin-and-does-not-pet ()
  (should
   (equal (elpet-test--gesture
           '(down-mouse-1 nil) '((500 . 400) (520 . 410) (530 . 430))
           '((mouse-movement nil) (drag-mouse-1 nil nil)))
          '((130 . 180) ((120 . 160) (130 . 180)) nil nil))))

(ert-deftest elpet-drag-preserves-clicks-and-keyboard-input ()
  (should (equal (elpet-test--gesture
                  '(down-mouse-1 nil) '((500 . 400) (502 . 402))
                  '((mouse-1 nil)))
                 '(nil nil pet nil)))
  (should (equal (elpet-test--gesture
                  '(double-down-mouse-1 nil) '((500 . 400) (500 . 400))
                  '((double-mouse-1 nil)))
                 '(nil nil random nil)))
  (should (equal (elpet-test--gesture
                  '(down-mouse-1 nil) '((500 . 400)) '(27))
                 '(nil nil nil (27)))))

(ert-deftest elpet-drag-clamps-to-nearest-fitting-pane ()
  (let ((areas '((10 10 390 300) (410 10 800 600))))
    (should (equal (elpet--nearest-position '(30 . 40) areas 220 180)
                   '(30 . 40)))
    (should (equal (elpet--nearest-position '(300 . 160) areas 220 180)
                   '(410 . 160)))
    (should (equal (elpet--nearest-position '(999 . 999) areas 220 180)
                   '(580 . 420)))
    (should-not (elpet--nearest-position '(30 . 40) areas 900 180))))

(ert-deftest elpet-crop-reduces-padding-without-rescaling-pet ()
  (let ((elpet-width 220)
        (elpet-trim-transparent-margins t)
        elpet--image-slice elpet--sprite-height
        elpet--sprite-width elpet--display-width)
    (elpet--layout "daiji-huxi-xiuxian" "陪你摸鱼")
    (should (= elpet--sprite-width 87))
    (should (= elpet--sprite-height 97))
    (should (= elpet--display-width 92))
    (should (= (length elpet--image-slice) 4))
    (setq elpet-width 440)
    (elpet--layout "daiji-huxi-xiuxian" "陪你摸鱼")
    (should (= elpet--sprite-width 174))
    (should (= elpet--display-width 184))))

(ert-deftest elpet-crop-does-not-clip-replacement-assets ()
  (let ((elpet-trim-transparent-margins t)
        (directory (make-temp-file "pet-crop-test" t)))
    (unwind-protect
        (let ((elpet-assets-directory directory))
          (with-temp-file (elpet--asset "daiji-huxi-xiuxian")
            (insert "Different asset with the same name"))
          (should-not (elpet--crop "daiji-huxi-xiuxian")))
      (delete-directory directory t))))

(load (expand-file-name "elpet-core-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(load (expand-file-name "elpet-chat-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(load (expand-file-name "elpet-pack-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(load (expand-file-name "elpet-gui-test.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

;;; elpet-test.el ends here
