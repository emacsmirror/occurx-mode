;;; logview-mode.el --- Interactive log filtering  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  k32

;; Author: k32 <example@example.com>
;; Keywords: logs occur
;; Version: 0.1
;; Homepage: https://github.com/k32/snabbkaffe-mode
;; Package-Requires: ((emacs "25.1") (rbit "0.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'rx)
(require 'hi-lock)
(require 'cl-lib)
(require 'rbit)

;;; Customizable settings

(setq logview--snk-bindings
      '((=> (a b) (seq a (* blank) "=>" (* blank) b))
        (kind (a) (=> "'$kind'" a))
        (meta (k v) (=> "'~meta'" (seq "#{" (* nonl) (=> k v))))))

(defcustom logview-rx-bindings
  logview--snk-bindings
  "List of additional definitions that is passed to `rx-let-eval'"
  :type '(repeat sexp))

(defcustom logview-default-faces
  '(hi-pink hi-green hi-blue hi-salmon)
  "List of faces used to highlight the patterns."
  :type '(repeat face)
  :group 'logview)

(defcustom logview-context
  10
  "Size of the context"
  :type 'integer
  :group 'logview)

;;; Source buffer

;;;###autoload
(define-minor-mode logview-mode
  "Minor mode for viewing logs"
  :lighter "🪵"
  :keymap (list (cons (kbd "q") #'quit-window)
                (cons (kbd "o") #'logview-pattern-buffer)
                (cons (kbd "<SPC>") #'scroll-up-command)
                (cons (kbd "C-c C-c") (lambda ()
                                        (logview-pattern-buffer)
                                        (logview-run))))
  (read-only-mode t))

(defun logview--occur-buffer (source-buffer)
  "Create or get occur buffer for the given SOURCE-BUFFER"
  (get-buffer-create (concat "*Occur* " (buffer-name source-buffer)) t))

;;; Occur
(defun logview--run-pattern (pattern begin bound)
  "Run a list of regular expressions PATTERN.
If all of them match, return list of positions of all matches, `nil' overwise."
  (cl-loop for re in pattern
           for found = (progn
                         (goto-char begin)
                         (cl-loop while (re-search-forward re bound t)
                                  collect `(,(match-beginning 0) . ,(match-end 0))))
           if found append found
           else return nil))

(defun logview--match-intervals (begin bound matches)
  (let* (acc
         (push-interval (lambda (beg end match)
                          (if (= beg end)
                              acc
                            (setq acc (rbit-set acc beg end match (lambda (a b) (or a b))))))))
    (pcase-dolist (`(,beg . ,end) matches)
      (funcall push-interval beg end t)
      (funcall push-interval (max begin (- beg logview-context)) beg nil)
      (funcall push-interval end (min bound (+ end logview-context)) nil))
    (rbit-to-list acc)))

(defun logview--on-match (entry-beginning begin bound matches face orig-buf occur-buf)
  "This function is called when a pattern match is found"
  (with-current-buffer occur-buf
    (dolist (i (logview--match-intervals entry-beginning bound
                                         ;; TODO: add entry delimiter to the list of matches:
                                         matches))
      (let* ((min (pop i))
             (max (pop i))
             (hl (pop i))
             (chunk-begin (point))
             (offset (- chunk-begin min)))
        (insert-buffer-substring orig-buf min max)
        ;; Add property that allows to jump to the source
        (put-text-property chunk-begin (point) 'logview-pointer min)
        ;; Highlight fragment:
        (when hl
          (put-text-property chunk-begin (point) 'face face))))
      ;;   Insert newline if not at the end of line:
      (unless (bolp)
        (insert-char ?\n))))

(defun logview--run-patterns (delimiter patterns orig-buf occur-buf)
  (let (entry-beginning body-beginning next-entry-beginning next-body-beginning)
    ;; Initialization of the loop:
    (setq body-beginning (re-search-forward delimiter nil t)
          entry-beginning (match-beginning 0))
    ;; Loop over buffer:
    (while body-beginning
      (forward-char)
      ;; Find next entry:
      (setq next-body-beginning (re-search-forward delimiter nil t)
            next-entry-beginning (if next-body-beginning (match-beginning 0) (point-max)))
      ;; Match entry's body against patterns, stop on first match:
      (cl-loop for pattern in patterns
               for matches = (logview--run-pattern (plist-get pattern :rx)
                                                   body-beginning
                                                   next-entry-beginning)
               if matches
               return (logview--on-match entry-beginning body-beginning next-entry-beginning
                                         matches
                                         (plist-get pattern :face)
                                         orig-buf occur-buf)
               end)
      ;; Move forward:
      (setq body-beginning next-body-beginning
            entry-beginning next-entry-beginning)
      (when body-beginning (goto-char body-beginning)))))

(defun logview--occur (pattern-buf orig-buf delimiter patterns)
  (let ((occur-buf (logview--occur-buffer (current-buffer))))
    (set-window-dedicated-p
     (display-buffer occur-buf
                     `((display-buffer-reuse-window display-buffer-in-atom-window)
                       (side . left)
                       (window . ,(window-parent))))
     t)
    (with-current-buffer occur-buf
      (logview-occur-mode)
      (setq-local logview-orig-buffer orig-buf)
      (setq-local logview-pattern-buffer pattern-buf)
      (read-only-mode -1)
      (erase-buffer))
    (with-current-buffer orig-buf
      (save-excursion
        (goto-char (point-min))
        (logview--run-patterns delimiter patterns orig-buf occur-buf)))
    (with-current-buffer occur-buf
      (read-only-mode))))

;;;###autoload
(defun logview-run ()
  "Read a set of `rx' patterns from a specified buffer and run `occur' with them.
Colorize the occur buffer."
  (interactive "")
  (pcase-exhaustive (logview--read-patterns (current-buffer))
    (`(,delimiter . ,raw-patterns)
     (message "Filtering patterns %S with delimiter %S" raw-patterns delimiter)
     (let ((compiled-patterns (logview--compile-patterns raw-patterns)))
       (dolist (buf logview-dependent-buffers)
         (logview--occur (current-buffer) buf delimiter compiled-patterns))))))

;;;; Occur major mode
(defun logview-occur-visit-source ()
  "Jump to the occurrance in the original buffer"
  (interactive)
  (let ((pos (get-text-property (point) 'logview-pointer)))
    (when pos
      (select-window
       (display-buffer logview-orig-buffer '((display-buffer-reuse-window display-buffer-in-direction)
                                             (direction . right))))
      (goto-char pos))))

(defvar logview-occur-mode-map nil "Keymap for logview-occur-mode")
(setq logview-occur-mode-map (make-sparse-keymap))

(define-key logview-occur-mode-map (kbd "<return>") #'logview-occur-visit-source)
(define-key logview-occur-mode-map (kbd "o") #'logview-pattern-buffer)
(define-key logview-occur-mode-map [mouse-1] #'logview-occur-visit-source)

(define-derived-mode logview-occur-mode fundamental-mode
  "🪡"
  :syntax-table nil
  :abbrev-table nil
  (setq-local logview-orig-buffer nil))

;;;; Pattern buffer

(defun logview--buffer-to-sexps (buffer)
  "Parse BUFFER into a list of sexps"
  (with-current-buffer buffer
    (save-excursion
      (let (sexps
            sexp
            (line-start 0)
            line-end)
        (goto-char (point-min))
        (ignore-errors
          (while (setq sexp (read (current-buffer)))
            (setq line-end (line-number-at-pos))
            (push (list line-start line-end sexp) sexps)
            (setq line-start line-end)))
        (reverse sexps)))))

(defun logview--normalize-pattern (input)
  "Produce a normalized pattern from the raw user input
Result type: (:start LINE :end LINE :face FACE :rx LIST-OF-RX-PATTERNS)"
  (let ((line-start (pop input))
        (line-end   (pop input))
        (pattern    (pop input)))
    (pcase-exhaustive pattern
      ((pred stringp)
       ;; Single string pattern:
       `(:start ,line-start :end ,line-end :face nil :rx (,pattern)))
      ((pred listp)
       ;; Complex pattern, try to extract the keywords and treat the rest of the list as rx pattern:
       (let (face keyw)
         (while (keywordp (setq keyw (car pattern)))
           (setq pattern (cdr pattern))
           (pcase keyw
             (:face (setq face (pop pattern)))))
         `(:start ,line-start :end ,line-end :face ,face :rx ,pattern))))))

(defun logview--read-patterns (buffer)
  "Read patterns from BUFFER as s-exps"
  (let* ((patterns (logview--buffer-to-sexps buffer))
         (delimiter '(or bos bol))
         result
         (normalize (lambda (input)
                      (pcase-exhaustive input
                        (`(,_ ,_ (delimiter ,del))   (setq delimiter del))
                        (_                           (push (logview--normalize-pattern input) result))))))
    (mapcar normalize patterns)
    `(,(logview--rx-compile delimiter) . ,result)))

(defun logview--intercalate (separator l)
  "Return a list where SEPARATOR is inserted between elements of L."
  (let (ret)
    (dolist (i l (nreverse (cdr ret)))
      (setq ret (cons separator (cons i ret))))))

(defun logview--preprocess-rx (pat)
  "Preprocess `rx' pattern PAT.
Change behavior of `and' operation: it inserts `(* nonl)' between each operand.
Use `seq' if you need standard rx behavior."
  (pcase pat
    (`(and . ,rest) (cons 'and (logview--intercalate '(* any) (logview--preprocess-rx rest))))
    ((pred listp)   (mapcar #'logview--preprocess-rx pat))
    (_              pat)))

(defun logview--rx-compile (pat)
  "Compile rx pattern PAT to string"
  (rx-let-eval logview-rx-bindings
    (rx-to-string (logview--preprocess-rx pat) t)))

(defun logview--compile-patterns (patterns)
  "Compile rx patterns into string form"
  (let ((faces logview-default-faces))
    (mapcar
     (lambda (pat)
       ;; Cycle faces if reached the end of the default list:
       (unless faces (setq faces logview-default-faces))
       ;; Compile pattern:
       (let* ((raw-patterns (plist-get pat :rx))
              (patterns (mapcar #'logview--rx-compile raw-patterns))
              (face (or (plist-get pat :face) (pop faces))))
         (plist-put (plist-put pat :rx patterns) :face face)))
     patterns)))

;;;###autoload
(defun logview--find-pattern-buffer (change)
  "Find or create a buffer that stores the pattern for the current buffer."
  (unless (and (boundp 'logview-pattern-buffer)
               (get-buffer logview-pattern-buffer) ; Buffer's alive
               (not change))                       ; User doesn't want to change it
    (setq-local logview-pattern-buffer
                (find-file-noselect (read-file-name "Buffer containing the pattern:" (concat (buffer-name) "-pattern.el")))))
  logview-pattern-buffer)

;;;###autoload
(defun logview-pattern-buffer (&optional change)
  "Switch to the pattern buffer"
  (interactive "P")
  (let ((orig-buf (buffer-name))
        (pattern-buf (logview--find-pattern-buffer change)))
    (select-window
     (display-buffer (get-buffer-create pattern-buf)
                     '((display-buffer-reuse-window display-buffer-in-atom-window)
                       (window-height . 8)
                       (side . below))))
    (set-window-dedicated-p (selected-window) t)
    (logview-pattern-mode)
    (push orig-buf logview-dependent-buffers)
    pattern-buf))

(defvar logview-pattern-mode-map nil "Keymap for logview-pattern-mode")
(setq logview-pattern-mode-map (make-sparse-keymap))
(define-key logview-pattern-mode-map (kbd "C-c C-c") #'logview-run)

(define-derived-mode logview-pattern-mode emacs-lisp-mode
  "🔍"
  :syntax-table nil
  :abbrev-table nil
  (setq-local logview-dependent-buffers nil))

(provide 'logview-mode)
;;; logview-mode.el ends here
