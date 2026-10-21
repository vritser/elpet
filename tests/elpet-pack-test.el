;;; elpet-pack-test.el --- Character-pack installation contracts -*- lexical-binding: t; -*-

(require 'ert)
(require 'elpet-pack)

(defun elpet-pack-test--make-pack (directory)
  "Create a minimal valid pack in DIRECTORY and return it."
  (make-directory directory t)
  (with-temp-file (expand-file-name "fallback.png" directory) (insert "fallback"))
  (with-temp-file (expand-file-name "idle.gif" directory) (insert "gif"))
  (with-temp-file (expand-file-name "pack.json" directory)
    (insert
     "{\"schema-version\":1,\"pack-id\":\"test-pack\",\"author\":\"test\",\
\"license\":\"MIT\",\"source\":\"test\",\"fallback\":\"fallback.png\",\
\"states\":{\"idle\":[{\"name\":\"idle-test\",\"file\":\"idle.gif\",\
\"weight\":1,\"loop\":true}]}}\n"))
  directory)

(ert-deftest elpet-pack-rejects-unsafe-archive-paths ()
  (should (elpet-pack--safe-entry-p "pack/assets/idle.gif"))
  (should (elpet-pack--safe-entry-p "pack/./assets/idle.gif"))
  (should-not (elpet-pack--safe-entry-p "../evil"))
  (should-not (elpet-pack--safe-entry-p "/absolute/evil"))
  (should-not (elpet-pack--safe-entry-p "pack/../../evil"))
  (should-not (elpet-pack--safe-entry-p "pack\\..\\evil")))

(ert-deftest elpet-pack-installs-directory-and-sets-pack-file ()
  (let* ((source (make-temp-file "elpet-pack-source-" t))
         (destination (make-temp-file "elpet-pack-install-" t))
         (elpet-pack-install-directory (file-name-as-directory destination))
         (elpet-pack-file nil)
         (elpet-state-file nil)
         (elpet-mode nil))
    (unwind-protect
        (progn
          (elpet-pack-test--make-pack source)
          (let ((manifest (elpet-install-pack source)))
            (should (file-readable-p manifest))
            (should (string-prefix-p (file-name-as-directory destination) manifest))
            (should (equal manifest elpet-pack-file))
            (should (file-readable-p
                     (expand-file-name "idle.gif" (file-name-directory manifest))))))
      (delete-directory source t)
      (delete-directory destination t))))

(ert-deftest elpet-pack-installs-tar-archive ()
  (skip-unless (executable-find "tar"))
  (let* ((source (make-temp-file "elpet-pack-archive-source-" t))
         (destination (make-temp-file "elpet-pack-archive-install-" t))
         (archive (make-temp-file "elpet-pack-" nil ".tar.gz"))
         (elpet-pack-install-directory (file-name-as-directory destination))
         (elpet-pack-file nil)
         (elpet-state-file nil)
         (elpet-mode nil))
    (unwind-protect
        (progn
          (elpet-pack-test--make-pack source)
          (should (zerop (call-process "tar" nil nil nil
                                       "-czf" archive "-C" source ".")))
          (let ((elpet-pack--official-sha256 (elpet-pack--sha256 archive)))
            (let ((manifest (elpet-install-pack archive)))
              (should (file-readable-p manifest))
              (should (equal manifest elpet-pack-file))
              (should (file-readable-p
                       (expand-file-name "pack.json" (file-name-directory manifest)))))))
      (delete-directory source t)
      (delete-directory destination t)
      (delete-file archive))))

;;; elpet-pack-test.el ends here
