;;; elpet-gui-test.el --- Display lifecycle integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'elpet)

(defmacro elpet-test--with-display (&rest body)
  "Run BODY with an isolated graphical companion."
  (declare (indent 0))
  `(progn
     (skip-unless (display-graphic-p))
     (save-window-excursion
       (let ((elpet-state-file nil)
             (elpet-display-type 'child-frame)
             (elpet-reduced-motion nil)
             (elpet-width 220))
         (unwind-protect
             (progn (delete-other-windows) (elpet-mode 1) ,@body)
           (elpet-stop))))))

(ert-deftest elpet-gui-toggle-cancels-all-instance-resources-and-late-work ()
  (elpet-test--with-display
   (dotimes (_ 3)
     (let* ((pet elpet--default-instance)
            (view (elpet-instance-view pet))
            (timer (elpet-view-timer view))
            (callback (timer--function timer))
            (image (elpet-view-image view))
            (animation-timer (image-animate-timer image)))
       (elpet-stop)
       (should-not (elpet-instance-alive pet))
       (should-not (memq timer timer-list))
       (should-not (memq animation-timer timer-list))
       (should-not (buffer-live-p (elpet-view-buffer view)))
       (should-not (frame-live-p (elpet-view-frame view)))
       (should-not (process-live-p (elpet-view-bubble-process view)))
       (elpet-mode 1)
       (let ((current elpet--default-instance))
         (funcall callback)
         (should (eq current elpet--default-instance))
         (should (buffer-live-p (elpet-view-buffer (elpet-instance-view current)))))))))

(ert-deftest elpet-gui-simulated-host-disconnect-and-hidden-events ()
  (elpet-test--with-display
   (let ((pet elpet--default-instance))
     (elpet-register-source "simulated-host")
     (elpet-test--event pet "simulated-host" 0 'started)
     (elpet--tick)
     (elpet--with-default (should (eq elpet--state 'working)))
     (elpet-hide)
     (elpet-test--event pet "simulated-host" 1 'waiting)
     (elpet--tick)
     (elpet--with-default
      (should elpet--hidden)
      (should-not (frame-visible-p elpet--frame))
      (should-not elpet--image))
     (elpet-hide)
     (elpet--with-default
      (should (eq elpet--state 'waiting))
      (should (frame-visible-p elpet--frame)))
     (elpet-unregister-source "simulated-host")
     (elpet--tick)
     (elpet--with-default (should (eq elpet--state 'idle))))))

(ert-deftest elpet-gui-long-bubbles-retheme-without-restarting-image ()
  (elpet-test--with-display
   (elpet--with-default
    (let ((image elpet--image)
          (text (make-string 500 ?x))
          (original (face-background 'elpet-bubble)))
      (unwind-protect
          (progn
            (elpet-say text)
            (elpet--tick)
            (should (eq image elpet--image))
            (should (= (length elpet--bubble-lines) (elpet--bubble-line-limit)))
            (should (> elpet--bubble-height 46))
            (set-face-background 'elpet-bubble "#334455")
            (elpet--tick)
            (should (eq image elpet--image))
            (should (equal (cadr elpet--pending-bubble) "#334455"))
            (should (equal (plist-get (car (plist-get (elpet-snapshot) :history)) :text) text)))
        (set-face-background 'elpet-bubble original))))))

(ert-deftest elpet-gui-chat-bubble-opens-chat-and-body-keeps-petting ()
  (elpet-test--with-display
    (elpet-say "A full chat reply" '(:action elpet-chat))
    (elpet--tick)
    (elpet--with-default
      (with-current-buffer elpet--buffer
        (should (eq (lookup-key (get-text-property (point-min) 'keymap) [mouse-1])
                    #'elpet--bubble-click))
        (should (eq (lookup-key (get-text-property (1- (point-max)) 'keymap) [mouse-1])
                    #'elpet-pet)))
      (let (opened)
        (cl-letf (((symbol-function 'elpet-chat) (lambda () (interactive) (setq opened t))))
          (elpet--bubble-click)
          (should opened))))))

(ert-deftest elpet-gui-bubble-scroll-keeps-size-animation-and-focus ()
  (elpet-test--with-display
    (elpet-say (mapconcat (lambda (n) (format "Line %02d" n)) (number-sequence 1 20) "\n")
                   '(:action elpet-chat))
    (elpet--tick)
    (elpet--with-default
      (let ((image elpet--image) (width elpet--display-width)
            (height elpet--bubble-height) (window (selected-window))
            (history (length (elpet-instance-history elpet--default-instance))))
        (elpet-bubble-next-lines 3)
        (should (= elpet--bubble-offset 3))
        (should (equal (car elpet--bubble-lines) "Line 04"))
        (elpet-bubble-next-lines 100)
        (should (= elpet--bubble-offset (- 20 (elpet--bubble-line-limit))))
        (should (equal (car (last elpet--bubble-lines)) "Line 20"))
        (should (= width elpet--display-width))
        (should (= height elpet--bubble-height))
        (should (eq image elpet--image))
        (should (eq window (selected-window)))
        (should (= history (length (elpet-instance-history elpet--default-instance))))
        (elpet-bubble-previous-lines 100)
        (should (= elpet--bubble-offset 0))
        (with-current-buffer elpet--buffer
          (should (eq (lookup-key (get-text-property (point-min) 'keymap) [wheel-down])
                      #'elpet-bubble-next-lines)))))))

(ert-deftest elpet-gui-bubble-height-follows-content-and-window-space ()
  (elpet-test--with-display
    (let ((elpet-bubble-max-lines 8))
      (elpet-say "Hi") (elpet--tick)
      (elpet--with-default
        (let ((short elpet--bubble-height) (image elpet--image))
          (elpet-say "One\nTwo\nThree\nFour\nFive\nSix")
          (elpet--tick)
          (should (> elpet--bubble-height short))
          (should (<= (length elpet--bubble-lines) 6))
          (should (eq image elpet--image))
          (let ((limit (elpet--bubble-line-limit)))
            (split-window-below)
            (elpet--window-size-change elpet--parent)
            (elpet--tick)
            (should (< (elpet--bubble-line-limit) limit))
            (should (<= (length elpet--bubble-lines) (elpet--bubble-line-limit)))
            (delete-other-windows))
          (elpet-say "Short again") (elpet--tick)
          (should (= short elpet--bubble-height))
          (let* ((svg (elpet--bubble-svg elpet--text))
                 (text-node (car (dom-by-tag svg 'text))))
            (should (equal (dom-attr text-node 'text-anchor) "start"))))))))

(ert-deftest elpet-gui-side-window-hide-and-child-frame-fallback ()
  (skip-unless (display-graphic-p))
  (save-window-excursion
    (let ((elpet-state-file nil)
          (elpet-display-type 'child-frame))
      (unwind-protect
          (progn
            (delete-other-windows)
            (cl-letf (((symbol-function 'make-frame) (lambda (&rest _) (error "unavailable"))))
              (elpet-mode 1))
            (elpet--with-default
             (should-not elpet--frame)
             (should (window-live-p elpet--window)))
            (elpet-hide)
            (elpet--tick)
            (should elpet-mode)
            (elpet-hide)
            (elpet--with-default (should (window-live-p elpet--window))))
        (elpet-stop)))))

(ert-deftest elpet-gui-position-survives-mode-restart ()
  (skip-unless (display-graphic-p))
  (let* ((directory (make-temp-file "pet-gui-position-" t))
         (elpet-state-file (expand-file-name "state.json" directory))
         (elpet-remember-position t))
    (unwind-protect
        (progn
          (elpet-mode 1)
          (elpet--with-default
           (let ((area (window-inside-pixel-edges (selected-window))))
             (setq elpet--manual-position (cons (+ (car area) 20) (+ (cadr area) 30)))
             (elpet--position)))
          (elpet-stop)
          (should (plist-get (elpet--read-preferences) :position))
          (elpet-mode 1)
          (elpet--with-default
           (should elpet--position-data)
           (should (< (frame-parameter elpet--frame 'left) 100))
           (elpet-reset-position)
           (should-not elpet--position-data))
          (should-not (plist-get (elpet--read-preferences) :position)))
      (elpet-stop)
      (delete-directory directory t))))



(ert-deftest elpet-gui-repeated-idle-interaction-selects-another-action ()
  ;; The built-in pack has one idle action; the test only applies when the
  ;; active pack offers an alternative.
  (skip-unless (and elpet--pack
                    (> (length (elpet--pack-actions elpet--pack 'idle)) 1)))
  (elpet-test--with-display
   (let ((before (elpet-view-animation (elpet-instance-view elpet--default-instance))))
     (elpet-random-action)
     (should-not (equal before (elpet-view-animation
                                (elpet-instance-view elpet--default-instance)))))))

(ert-deftest elpet-gui-parent-deletion-invalidates-the-instance ()
  (skip-unless (display-graphic-p))
  (let ((elpet-state-file nil)
        (parent (make-frame '((name . "Pet lifecycle test") (visibility . nil)))))
    (unwind-protect
        (with-selected-frame parent
          (elpet-mode 1)
          (let* ((pet elpet--default-instance)
                 (view (elpet-instance-view pet))
                 (timer (elpet-view-timer view)))
            (delete-frame parent t)
            (should-not elpet-mode)
            (should-not (elpet-instance-alive pet))
            (should-not (memq timer timer-list))
            (should-not (buffer-live-p (elpet-view-buffer view)))))
      (when (frame-live-p parent) (delete-frame parent t))
      (elpet-stop))))

(provide 'elpet-gui-test)
;;; elpet-gui-test.el ends here
