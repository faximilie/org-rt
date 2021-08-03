;;; org-rt.el --- Emacs orgmode interface to RT  -*- lexical-binding: t; -*-

;; Copyright (C) 2020-2021 Free Software Foundation, Inc.

;; Author: Patrick Childs <me@faximili.me>
;; Maintainer: Patrick Childs <me@faximili.me>
;; Keywords: rt, tickets, orgmode
;; url: http://www.github.com/faximilie/org-rt/

;; This file is a part of org-rt.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public
;; License along with this program; if not, write to the Free
;; Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
;; MA 02111-1307, USA.

;;; Installation and Use:
;;
;; Detailed instructions for installation and use can be found in the
;; org-rt readme

;;; History:
;;
;; Started during july of 2021

;;; Special thanks to rt-liber.el for allowing me starting this project

;; TODO: Distinguish between task and tickets more clearly
;; TODO: Add docstrings to every function
;; TODO: introduce Point or Marker or ID
;;           - Allow calling most functions without ID and only work at current point
;;           - Reduce chance of incorrect ID being used (auto-translate)
;;           - Reduce line count drastically
;;           - Potentially reduce complexity by always working with POMs
;;           - Allow us to speed up ID lookups in future without rewriting a lot



;;; Code:

;;; ------------------------------------------------------------------
;;; Imports
;;; ------------------------------------------------------------------
(require 'threads)

(require 'cl-lib)
(require 'cl-macs)

(require 'org)
(require 'org-id)

(require 'request)


;;; ------------------------------------------------------------------
;;; Constants
;;; ------------------------------------------------------------------
(defconst org-rt-api-version "1.0"
  "The API version that org-rt will use (Currently only 1.0 is supported)")

(defconst org-rt-key-regexp "^\\(\\([ .{}#[:alpha:]]+\\): \\(.*\\)\\)$\\|^--$"
  "The regex to find keys within an RT 1.0 API response")

(defconst org-rt-continue-regexp "^\\(\s\\{%d,\\}\\)\\(.+\\)$"
  "The regex to find multiline values after a key within an RT 1.0 API response")

(defconst org-rt-id-regexp "[.[:alpha:]/]*\\([[:digit:]]+\\)[[:alpha:]/]*"
  "A regexp to find an ID within an RT 1.0 API response")
(defconst org-rt-id-key-regexp (concat "^id: " org-rt-id-regexp "$")
  "The regex to find id entries within an RT 1.0 API response")

(defconst org-rt-queue-regexp "^\\([0-9]+\\): \\([[:alpha:]_\-]+\\)$"
  "A regexp to match queues within an RT 1.0 API Response")

(defconst org-rt-new-ticket-regexp "^# Ticket \\([0-9]+\\) created.$"
  "A regexp to match the ID of a newly created ticket within an RT 1.0 API response")

(defconst org-rt-history-short-regexp "^\\([[:digit:]]+\\): \\(.+\\)$"
  "The regex to find short history entries within an RT 1.0 API response")

(defconst org-rt-link-regexp "fsck\\.com-rt://.+/\\([[:digit:]]+\\),*$";"^\\(\\([.{} #[:alpha:]]+\\): fsck\\.com-\\(.*/\\([[:digit:]]+\\)\\),*\\)$\\|^--$";"\\(^[.{}#[:alpha:]]+: fsck\\.com-.*\\)$\\|^--$"
  "The regex to find a link within an RT 1.0 API response")

(defconst org-rt-content-key-regexp "^\\(Content\\): \\(.+\\)$"
  "The regex to find the content key within an RT 1.0 API response")

(defconst org-rt-attach-key-regexp "^Attachments: $"
  "The regex to find the attachments key within an RT 1.0 API response")

(defconst org-rt-url-regexp "^\\(https*\\)://\\(.+\\):\\([0-9]+\\)/\\(.+\\)$"
  "A regex to find the details of a HTTP(S) url
Capture group 1 is the protocol
Capture group 2 is the hostname
Capture group 3 is the port
Capture group 4 is the path")

(defconst org-rt-url-path-regexp
  "https*://[.[:alpha:]]+\\(?::[[:digit:]]+\\)\\{,1\\}/[[:alpha:]._/]+/REST/1\.0/\\([[:alpha:][:digit:]/_.]+\\)\\(?:?.*\\)\\{,1\\}$"
  "A regexp to capture the path of an API url
This is a very tight regexp, and only supplies the path after `/REST/1.0/'")

(defconst org-rt-state-notes-regexp (concat "[ \t]*- +"
		                                        (replace-regexp-in-string
		                                         " +" " +"
		                                         (org-replace-escapes
		                                          (regexp-quote (cdr (assq 'state org-log-note-headings)))
		                                          `(("%d" . ,org-ts-regexp-inactive)
			                                          ("%D" . ,org-ts-regexp)
			                                          ("%s" . "\\(?:\"\\S-+\"\\)?")
			                                          ("%S" . "\\(?:\"\\S-+\"\\)?")
			                                          ("%t" . ,org-ts-regexp-inactive)
			                                          ("%T" . ,org-ts-regexp)
			                                          ("%u" . ".*?")
			                                          ("%U" . ".*?")))) "\\(?: \\\\\\)*")
  "A regexp to match the notes for a change in state")


(defconst org-rt-break-string "--"
  "The magic string that denotes the end of an entry in an RT 1.0 API response")

(defconst org-rt-query-assigned              "Owner = '%s'"
  "The query string used to find all tickets assigned to a user")
(defconst org-rt-query-assigned-resolved     "Owner = '%s' AND Status = 'resolved'"
  "The query string used to find all resolved tickets assigned to a user")
(defconst org-rt-query-assigned-not-resolved "Owner = '%s' AND Status != 'resolved'"
  "The query string used to find all open tickets assigned to a user")

(defconst org-rt-link-property-map '(("Parents" . "MemberOf") ("Children" . "Members")
                                     ("Blockers" . "DependsOn") ("Blocking" . "DependedOnBy")))

(defconst org-rt-property-map (append
                               '(("RT_ID" . "id") ("Effort" . "TimeEstimated"))
                               org-rt-link-property-map)

  "An alist that contains a mapping of values that aren't represented 1:1 by the org properties
This includes the id being mapped to RT_ID and all dependency/children values being changed")

(defconst org-rt-field-blacklist '("id" "MemberOf" "Members" "DependsOn" "DepndedOnBy" "Status" "RefersTo" "ReferredToBy")
  "A list of fields to ignore when updating via setting fields,
as these need to be set in specific ways")

(defconst org-rt-fields '("id" "Queue" "Requestor" "Owner" "Creator" "Subject" "Status" "Priority" "InitialPriority" "FinalPriority" "Requestors" "Created" "Starts" "Started" "Due" "Resolved" "Told" "LastUpdated" "TimeEstimated" "TimeWorked" "TimeLeft")
  "A list of all fields used by RT")

(defconst org-rt-property-transform-map `(("Effort" . ,#'org-rt--effort-transform))
  "An alist of functions to transform the values")

(defconst org-rt-comment-fields '("Created" "Creator" "Content" "id") "") ;

(defconst org-rt-timer-list '(
                              (org-rt--create-tickets-missing . 30)
                              (org-rt--complete-resolved-tickets . 60)
                              (org-rt-refresh-cache . 30)
                              )
  "A list of functions to create timers for upon initialization
and to remove upon de-initialization")

(defconst org-rt-note-capture-buffer
  "*Org Note*"
  "The name of the buffer to use for note captures in org-rt")

(defconst org-rt-note-capture-text
  "# Write your comment in orgmode here
# It will be exported as HTML or UTF8 and submitted
# Finish with C-c C-c or cancel with C-c C-k\n\n"
  "A string that will be inserted when capturing a note in org-rt")

(defconst org-rt-link-path "%s/Ticket/Display.html?id=%s"
  "The path of a ticket in the RT UI as a string format
The first %s is the base URI (e.g. https://rt.com/rt/)
The second %s is the id of the ticket")



(defvar org-rt-note-return-to (make-marker)
  "The location to return to after creating a note")
(defvar org-rt-note-window-configuration nil
  "The window configuration to restore after creating a note")
(defvar org-rt-note-finish-hook nil
  "A hook to call when a note has been exported and is ready to be processed")
;; TODO use this on more functions
(defvar org-rt-ignore-hooks nil
  "Ignore all hooks when set to t")

(defvar org-rt-need-id-refresh t
  "Refresh ids when set to t")

(defvar org-rt-pre-close-note-count nil
  "Used to determine if a new note has been added")

(defvar org-rt-task-cache nil
  "A cached list of all assigned tasks
Used mainly to ensure certain actions are fast and non-blocking

Specifically HELM searches")

;;; ------------------------------------------------------------------
;;; Customizable variables
;;; ------------------------------------------------------------------

(defgroup org-rt nil
  "*org-rt, the Emacs OrgMode interface to RT"
  :prefix "org-rt"
  :group 'org-rt)

(defcustom org-rt-capture-templates `(("W" "RT" entry
                                        (file+headline ,(expand-file-name
                                                        "inbox.org"
                                                        org-directory)
                                                       "Tasks")
                                        "* TODO [[rt:%:id][RT%:id]] - %:subject
:PROPERTIES:
:ID: RT%:id
:RT_ID: %:id
:URL: %(org-rt-link--get-url \"\")%:id
:Owner: %:owner
:Creator: %:creator
:Status: %:status
:Priority: %:priority
:Created: %:created
:Due: %:due
:LastUpdated: %:lastupdated
:Parents: %:parents
:Children: %:children
:Blocking: %:blocking
:Blockers: %:blockers
:RefersTo: %:refersto
:ReferredToBy: %:referredtoby
:END:
** Description
%:description" :immediate-finish t))
  "An alist of all capture templates to use for a task
This list will be appended to the existing `org-capture-templates' list")

(defcustom org-rt-todo-function-map '(("TODO" . org-rt--open-task-pom)
                                      ("DONE" . org-rt--org-after-todo-done))
  "Alist of functions to call on a TODO state change in org
The car should be a TODO state, and the CDR a single function"
  :type '(alist :key-type string :value-type function)
  :group 'org-rt)

(defcustom org-rt-auth-function #'org-rt--get-rest-auth
  "The function used to procure authentication credentials
Currently this must return an alist with `user' and `pass'"
  :type '(function)
  :group 'org-rt)

(defcustom org-rt-username ""
  "The username to use for authentication and default username for assigned queries"
  :type 'string
  :group 'org-rt)

(defcustom org-rt-password ""
  "The password to use for authentication"
  :type 'string
  :group 'org-rt)

(defcustom org-rt-rest-endpoint "http://localhost:8080/rt/REST/1.0"
  "The HTTP endpoint to send REST requests to"
  :type 'string
  :group 'org-rt)

(defcustom org-rt-blocking-heading "Subtasks"
  "The heading name to file blocking tasks under as subtasks"
  :type 'string
  :group 'org-rt)

(defcustom org-rt-default-capture-template "W"
  "The key used for the capture template that we will fill out
This can be any key defined in `org-capture-templates' or
`org-rt-capture-templates'"
  :type 'string
  :group 'org-rt)

(defcustom org-rt-custom-resolve-list
  nil
  "A list of cons to set on the ticket when closing
This is for my usecase where a ticket needs to have specific custom
fields set before it can be marked as resolved."
  :type '(alist :key-type string :value-type string)
  :group 'org-rt)

(defcustom org-rt-todo-state-map '((todo . (("TODO" "NEXT")
                                             ("new" "open" "stalled")))
                                   (done . (("DONE")
                                             ("resolved" "rejected"))))
  "An alist of two lists, the car of the alist are the symbols todo or done
The first list is the org todo words
The second list is RT todo words"
  :type '(alist :key-type symbol :value-type (list (list string)))
  :group 'org-rt)


(defcustom org-rt-note-export-html t "If notes should be exported as html"
  :type 'boolean
  :group 'org-rt)

(defcustom org-rt-note-export-function-html
  #'org-rt--note-convert-region-html
  "The function to call when exporting to HTML
The function must expect no arguments and peroform the conversion
on an active region only."
  :type 'function
  :group 'org-rt)

(defcustom org-rt-note-export-function-plain
  #'org-ascii-convert-region-to-utf8
  "The function to call when exporting to plain-text
The function must expect no arguments and peroform the conversion
on an active region only."
  :type 'function
  :group 'org-rt)

(defcustom org-rt-goto-use-stack t "Use xref marker stack when jumping"
  :type 'boolean
  :group 'org-rt)

(defcustom org-rt-mode-key-map-prefix "R"
  "The keymap prefix"
  :type 'string
  :group 'org-rt)

;;TODO nested alist for prefixes
(defcustom org-rt-mode-key-map '(("y" . org-rt-task-yank-id)
                                 ("Y" . org-rt-task-yank-url)
                                 ("o" . org-rt-task-open-url)
                                 ("O" . org-rt-task-open)
                                 ("c" . org-rt-create-ticket)
                                 ("C" . org-rt-task-comment)
                                 ("d" . org-rt-task-complete)
                                 ("f" . org-rt-task-find-or-create)
                                 ("F" . org-rt-assigned-fetch)
                                 ("G" . org-rt-task-goto)
                                 ("T" . org-rt-ticket-take)
                                 ("g p" . org-rt-goto-parent)
                                 ("g c" . org-rt-goto-child)
                                 ("g b" . org-rt-goto-blocker)
                                 ("g B" . org-rt-goto-blocking)
                                 ("l r" . org-rt-add-reference)
                                 ("l R" . org-rt-add-referenced-by)
                                 ("l p" . org-rt-add-parent)
                                 ("l c" . org-rt-add-child)
                                 ("l b" . org-rt-add-blocker)
                                 ("l B" . org-rt-add-blocking)
                                 ("L r" . org-rt-remove-reference)
                                 ("L R" . org-rt-remove-referenced-by)
                                 ("L p" . org-rt-remove-parent)
                                 ("L c" . org-rt-remove-child)
                                 ("L b" . org-rt-remove-blocker)
                                 ("L B" . org-rt-remove-blocking)
                                 )
  "The initial keymap to be defined.
It is prefixed with `org-rt-mode-key-map-prefix' and `C-C'
If spacemacs is installed it will add itself to the minor-mode-map there"
  :type '(alist :key-type string :value-type function)
  :group 'org-rt)

(defcustom org-rt-link-endpoint "https:////rt.remoteserver.com.au/rt"
  "The URL of the RT instance")

(defcustom org-rt-link-open "firefox '%s'"
  "The command to run to open the link.
Where %s is replaced with the URL of the ticket")



;;; ------------------------------------------------------------------
;;; Org Note functions
;;; ------------------------------------------------------------------
(defmacro org-rt-after-note (&rest body)
  "Will execute `body' after exporting org-note with `export'
`export' is a function-symbol that will be called with a region to convert"
  `(progn
       (setq org-rt-note-window-configuration (current-window-configuration))
       (move-marker org-rt-note-return-to (point))
       (org-switch-to-buffer-other-window org-rt-note-capture-buffer)
       (erase-buffer)
       (let ((org-inhibit-startup t)) (org-mode))
       (insert org-rt-note-capture-text)
       (setq-local org-finish-function #'org-rt--store-note)

       (let ((symbol (make-symbol "org-rt-note-finish-func")))
         (fset symbol (lambda() ,@body))
         (setq-local org-rt-note-finish-function symbol)
         )
       (setq-local org-rt-note-export-func
                   (if org-rt-note-export-html
                       org-rt-note-export-function-html
                     org-rt-note-export-function-plain)
                   )
       )
  )
;; TODO Work without heading
(defun org-rt--note-convert-region-html (&optional keep-toc)
    ;; Go back to the begining of the buffer
  (org-html-convert-region-to-html)
  (setq mark-active nil)
  (goto-char (point-min))

  ;; Remove the toc
  ;; Look for the first heading div
  (unless keep-toc
    (when (re-search-forward "<div id=\"outline-container-org"
                             (point-max) t)
      ;; Find the first div behind that
      (re-search-backward "</div>")

      ;; Kill the region from the start to the END of the div behind
      ;; the outline div
      ;; TODO This isn't elegant but it works well enough
      (kill-region (point-min) (re-search-forward "</div>")))
    )
  )

(defun org-rt--store-note ()
  (let ((org-rt-note-export-func org-rt-note-export-func)
        (org-rt-note-finish-function org-rt-note-finish-function)
        (contents (prog1 (buffer-string)
                    (kill-buffer))))

    (with-temp-buffer
      (unless org-note-abort
        (insert contents)
        (goto-char (point-min))

        ;; Remove comments
        (replace-regexp "\\# .*\n[ \t\n]*" "")
        (replace-regexp "\\s-+\\'" "")

        ;; Create an active region of the whole buffer
        (let ((p1 (point-min))
              (p2 (point-max)))
          (goto-char p1)
          (push-mark p2)
          (setq mark-active t)

          (funcall org-rt-note-export-func)
          )
        ;; Finally run the hooks that want the raw HTML in a clean buffer
        (goto-char (point-min))
        (when (fboundp org-rt-note-finish-function)
          (funcall org-rt-note-finish-function)
          )
        (run-hooks 'org-rt-note-finish-hook)

        ;; Cleanup
        (set-window-configuration org-rt-note-window-configuration)
        (with-current-buffer (marker-buffer org-rt-note-return-to)
          (goto-char org-rt-note-return-to))
        (move-marker org-rt-note-return-to nil)
        )
      )
    )
)
;;; ------------------------------------------------------------------
;;; Helper/util functions
;;; ------------------------------------------------------------------


(defun org-rt--join (lst sep &optional pre post)
  (mapconcat (function (lambda (x) (concat pre x post))) lst sep))

;; TODO make string &rest and deal with listp
(defun org-rt--string-match-group (regexp group string)
  "Return a match `group' from `string' that matches `regexp'
This is a helper function designed to shrink the lines of code"
  (when string
    (prog2
        (string-match regexp string)
        (match-string-no-properties group string)
      ))
  )

(defun org-rt--not-cdr (element)
  "Helper function that returns t if `cdr' of `element' is nil"
  (not (cdr element)))

(defun org-rt--force-int (object)
  (cond ((stringp object) (string-to-number object))
        ((markerp object) nil)
        ((numberp object) object)
        ((floatp object) object)
        ))

(defun org-rt--add-to-list-n (element list n)
  (let* ((pre-list (reverse (nthcdr (- (seq-length list) n) (reverse list))))
         (post-list (nthcdr n list)))
    (append pre-list (list element) post-list)
    )
  )

(defun org-rt--assocdr (alist &rest key-list)
  (let ((keys (flatten-list key-list))
        (cur alist))
    (if (> (seq-length keys) 1)
        (org-rt--assocdr (cdr (assoc (car keys) alist)) (cdr keys))
        (cdr (assoc (car keys) alist))
        )
    )
  )

(defun org-rt--nthcar (n list &optional reverse)
  (reverse (nthcdr (if reverse n (- (seq-length list) n))
                   (reverse list))))

(defun org-rt--alist-pluck-keys (alist &rest keys)
  (remove nil (org-rt--alist-to-list alist (flatten-list keys)))
  )

(defun org-rt--alist-to-list (alist &rest keys)
  (cl-loop for (key . value) in alist
           collect (when (or (not keys)
                             (member key (flatten-list keys)))
                     value)
           )
  )

(defun org-rt--alist-values (alist)
  (cl-loop for (key . value) in alist collect value))

(defun org-rt--alist-keys (alist)
  (cl-loop for (key . value) in alist collect key))

(defun org-rt--alist-swap-car (alist)
  (cl-loop for (key . value) in alist collect (cons value key)))

(defun org-rt--idle-timer-once (time repeat function)
  (let ((function-name (symbol-name function)))
    (unless (seq-filter (lambda (timer) (when (symbolp (aref timer 5))
                                          (string= (symbol-name (aref timer 5)) function-name)))
                        timer-idle-list)
      (run-with-idle-timer time repeat function))
    )
  )
(defun org-rt--idle-timer-remove (function))

(defconst org-rt-property-map-rev (org-rt--alist-swap-car org-rt-property-map)
  "Reversed property map, to simplify code in sections")

;;; ------------------------------------------------------------------
;;; Helm util functions
;;; ------------------------------------------------------------------


;;; ------------------------------------------------------------------
;;; ID util functions
;;; ------------------------------------------------------------------

(defun org-rt--strip-id-prefix (id)
  "Remove `RT' from the `ID' if it exists within `id'"
  (if (string= (substring-no-properties id nil 2) "RT")
    (substring-no-properties id 2)
    id
    )
  )

(defun org-rt--add-id-prefix (id)
  "Add `RT' to the `id' if it does not exist within `id'"
  (unless (string= (substring-no-properties id nil 2) "RT")
    (concat "RT" id)
    )
  )

(defun org-rt--extract-numerical-id (id)
  "Extract the numeric RT ID from `id'"
  (org-rt--string-match-group org-rt-id-regexp 1 id)
  )

;;; ------------------------------------------------------------------
;;; Parser functions
;;; ------------------------------------------------------------------
(defun org-rt--queue-parser-f ()
  (let ((queues '()))
    (while (re-search-forward org-rt-queue-regexp (point-max) t)
      (let ((id (match-string-no-properties 1))
            (name (match-string-no-properties 2)))
        (push (cons id name) queues)
        )
      )
    (reverse queues)
    )
  )

(defun org-rt--new-ticket-parser-f ()
  (when (re-search-forward org-rt-new-ticket-regexp (point-max) t)
    (match-string-no-properties 1))
  )
(defun org-rt--description-parser-f ()
  "Faster parser for finding the first multiline content in a RT API 1.0 response
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--descrption-parser-f)'"
  (let ((attachments )))
  (re-search-forward org-rt-content-key-regexp (point-max) t)
  (let ((field-name (match-string-no-properties 1))
        (field-value (match-string-no-properties 2))
        (attach-point (save-excursion (re-search-forward org-rt-attach-key-regexp (point-max) t))))
    (while (re-search-forward (format org-rt-continue-regexp (length field-name)) attach-point t)
      (let ((continuation (match-string-no-properties 2))
            ;; (padding-printf (format "%%%ds" (length field-name)))
            (padding (match-string-no-properties 1))
            )
        (unless (string-empty-p continuation)
          ;; (setq field-value (concat field-value "\n" (format padding-printf continuation)))
          (setq field-value (concat field-value "\n" (concat padding continuation)))
          )
        ))
    field-value
       )
  )

(defun org-rt--history-short-parser-f ()
  "A parser function to parse the short history of a RT ticket from an RT API 1.0 response
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--history-short-parser-f)'"
  (let (history-list)
    (while (re-search-forward org-rt-history-short-regexp (point-max) t)
      (push (cons (match-string-no-properties 1) (match-string-no-properties 2)) history-list)
      )
    (reverse history-list)
  )
  )

(defun org-rt--history-parser-f ()
  "A parser function to parse the long history format of an RT Ticket given an RT API 1.0 response

This is probably the slowest parser, that also has to deal with the most content, use sparingly
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--history-parser-f)'"
  (let (tickets ticket (field-value "")
                (ticket-continue t) (list-continue t))
    (while
        ;; Keep going as long as we have IDs ahead
        (re-search-forward org-rt-id-key-regexp (point-max) t)
      (let ((history-id (match-string-no-properties 1))
            (next-id (or (save-excursion (re-search-forward org-rt-id-key-regexp (point-max) t))(point-max)))
            (next-break (or (save-excursion (re-search-forward org-rt-break-string (point-max) t)) (point-max))))
        ;; While we're on the same ticket find field entries
        (while (and ticket-continue
                    (re-search-forward
                     org-rt-key-regexp
                     (if (<= next-break (point)) next-id next-break) t))
          (let ((field-name (match-string-no-properties 2))
                (field-value (match-string-no-properties 3))
                (next-key (or (save-excursion (re-search-forward org-rt-key-regexp (point-max) t)) (point-max))))
            (if (or (string= field-name "Content") (string= field-name "Attachments"))
                (while (and list-continue
                            (re-search-forward
                             (format org-rt-continue-regexp (length field-name))
                             next-key t))
                  (let ((continuation (match-string-no-properties 2))
                        ;; (padding-printf (format "%%%ds" (length field-name) ))
                        (padding (match-string-no-properties 1))
                        )
                    (unless (string-empty-p continuation)
                      ;; (setq field-value (concat field-value "\n" (format padding-printf continuation)))
                      (setq field-value (concat field-value "\n" (concat padding continuation)))
                      )
                    )
                  ))
            (push (cons field-name field-value)
                  ticket)
            )
          (setq field-value nil list-continue t)
          )
        (push (cons history-id (copy-sequence ticket)) tickets)
        (setq ticket nil ticket-continue t)))
    (reverse tickets)))

(defun org-rt--link-parser-f ()
  "A parser function to parse the links of an RT Ticket given an RT API 1.0 response
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--link-parser-f)'"

  (let (links)
    (re-search-forward org-rt-id-key-regexp (point-max) t)
    (while (re-search-forward org-rt-key-regexp (point-max) t)
      (let* ((field-name (match-string-no-properties 2))
             (first-link (match-string-no-properties 3))
             (next-key (save-excursion
                             (re-search-forward org-rt-key-regexp (point-max) t)))
              (link-list (list (org-rt--string-match-group org-rt-link-regexp 1 first-link))));;
        (while (re-search-forward (format org-rt-continue-regexp (length field-name)) (or next-key (point-max)) t)
            (push (org-rt--string-match-group org-rt-link-regexp 1
                                              (match-string-no-properties 0))
                  link-list)
          )
        (push (cons field-name link-list) links)
        )
          )
    (reverse links)
    )
  )

(defun org-rt--show-parser-f ()
  "A parser function to parse the show response of an RT API 1.0 call for a ticket
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--show-parser-f)'"
  (let (ticket
        (id (cons "id" (prog2
                           (re-search-forward org-rt-id-key-regexp (point-max) t)
                           (match-string-no-properties 1)))))
    (when id
      (push id ticket)
      (while (re-search-forward org-rt-key-regexp (point-max) t)
        (let ((field-name (match-string-no-properties 2))
              (field-value (match-string-no-properties 3))
              (next-key (or (save-excursion (re-search-forward org-rt-key-regexp (point-max) t)) (point-max))))
          (while (re-search-forward
                  (format org-rt-continue-regexp (length field-name))
                  next-key t)
            (let ((continuation (match-string-no-properties 2))
                  ;; (padding-printf (format "%%%ds" (length field-name)))
                  (padding (match-string-no-properties 1))
                  )
              (unless (string-empty-p continuation)
                ;; (setq field-value (concat field-value "\n" (format padding-printf continuation)))
                (setq field-value (concat field-value "\n" (concat padding continuation)))
                )))
          (push (cons field-name field-value)
                ticket))))
    (reverse ticket)
    )
  )

(defun org-rt--search-parser-f ()
  "A parser function to parse the search response of an ART API 1.0 call
Needs to be run from the minimum point of a buffer
Usage: `(request url :parser #\'org-rt--search-parser-f)'"
  (let (tickets)
    (next-line)
    (while (re-search-forward org-rt-id-regexp (point-max) t)
      (push (match-string-no-properties 1) tickets))
    (reverse tickets)))

(defun org-rt--test-parser ()
  "Provides a method of discovering the contents of a buffer that would usually be parsed"
  ;; (message (buffer-file-name (current-buffer)))
  ;; (message (buffer-substring-no-properties (point-min) (point-max)))
  (buffer-substring-no-properties (point-min) (point-max))
  )

(defun org-rt--parse-comment (comment)
  "Replace newlines with newlines preceeded by a space for multiline comments"
  (replace-regexp-in-string "\n" "\n " comment)
  )

;;; ------------------------------------------------------------------
;;; Helper REST Functions
;;; ------------------------------------------------------------------
(defun org-rt--get-rest-string (query-string)
  "Returns a formatted string appending `org-rt-rest-endpoint' and `query-string'"
  (format "%s/%s" org-rt-rest-endpoint query-string)
  )

(defun org-rt--make-params (params)
     "Creates an alist of both `params' and the auth alist
It retrieves the auth alist from `org-rt-auth-function'"
     (let ((param (funcall org-rt-auth-function)))
       (setq param (append param params))
       ))

(defun org-rt--auth-source-get (&optional username hostname)
  (let* ((url (unless hostname
               (string-match org-rt-url-regexp org-rt-rest-endpoint)))
        (port (match-string-no-properties 3 org-rt-rest-endpoint))
        (path (match-string-no-properties 4 org-rt-rest-endpoint))
        (host (or hostname (format
                            "%s:%s/%s"
                            (match-string-no-properties 2 org-rt-rest-endpoint)
                            port
                            path)))
        (user (or username org-rt-username)))
    (let ((found (nth 0 (auth-source-search :host host :user user))))
      (when found
        (let ((secret (plist-get found :secret)))
	        (when (functionp secret)
	          (funcall secret)))))))

(defun org-rt--get-rest-auth ()
  ;; TODO add option to turn off authinfo search
  "Returns an alist containing the `user' and `pass' params for HTTP authentication
`user' is retrieved from `org-rt-username'
`pass' is retrieved from authinfo first, then `org-rt-password'"
  (let ((password (or (org-rt--auth-source-get org-rt-username)
                      org-rt-password)))
    `(("user" . ,org-rt-username)
      ("pass" . ,password))
    )
  )

;;; ------------------------------------------------------------------
;;; Wrapper REST request functions
;;; ------------------------------------------------------------------

(defun org-rt--request (path parser &optional method params data no-wait)
  "A helper function that does a synchronous request to the RT API
`path' is the path to append to the API endpoint
`parser' is a function that will be called to parse the response
`method' is the HTTP method (GET, PUT, POST, etc)
`params' is an alist of HTTP get params to be added to the URL (?param=value&such)
`data' is an alist of HTTP post data to be sent"
  ;; For some reason occasionally :sync t just breaks until restart
  (let ((request (request (org-rt--get-rest-string path)
                   :type method
                   :params (org-rt--make-params params)
                   :parser parser
                   :data data
                   )))
    (unless (or (not parser) no-wait)
      (while (not (request-response-done-p request))
        (sleep-for 0.1))
      (request-response-data request))
    ))

(defun org-rt--request-async (path parser callback &optional method params data)
  "A helper function that does a synchronous request to the RT API
`path' is the path to append to the API endpoint
`parser' is a function that will be called to parse the response
`callback' is a function that will be called with the parsed response
`method' is the HTTP method (GET, PUT, POST, etc)
`params' is an alist of HTTP get params to be added to the URL (?param=value&such)
`data' is an alist of HTTP post data to be sent"
  ;; For some reason occasionally :sync t just breaks until restart
  (let ((request (request (org-rt--get-rest-string path)
                   :type method
                   :params (org-rt--make-params params)
                   :parser parser
                   :data data
                   :success callback
                   )))
    ))

(defun org-rt--requests-async (method parser &optional car-id &rest paths)
  "Sends multiple async requests and awaits their response before returning
`method' HTTP method (GET, PUT, POST, etc)
`parser' a function that will parse the response
when `car-id' is non-nil, each item will be returned as a cons with the car being the id
`paths' either a list of strings OR a lsit of alists that contain `path', `params' and `data' cons
    which will be applied to each request"
  ;;(org-rt--requests-async "GET" #'org-rt--history-parser-f '((("path" . "ticket/159343/history") ("params" . (("format" . "l")))) (("path" . "ticket/160881/history") ("params" . (("format" . "l"))))))
  (let* ((finished-requests (list))
         (requests (mapcar (lambda (path)
                             (if (and (listp path) (assoc "path" path))
                                 (request (org-rt--get-rest-string (cdr (assoc "path" path)))
                                   :type method
                                   :parser parser
                                   :data (cdr (assoc "data" path))
                                   :params (org-rt--make-params (cdr (assoc "params" path))))
                             (request (org-rt--get-rest-string path)
                                            :type method
                                            :parser parser
                                            :params (org-rt--make-params nil))
                             ))
                           (car paths)
                           )))

    (when parser
      (while requests
        (sleep-for 1)
        (mapcar (lambda (request)
                  (when (request-response-done-p request)
                    (setq requests (delete request requests))
                    (setq finished-requests (append finished-requests (list request)))))
                requests))
      (if car-id
          (mapcar
           (lambda (request)
             (cons
              (org-rt--string-match-group
               org-rt-id-regexp 1 (org-rt--string-match-group
                                   org-rt-url-path-regexp 1
                                   (request-response-url request)))
              (request-response-data request)))
           finished-requests)
        (mapcar #'request-response-data finished-requests))
      )
    )
  )


;;; ------------------------------------------------------------------
;;; Analogues of rt-liber rest commands
;;; ------------------------------------------------------------------
(defun org-rt--rest-command-set (id key value)
  "Sets a field on a ticket with the name `key' on a ticket with `id' to `value'"
  ;; TODO Deal with multiline values (parse-comment)
  (let ((data `(("content" . ,(format "%s: %s" key value;; (url-hexify-string key) (url-hexify-string value)
                                      )))))
    (org-rt--request (format "ticket/%s/edit" id) nil "POST" nil data)
    )
  )

(defun org-rt--rest-show (&rest ids)
  "Request and parse the ticket data from the API given by `ids'
This is somewhat async"
  (org-rt--requests-async "GET" #'org-rt--show-parser-f nil
                          (mapcar (lambda (id) (format "ticket/%s/show" id)) (flatten-list ids)))
  )
(defun org-rt--rest-ls-query (query)
  "Return a list of IDs that return from `query'"
  (org-rt--request "search/ticket" #'org-rt--search-parser-f "GET"
                   `(("query" . ,query)
                     ("format" . "i")
                     ("orderby" . "+Created")))
     )

;;; ------------------------------------------------------------------
;;; Functions that provide an API to RT
;;; ------------------------------------------------------------------

(defun org-rt--get-queues ()
  (org-rt--request "search/queue" #'org-rt--queue-parser-f nil
                   '(("query" . "")))
  )

(defun org-rt--get-queue-names ()
  (org-rt--alist-values (org-rt--get-queues)))

;;; ------------------------------------------------------------------
;;; Functions for reading tickets
;;; ------------------------------------------------------------------
(defun org-rt--get-ticket (id)
  "Get the data of a single ticket with an id of `id'"
  (car (org-rt--rest-show id))
  )

(defun org-rt--get-tickets (&rest ids)
  "Get the data of all tickets with ids that match `ids'"
  (org-rt--rest-show ids)
  )

(defun org-rt--get-ids (query)
  "Get the IDs of tickets that match `query'"
  (org-rt--rest-ls-query query)
  )

;; TODO use async requests and async
(defun org-rt--construct-entry (id &optional fetch-description fetch-links fetch-history)
  "Construct a plist of a ticket with the id of `id'
`fetch-description' will fetch the tickets description
`fetch-links' will fetch links for the ticket (parents, blockers, etc)
`fetch-history' will fetch the whole history of a ticket, this is every slow"
  (let* ((ticket-thread (make-thread (lambda () (org-rt--get-ticket id))))
         (links-thread (make-thread (lambda () (when fetch-links
                                                 (org-rt--get-ticket-links id)))))
         (description-thread (make-thread (lambda () (when fetch-description
                                                       (org-escape-code-in-string
                                                        (org-rt--get-ticket-description id))))))
         (history-thread (make-thread (lambda () (when fetch-history
                                                   (org-rt--get-ticket-history id)))))
         (ticket (thread-join ticket-thread))
        (links (thread-join links-thread))
        (description (thread-join description-thread))
        (history (thread-join history-thread)))
    (list
     :id           (org-rt--extract-numerical-id
                   (cdr (assoc "id"            ticket)))
     :owner        (cdr (assoc "Owner"         ticket))
     :creator      (cdr (assoc "Creator"       ticket))
     :created      (cdr (assoc "Created"       ticket))
     :due          (cdr (assoc "Due"           ticket))
     :priority     (cdr (assoc "Priority"      ticket))
     :lastupdated  (cdr (assoc "LastUpdated"   ticket))
     :status       (cdr (assoc "Status"        ticket))
     :subject      (cdr (assoc "Subject"       ticket))
     :parents      (org-rt--join (cdr (assoc "MemberOf"      links)) " ")
     :children     (org-rt--join (cdr (assoc "Members"       links)) " ")
     :blockers     (org-rt--join (cdr (assoc "DependsOn"     links)) " ")
     :blocking     (org-rt--join (cdr (assoc "DependedOnBy"  links)) " ")
     :refersto     (org-rt--join (cdr (assoc "RefersTo"  links)) " ")
     :referredtoby (org-rt--join (cdr (assoc "ReferredToBy"  links)) " ")
     :description  description
     )
    )
  )

(defun org-rt--get-ids-assigned (&optional user)
  "Return a list of IDs of tickets assigned to `user' or `org-rt-username' if user is nil"
  (let ((username (or user org-rt-username)))
    (org-rt--get-ids (format org-rt-query-assigned-not-resolved username))
    )
  )

(defun org-rt--get-ticket-links (id)
  "Get the links of a ticket with the id of `id'"
  (org-rt--request (format "ticket/%s/links/show" id) #'org-rt--link-parser-f)
  )

(defun org-rt--get-tickets-links (car-id &rest ids)
  "Get the links of multiple tickets with their ids matching `id'"
  (org-rt--requests-async "GET" #'org-rt--link-parser-f car-id
                          (mapcar (lambda (id)
                                    (format "ticket/%s/links/show" id))
                                  ids)
                          )
  )

(defun org-rt--get-ticket-history-short (id)
  "Get the short history of a ticket with id of `id'"
  (org-rt--request (format "ticket/%s/history" id) #'org-rt--history-short-parser-f)
  )

(defun org-rt--get-tickets-history-short (car-id &rest ids)
  (org-rt--requests-async "GET" #'org-rt--history-short-parser-f car-id
                          (mapcar (lambda (id)
                                    (format "ticket/%s/history" id))
                                  ids)
                          )
  )

(defun org-rt--get-ticket-history (id)
  (org-rt--request (format "/ticket/%s/history/" id) #'org-rt--history-parser-f nil '(("format" . "l")))
  )

(defun org-rt--get-tickets-history (car-id &rest ids)
  (org-rt--requests-async "GET" #'org-rt--history-parser-f car-id
                          (mapcar (lambda (id)
                                    (list (cons "path" (format "ticket/%s/history" id))
                                          (cons "params" '(("format" . "l")))))
                                  ids)
                          )
  )

(defun org-rt--get-ticket-description (id)
  (org-rt--request (format "ticket/%s/history/id/%s" id
                           (caar(org-rt--get-ticket-history-short id)))
                   #'org-rt--description-parser-f)
  )

(defun org-rt--get-tickets-description (car-id &rest ids)
  (org-rt--requests-async
   "GET" #'org-rt--description-parser-f car-id
             (mapcar
              (lambda (history-list)
                (format "ticket/%s/history/id/%s"
                        (car history-list)
                        (caadr history-list)))
              (apply #'org-rt--get-tickets-history-short
                       (append '(t) ids)))))

(defun org-rt--get-ticket-history-entry (id history-id)
  (append (list (cons "id" history-id))
  (remove history-id
          (car (org-rt--request
                (format "ticket/%s/history/id/%s" id history-id)
                   #'org-rt--history-parser-f)))))

(defun org-rt--get-ticket-comments (id)
  "Get a list of alists with details regarding a comment for a ticket
with the id of `id'"
  ;; Remove useless nil values returned by the mapcar
  (remove nil (mapcar
   (lambda (history)
     ;; Only expand the history for those who's description
     ;; looks like a comment
     (when (string-match-p
            "Comments added by [[:alpha:]]+"
            (cdr history))
       (let ((entry (org-rt--get-ticket-history-entry
                     id (car history))))
         ;; Ensure that it's __actually__ a comment
         (when (string= (cdr (assoc "Type" entry)) "Comment")
           ;; Only return the fields useful for a comment
           ;; Defined in `org-rt-comment-fields'
           (seq-filter (lambda (cons)
                         (if (consp cons)
                             (member (car cons) org-rt-comment-fields)
                           t))
                       entry)
           )
         )
       ))
   (org-rt--get-ticket-history-short id)))
  )


;;; ------------------------------------------------------------------
;; Functions related to orgmode finding
;;; ------------------------------------------------------------------


(defun org-rt-refresh-cache (&optional no-update-org-id)
  (interactive)
  (unless no-update-org-id
    (org-id-update-id-locations nil t))
  (setq org-rt-task-cache (mapcar
                           (lambda (cons)
                             (let* ((id (car cons))
                                    (marker (cdr cons))
                                    (title (org-entry-get
                                           marker
                                           "ITEM")))
                               (when title
                                 (cons id (org-link-display-format title))
                                 )))
                           (org-rt--find-tickets (org-rt--get-ids
                                                  (format org-rt-query-assigned
                                                          org-rt-username)))
                           ))
  )

(defun org-rt--find-ticket (id &optional markerp car-id)
  "Find the location of a ticket within orgmode
when `markerp' is non-nil it will return the marker
when `car-id' is non-nil a cons will be returned where the car is the id"
  (let* ((pos (org-id-find (org-rt--add-id-prefix id) markerp))
         (file-name (if (number-or-marker-p pos)
                        (buffer-file-name (marker-buffer pos))
                      (car pos)
                      ))
         (archived (when file-name(string-match-p "\\.org_archive$" file-name))))
    (if car-id
        (cons id (unless archived pos))
      pos)))

(defun org-rt--find-tickets (&rest ids)
  (mapcar (lambda (id)
            (let ((file (gethash (format "RT%s" id)
                                 org-id-locations)))
              (cons id
                    (when (and file (not (string-match-p
                                          "\\.org_archive$" file)))
                      (org-id-find-id-in-file (format "RT%s" id)
                                              file t)))))
          (flatten-list ids))
  )

(defun org-rt--find-tickets-assigned (&optional user)
  "Find the location of all the tickets assigned to `user' in orgmode
if `user' is nil we will use `org-rt-username'"
  (org-rt--find-tickets (org-rt--get-ids-assigned user)))

(defun org-rt--find-tickets-missing (&optional user)
  "Return a list of tickets that do not exist in orgmode
when `user' is nil `org-rt-username' will be used"
  (flatten-tree (seq-filter (apply-partially #'org-rt--not-cdr)
                            (org-rt--find-tickets-assigned user))))

(defun org-rt--get-tickets-resolved (&optional user)
  "Return a list of IDs of tickets that are resolved and assigned to `user'
if `user' is nil `org-rt-username' will be used"
  (let ((username (or user org-rt-username)))
    (org-rt--get-ids (format org-rt-query-assigned-resolved username))
    )
  )

(defun org-rt--find-resolved-tickets (&optional user)
  "Find resolved ticket assigned to `user' that still exist inside org files"
  (seq-filter (apply-partially #'cdr)
              (org-rt--find-tickets
               (org-rt--get-tickets-resolved user)))
  )

(defun org-rt--find-subtasks-heading (pom &optional create)
  "This will find the subtask heading within the heading found at `pom' or point if `pom' is nil
if `create' is non-nil it will create the heading"
  (org-with-point-at pom
    (org-narrow-to-subtree)
    (if (re-search-forward
         (format org-complex-heading-regexp-format
                 (regexp-quote "Subtasks"))
         nil
         t)
        (point-marker)

      (when create
        (save-excursion
          (evil-save-state
            (if (org-goto-first-child)
                (org-insert-heading '(16))
              (org-insert-subheading nil))
            (insert "Subtasks"))
          (point-marker))))
    ))

(defun org-rt--find-state-notes-pom (&optional pom)
  (org-with-point-at pom
    (org-back-to-heading)
    (org-narrow-to-subtree)
    (let ((notes '()))
      (while (re-search-forward org-rt-state-notes-regexp nil t)
        (org-with-wide-buffer
         (org-narrow-to-element)
         (let ((note-start (save-excursion (re-search-forward "[ \t]+" nil t))))
           (when note-start
             (push (buffer-substring-no-properties note-start (- (point-max) 1))
                   notes)))))
      (reverse notes)))
  )
(defun org-rt--find-state-notes (&optional id)
  "Get a list of state notes from an org heading
if `id' is nil we will use the current point"
  (org-rt--find-state-notes-pom (org-id-find id t))
  )
;;; ------------------------------------------------------------------
;;; Functions for creating tickets
;;; ------------------------------------------------------------------
;; TODO make this async
(defun org-rt--capture-ticket (id &optional fetch-links fetch-history template)
  "This will capture a ticket in orgmode with the id of `id'
`fetch-links' allows links to be fetched
`fetch-history' will fetch history, but this is slow
`template' is the orgmode capture template to use when capturing"
  (let ((org-capture-link-is-already-stored t)
        (org-store-link-plist (org-rt--construct-entry id t fetch-links fetch-history))
        (org-capture-templates (append org-capture-templates org-rt-capture-templates)))
    (when (and (plist-get org-store-link-plist :id)
               (plist-get org-store-link-plist :subject))
      (org-capture nil (or template org-rt-default-capture-template)))
    )
  )

(defun org-rt--create-tickets-missing (&optional user)
  "An async function to create all tickets missing
as this runs on a timer and can take quite some time depending on the
amount of tickets needed to create"
  (message "Creating tickets in org we don't have")
  (mapcar (lambda (id)
                  (make-thread (lambda ()
                                 (org-rt--capture-ticket id t)))
                  )
                (org-rt--find-tickets-missing user)))

;;; ------------------------------------------------------------------
;;; Functions for making local changes to tickets
;;; ------------------------------------------------------------------

(defun org-rt--archive-resolved-tickets (&optional user)
  "Archive org mode entries of tickets from `user' that have been resolved
This will return a list of the IDs of the archived tickets"
  (mapcar (lambda (pom-pair)
            (org-with-point-at (cdr pom-pair) (org-archive-subtree))(car pom-pair))
          (org-rt--find-resolved-tickets user))
  (org-rt-refresh-cache)
  )

(defun org-rt--complete-resolved-tickets (&optional user)
  "Set the state of all resolved tasks assigned to `user' to DONE if it is not already
if `user' is nil `org-rt-username' will be used instead"
  (message "Completing resolved tickets")
  (mapcar (lambda (pom-pair)
            (org-with-point-at (cdr pom-pair)
              (unless (member (org-get-todo-state)
                              (cadr (assoc 'done org-rt-todo-state-map)))
                (let ((org-log-done nil)
                      (org-todo-log-states nil))
                  (org-todo 'done))
                (car pom-pair))))
          (org-rt--find-resolved-tickets user))
  )

(defun org-rt--refile-as-blocker (&optional pom)
  "Refile heading at `pom' or point if `pom' is nil to the subtasks heading in the first task that it blocks"
  (org-with-point-at pom
    (let* ((blocked-id (org-rt--add-id-prefix (car(org-entry-get-multivalued-property nil "Blocking"))))
           (subtask-heading-pom (org-rt--find-subtasks-heading (org-id-find blocked-id t) t)))
      (when (and (derived-mode-p 'org-mode) blocked-id)
        (org-refile nil nil
                    (list
                     "Subtasks"
                     (buffer-file-name(marker-buffer subtask-heading-pom))
                     nil
                     (marker-position subtask-heading-pom)))))))


;;; ------------------------------------------------------------------
;;; Functions for making remote changes to tickets
;;; ------------------------------------------------------------------

;; TODO Ensure type is set already
;; TODO Do not have type set in custom resolve variables
;; TODO Support functions for working out potential values
(defun org-rt--complete-task (id &optional message use-log-note org-done no-custom &rest fields)
  "Resolve an RT task with the id of `id'
if `message' is set that string will be commented before closing
if `message' is nil and `use-log-note' is t the string to be commented
will be pulled from the org log notes"
  (let ((task-data (org-rt--get-ticket id)))
    (unless no-custom
      (mapcar  (lambda (cons)
                 (let ((remote-value (cdr (assoc (car cons) task-data))))
                   (when (and remote-value (string-blank-p remote-value))
                     (org-rt--rest-command-set id (car cons) (cdr cons))
                     )
                   )
                 )
               org-rt-custom-resolve-list))
    ;; Can't run timer from timer?
    ;; (run-with-timer 2 nil #'org-rt--rest-command-set id "Status" "Resolved")
    ;; TODO Get only the first note and only if it's added when this is called
    ;; We already call a function after org-log-note-store
    ;; maybe we should add another before, and compare if a new one has been added
    (when (or message use-log-note)
      (org-rt--write-comment id (or message (car (org-rt--find-state-notes id)))))
    (org-rt--rest-command-set id "Status" "Resolved")
    (when org-done
      (org-with-point-at (org-id-find id t)
        (org-todo 'done)))

    )
  )

(defun org-rt--complete-task-pom (&optional pom message use-log-note
                                            org-done no-custom)
  "Complete a task at `pom' if `pom' is nil, (point) will be used"
  (org-rt--complete-task (org-entry-get pom "RT_ID") message
                         use-log-note org-done no-custom))

;; TODO support flag for setting only custom fields
(defun org-rt--set-fields (id fields &optional clobber );;custom-only)
  "Set fields of a ticket with the id of `id' to `fields'
`fields' must be an alist
when `clobber' is non-nil we will overwrite existing values"
  ;; If fields is nil it will not run
  (mapcar (lambda (cons)
            (let ((old-fields (unless clobber (org-rt--get-ticket id)))
                  (key (car cons))
                  (value (cdr cons)))
              (if old-fields
                  ;; Do not clobber, check if value is set before setting it
                  (let ((old-value (cdr (assoc key old-fields))))
                    (when (and old-value (string-blank-p old-value))
                      (org-rt--rest-command-set id key value)))
                ;; Clobber, we don't care if it was set
                (org-rt--rest-command-set id key value))
              )
            )
          fields)
  )

(defun org-rt--take-ticket (id &optional new-owner)
  (let ((id (org-rt--strip-id-prefix id))
        (owner (or new-owner org-rt-username)))
    (org-rt--set-fields id `(("Owner" . ,owner)) t)
    (org-rt--capture-ticket id t)
    )
  )

(defun org-rt--create-ticket (queue subject &optional requestor owner text priority estimate due starts status)
  "Create an RT ticket"
  (let* ((plain-text (if org-rt-note-export-html
                         (with-temp-buffer
                           (insert text)
                           (shr-render-region (point-min)
                                              (point-max))
                           (buffer-substring-no-properties
                            (point-min) (point-max)))
                       text
                       ))
         (content (substring (org-rt--join
                            (list
                             "id: ticket/new"
                             (format "Queue: %s" queue)
                             (format "Subject: %s" subject)
                             (format "Priority: %s" (or (org-rt--force-int priority) 0))
                             (format "Owner: %s" (or owner org-rt-username))
                             (when requestor
                               (format "Requestor: %s" (or requestor org-rt-username)))
                             (when estimate
                               (format "TimeEstimated: %s" estimate))
                             (when due
                               (format "Due: %s" due))
                             (when starts
                               (format "Starts: %s" starts))
                             (when status
                               (format "Status: %s" status))
                             (when plain-text
                               (format "Text: %s" (org-rt--parse-comment plain-text)))
                             )
                            "\n") nil -1))
         (id (org-rt--request
              "ticket/new" #'org-rt--new-ticket-parser-f "POST"
              nil (list (cons "content" content) (cons "attachment_1" "")))))
    (org-rt--capture-ticket id t)
    id
    )
  )

(defun org-rt--create-ticket-note (queue subject &optional requestor owner priority estimate due starts status)
  (org-rt-after-note
   (let* ((text (buffer-substring-no-properties (point-min) (point-max))))
     (org-rt--create-ticket queue
                            subject requestor
                            owner text priority
                            estimate due starts
                            status)
     ))
  )


(defun org-rt--write-comment (id &optional comment)
  "Write a comment with the content of `comment' to a ticket with id of `id'"
  (if comment
      (let* ((parsed-comment (org-rt--parse-comment comment))
             (content (format (org-rt--join
                               `("id: %s"
                                 "Action: comment"
                                 "Text: %s"
                                 ,(when org-rt-note-export-html "Content-Type: text/html")
                                 )
                               "\n")
                              id parsed-comment))
             (data `(("attachment_1" . "") ("content" . ,content))))
        (org-rt--request (format "ticket/%s/comment" id) nil "POST" nil data)
        )
    (org-rt-after-note
                       (org-rt--write-comment
                        id
                        (buffer-substring-no-properties (point-min) (point-max)))
                       )
  )
  )

(defun org-rt--open-task (id &optional message &rest fields)
  "Open a resolved ticket with `id'
if `message' is non-nil it will be added as a comment
`fields' should be a alist of fields to change"

  (org-rt--set-fields id fields t)
  (when message (org-rt--write-comment id message))
  (org-rt--rest-command-set id "Status" "Open")
  (org-with-point-at (org-id-find (org-rt--add-id-prefix id) t)
    (unless (string= (org-get-todo-state) "TODO")
      (org-todo 'todo))))

(defun org-rt--open-task-pom (&optional pom)
  "Open a resolved ticket at `pom'"
  (org-rt--open-task (org-entry-get pom "RT_ID")))

(defun org-rt--find-all-tasks ()
  (mapcar (lambda (id)
            (org-id-find (org-rt--add-id-prefix id) t)
            )
          (org-rt--get-ids (format org-rt-query-assigned org-rt-username)))
  )

(defun org-rt--get-all-task-names (&optional cdr-id)
  (mapcar (lambda (task)
            (if cdr-id
                (cons (cdr task) (car task))
              (cdr task)))
          org-rt-task-cache)
  )

(defun org-rt--get-task-name (id &optional cdr-id)
  (when id
    (let ((task (assoc id org-rt-task-cache)))
      (if cdr-id
          (cons (cdr task) (car task))
        (cdr task)))
  ))

(defun org-rt--get-all-tasks-helm (&rest ids)
  (remove '(nil)
          (if ids
              (mapcar (lambda (id) (org-rt--get-task-name id t))
                      (flatten-list ids))
            (org-rt--get-all-task-names t)))
  )
(defun org-rt--get-all-tasks-property-helm (property &optional pom)
  (org-rt--get-all-tasks-helm (org-entry-get-multivalued-property
                               pom property)))

(defun org-rt--link-remote (parent-id child-id &optional unlink blocker clobber no-update-local)
  "If `blocker' is `\'ref' then it will add a reference,
if it is any other non-nil value it will add a dependency,
if it is nil it will add as a member"
  (let* ((parent-key (cond ((eq blocker 'ref) "ReferredToBy")
                           ((not blocker)  "MemberOf")
                           (blocker    "DependedOnBy"))
                     )
         (child-key (cond ((eq blocker 'ref) "RefersTo")
                         ((not blocker)  "DependsOn")
                         (blocker    "Members"))
                    )
         (link-list (org-rt--get-tickets-links t parent-id child-id))
         (parents-existing (unless clobber (org-rt--assocdr link-list child-id parent-key)))
         (children-existing (unless clobber (org-rt--assocdr link-list parent-id child-key)))
         (parents-list (if unlink
                           (remove parent-id parents-existing)
                         (append (list parent-id) parents-existing)
                         ))
         (children-list (if unlink
                            (remove child-id children-existing)
                          (append (list child-id) children-existing)
                          )))
    (org-rt--request (format "ticket/%s/links" parent-id) nil "POST"
                     nil (list (cons "content"
                                     (format "%s: %s" child-key
                                             (org-rt--join children-list ",")))))
    (org-rt--request (format "ticket/%s/links" child-id) nil "POST"
                     nil
                     (list (cons "content"
                                 (format "%s: %s"
                                         parent-key (org-rt--join
                                                     parents-list ",")))))
    )
  (unless no-update-local (org-rt--link-tasks parent-id child-id blocker))
  )

(defun org-rt--link-local (parent-id child-id &optional unlink blocker update-remote)
  "If `blocker' is `\'ref' then it will add a reference,
if it is any other non-nil value it will add a dependency,
if it is nil it will add as a member"
  (let ((parent (org-id-find (org-rt--add-id-prefix parent-id) t))
        (child (org-id-find (org-rt--add-id-prefix child-id) t))
        (parent-prop (cond ((eq blocker 'ref) "ReferredToBy")
                          ((not blocker)  "Parents")
                          (blocker    "Blocking"))
                    ;; (if blocker "Blocking" "Parents")
                     )
        (child-prop (cond ((eq blocker 'ref) "RefersTo")
                          ((not blocker)  "Children")
                          (blocker    "Blockers"))
                    ;; (if blocker "Blockers" "Children")
                    )
        (prop-func (if unlink
                       #'org-entry-remove-from-multivalued-property
                     #'org-entry-add-to-multivalued-property)))
    (funcall prop-func parent child-prop child-id)
    (funcall prop-func child parent-prop parent-id)
    (unless (eq blocker 'ref) (org-rt--refile-as-blocker child)))
  (when update-remote (org-rt--link-tickets parent-id child-id blocker nil t))
  )

(defun org-rt--link-tickets (parent-id child-id &optional blocker clobber no-update-local)
  (org-rt--link-remote parent-id child-id nil blocker clobber no-update-local))



(defun org-rt--unlink-tickets (parent-id child-id &optional blocker clobber no-update-local)
  (org-rt--link-remote parent-id child-id t blocker blobber no-update-local)
  )

(defun org-rt--link-tasks (parent-id child-id &optional blocker update-remote)
  (org-rt--link-local parent-id child-id nil blocker update-remote)
  )

(defun org-rt--unlink-tasks (parent-id child-id &optional blocker update-remote)
  (org-rt--link-local parent-id child-id t blocker update-remote)
  )

(defun org-rt--link-pom (child-id &optional pom blocker update-remote)
  (org-with-point-at pom
    (let ((parent-id (org-entry-get nil "RT_ID")))
      (org-rt--link-local parent-id child-id nil blocker update-remote)
      )
    )
  )

(defun org-rt--unlink-pom (child-id &optional pom blocker update-remote)
  (org-with-point-at pom
    (let ((parent-id (org-entry-get nil "RT_ID")))
      (org-rt--link-local parent-id child-id t blocker update-remote)
      )
    )
  )

;;; ------------------------------------------------------------------
;;; Sync functions
;;; ------------------------------------------------------------------

(defun org-rt--sync-properties (pom property)
  (org-with-point-at pom
    (when (derived-mode-p 'org-mode)
    (let ((property-name (cdr (assoc (car property) org-rt-property-map-rev)))
          (property-value (cdr property)))
      (when (not property-name) (setq property-name (car property)))
      (let ((org-prop (org-entry-get nil property-name)))
        (when org-prop (org-entry-put nil property-name property-value))
        )
      )
    )
    )
  )

(defun org-rt--sync-subject (pom subject)
  (org-with-point-at pom
    (when (derived-mode-p 'org-mode)
      (org-back-to-heading)
      (when (and subject (not (string-empty-p subject))
                 (re-search-forward org-complex-heading-regexp
                                    (point-at-eol) t))
        (let ((heading-start (match-beginning 4))
              (id (org-entry-get pom "RT_ID")))
          (kill-region heading-start (point-at-eol))
          (goto-char heading-start)
          (insert (format "[[rt:%s][RT%s]] - %s" id id subject))
          (org-reveal)
          )
        )
      )
    )
  )

(defun org-rt--sync-show-pom (pom &optional id)
  (org-with-point-at pom
    (when (derived-mode-p 'org-mode)
      (let* ((id (or id (org-entry-get nil "RT_ID")))
             (ticket (org-rt--get-ticket id)))
        (mapcar (lambda (property)
                  (cond ((string= (car property) "Subject")
                         (org-rt--sync-subject pom (cdr property)))
                        ((member (car property) org-rt-field-blacklist)
                         (org-rt--sync-properties pom property))
                        )
                  )
                ticket)
        )
      )
    )
  )
(defun org-rt--sync-show (id)
  (org-rt--sync-show-pom (org-id-find (org-rt--add-id-prefix id) t))
  )

(defun org-rt--sync-links (id)
 (setq org-rt-ignore-hooks t)
  (let ((links (org-rt--get-ticket-links id)))
    (dolist (link links)
      (let ((link-name (org-rt--assocdr org-rt-property-map-rev (car link))))
        (when link-name
          (org-entry-put nil link-name (org-rt--join (cdr link) " "))
          )
        )
      ))
  (setq org-rt-ignore-hooks nil)
  )

(defun org-rt--sync-history (id))

(defun org-rt--sync-comments (id))

(defun org-rt--sync (id &optional sync-links sync-history sync-comments)
  (let ((pom (org-id-find (org-rt--add-id-prefix id) t)))
    (org-rt--sync-show-pom pom)
    (org-rt--sync-links id)
    )
  )
(defun org-rt--sync-all ()
  (mapcar (lambda (entry)
            (when (car entry)
              (org-rt--sync (car entry) t t t))
            )
          org-rt-task-cache)
  ;; TODO
  )

;;; ------------------------------------------------------------------
;;; Hook functions
;;; ------------------------------------------------------------------

;; TODO deal with multi values
;; TODO Deal with funky fields (parents)
(defun org-rt--org-property-changed-hook (property-name property-value)
  (when (and (assoc property-name org-rt-fields)
               (not (assoc property-name org-rt-field-blacklist))
               (not org-rt-ignore-hooks))
    (let* ((id (org-entry-get nil "RT_ID"))
           (field-name (cdr (assoc property-name org-rt-property-map)))
           (transform-function (cdr (assoc property-name org-rt-property-transform-map)))
           (parsed-value (when transform-function (apply transform-function (list property-value)))))
      (when id
        (org-rt--rest-command-set id
                                  (or field-name property-name)
                                  (or parsed-value property-value))))))
(defun org-rt--org-after-store-log-note ()
  (advice-remove 'org-store-log-note 'org-rt--org-after-store-log-note)
  (let ((new-count
         (seq-length (org-rt--find-state-notes-pom org-rt--todo-pom))))
    (org-rt--complete-task-pom
     org-rt--todo-pom nil t ;;(/= org-rt-pre-close-note-count new-count) TODO FIX
     )
    )
  (setq org-rt-pre-close-note-count 0)
  (setq org-rt--todo-pom nil))

(defun org-rt--org-after-todo-done (pom)
  (setq org-rt--todo-pom pom)
  (if (ignore-errors (set-buffer "*Org Note*"))
      (setq org-rt-pre-close-note-count
            (seq-length (org-rt--find-state-notes-pom pom)))
      (advice-add 'org-store-log-note :after 'org-rt--org-after-store-log-note)
    (org-rt--complete-task-pom pom)
    )
  )
(defun org-rt--org-after-todo-state-change-hook ()
  "Open task when org-state is TODO, resolve it when org-state is DONE"
  (when (and (derived-mode-p 'org-mode)
             (org-entry-get nil "RT_ID")
             (not org-rt-ignore-hooks))
    (let ((func (org-rt--assocdr org-rt-todo-function-map org-state)))
      (when func
        (save-excursion (org-back-to-heading)
                        (run-with-idle-timer 1 nil func (point-marker)))))
    ))
;;; ------------------------------------------------------------------
;;; Property transformation functions
;;; ------------------------------------------------------------------
(defun org-rt--effort-transform (effort)
  "Transforms an orgmode duration into a string formated like \"120 Minutes\""
  (format "%d Minutes" (org-duration-to-minutes effort)))


;;; ------------------------------------------------------------------
;;; RT Link handling
;;; ------------------------------------------------------------------
(defun org-rt-link--get-url (link)
  (format org-rt-link-path org-rt-link-endpoint link))

(defun org-rt-link--get-command (url)
  (format org-rt-link-open url))

(defun org-rt-link-make-description (link description)
  ;; TODO write some hook or something so that we aren't forever stealing this
  (if (string-match "^rt:\\([0-9]+\\)$" link)
      (format "RT%s" (match-string-no-properties 1 link))
    nil
    ))

(defun org-rt-link-open (link)
  "Open RT ticket in browser"
  (shell-command (org-rt-link--get-command
                  (org-rt-link--get-url link))))

(defun org-rt-store-link ()
  (let* ((id (org-entry-get-with-inheritance "RT_ID"))
         (description (org-link-display-format (org-entry-get nil "ITEM")))
         (link (when id (org-store-link-props
                         :type "rt"
                         :id id
                         :description description
                         :link (format "rt:%s" id)))))
    link))

(defun org-rt-link-export (link description format channel)
  "Export a link to the ticket from an orgmode link"
  (let ((path (org-rt-link--get-url link))
        (desc (or description link)))
    (pcase format
      (`html (format "<a target=\"_blank\" href=\"%s\">%s</a>" path desc))
      (`latex (format "\\href{%s}{%s}" path desc))
      (`texinfo (format "@uref{%s,%s}" path desc))
      (`ascii (format "%s (%s)" desc path))
      (_ path))))

(defun org-rt-link-complete ()
  (let ((id (helm :sources (helm-build-sync-source "Tasks"
                             :candidates (org-rt--get-all-tasks-helm)
                             :fuzzy-match t))))
    (when id (format "rt:%s" id))
    )
  )


(org-link-set-parameters "rt"
                         :follow #'org-rt-link-open
                         :export #'org-rt-link-export
                         :complete #'org-rt-link-complete
                         :store #'org-rt-store-link
                         )


;;; ------------------------------------------------------------------
;;; Interactive and user-facing functions
;;; ------------------------------------------------------------------

(defun org-rt-task-complete ()
  (interactive)
  (org-todo 'done)
  ;;(org-rt--complete-task-pom (point))
  )

;; TODO Allow message to be skipped with a prefix and have message be an orgmode capture buffer
(defun org-rt-task-open ()
  (interactive)
  (let ((id (org-entry-get (point) "RT_ID")))
    (org-rt-after-note
     (org-rt--open-task id (buffer-substring-no-properties
                            (point-min) (point-max)))
     )
    )
  )

(defun org-rt-task-comment ()
  (interactive)
  (org-rt--write-comment (org-entry-get (point) "RT_ID")))

(defun org-rt-task-find-or-create (id)
  (interactive "sID: ")
  (let ((marker (cdr (org-rt--find-ticket (org-rt--strip-id-prefix id) t t))))
    (if marker
        (progn (switch-to-buffer (marker-buffer marker)) (goto-char marker))
      (org-rt--capture-ticket (org-rt--strip-id-prefix id) t)
      (org-id-goto (org-rt--add-id-prefix id))
      )
    )
  )


(defun org-rt-task-goto (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                :candidates (org-rt--get-all-tasks-helm)
                                :fuzzy-match t))))
  (when id
    (when (and (fboundp #'xref-push-marker-stack) org-rt-goto-use-stack)
      (xref-push-marker-stack))
    (when (and (fboundp #'xref-push-marker-stack) org-rt-goto-use-stack)
      (xref-push-marker-stack))
    (org-id-goto (org-rt--add-id-prefix id)))
  )

(defun org-rt-goto-id-from-prop (property-name)
  (interactive (list
                (helm :sources
                      (helm-build-sync-source "Properties"
                        :candidates
                        (org-rt--alist-keys org-rt-link-property-map)
                        :fuzzy-match t))))
  (when (and property-name (not (string-empty-p property-name)))
    (let* ((property (org-entry-get-with-inheritance property-name))
           (ids (when (and property (not (string-empty-p property)))
                  (split-string property " ")))
           ;; If there's more then one use helm, otherwise just car it
           (id (when ids (if (> (seq-length ids) 1)
                             (helm :sources (helm-build-sync-source property-name
                                              :candidates (org-rt--get-all-tasks-helm ids)
                                              :fuzzy-match t)))
                     (car ids))))
      (org-rt-task-goto id))
    )
  )

(defun org-rt-goto-parent ()
  "Interactive function to jump to the selected parent"
  (interactive)
  (org-rt-goto-id-from-prop "Parents"))
(defun org-rt-goto-child ()
  "Interactive function to jump to the selected child"
  (interactive)
  (org-rt-goto-id-from-prop "Children"))
(defun org-rt-goto-blocker ()
  "Interactive function to jump to the selected blocker"
  (interactive)
  (org-rt-goto-id-from-prop "Blockers"))

(defun org-rt-goto-blocking ()
  "Interactive function to jump to the selected blocking"
  (interactive)
  (org-rt-goto-id-from-prop "Blocking"))

(defun org-rt-task-yank-id ()
  (interactive)
  (let ((id (org-entry-get nil "ID")))
    (if id
        (message "Yanked: %s" (kill-new id))
      (message "Could not get ID of task"))))


(defun org-rt-task-yank-url ()
  (interactive)
  (let ((url (org-entry-get nil "URL")))
    (if url
        (message "Yanked: %s" (kill-new url))
      (message "Could not get URL of task"))
    ))

(defun org-rt-task-open-url ()
  (interactive)
  (let ((url (org-entry-get nil "URL")))
    (if url
        (message "Visited: %s" (org-rt-open url))
      (message "Could not get URL of task"))
    ))


(defun org-rt-create-ticket (queue subject)
  (interactive (list (helm :sources (helm-build-sync-source "Queues"
                                      :candidates (org-rt--get-queue-names)
                                      :fuzzy-match t))
                     (helm-read-string "Subject: ")))
  (org-rt--create-ticket-note queue subject)
  )

(defun org-rt-add-reference (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets id current-id 'ref))
    )
  )

(defun org-rt-add-referenced-by (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets current-id id 'ref))
    )
  )

(defun org-rt-add-parent (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets id current-id))
    )
  )

(defun org-rt-add-child (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets current-id id))
    )
  )


(defun org-rt-add-blocker (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets current-id id t))
    )
  )

(defun org-rt-add-blocking (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-helm)
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--link-tickets id current-id t))
    )
  )

(defun org-rt-remove-reference (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "RefersTo")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets id current-id 'ref))
    )
  )

(defun org-rt-remove-referenced-by (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "ReferredToBy")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets current-id id 'ref))
    )
  )

(defun org-rt-remove-parent (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "Parents")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets id current-id))
    )
  )

(defun org-rt-remove-child (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "Children")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets current-id id))
    )
  )


(defun org-rt-remove-blocker (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "Blockers")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets current-id id t))
    )
  )

(defun org-rt-remove-blocking (id)
  (interactive (list (helm :sources (helm-build-sync-source "Tasks"
                                      :candidates (org-rt--get-all-tasks-property-helm
                                                   "Blocking")
                                      :fuzzy-match t))))
  (let ((current-id (org-entry-get nil "RT_ID")))
    (when current-id (org-rt--unlink-tickets id current-id t))
    )
  )

(defun org-rt-assigned-fetch ()
  (interactive)
  (org-rt--create-tickets-missing org-rt-username)
  )

(defun org-rt-ticket-take (id)
  (interactive "sTicket ID: ")
  (org-rt--take-ticket id org-rt-username)
  )
;; TODO New task from buffer
;; IE have the content of a new ticket in a buffer for editing (like mail file)
;; TODO new task from heading
;; TODO manual sync
;; TODO create history in heading
;; TODO create comments in heading
;; TODO attach file



;;; ------------------------------------------------------------------
;;; Hooks and timers
;;; ------------------------------------------------------------------


;;;###autoload
(define-minor-mode org-rt-mode
  "A mode for managing RT tickets in orgmode"
  :lighter " RT"
  :group 'org-rt
  :require 'org-rt
  :keymap (let ((keymap (make-sparse-keymap))
                (spacemacs (boundp 'spacemacs-version)))
            (when spacemacs
              (spacemacs/declare-prefix-for-mode 'org-mode "mR" "org-rt")
              (spacemacs/declare-prefix-for-mode 'org-mode "mRg" "org-rt-goto-tasks")
              (spacemacs/declare-prefix-for-mode 'org-mode "mRl" "org-rt-link-tasks")
              (spacemacs/declare-prefix-for-mode 'org-mode "mRL" "org-rt-unlink-tasks"))
            (dolist (map org-rt-mode-key-map)
              (define-key keymap (kbd (format "C-c %s %s"
                                              org-rt-mode-key-map-prefix
                                              (car map)))
                (cdr map))
              (when spacemacs
                (spacemacs/set-leader-keys-for-major-mode 'org-mode (format "%s %s"
                                                                  org-rt-mode-key-map-prefix
                                                                  (car map))
                  (cdr map))
                )
              )
            keymap)
  (cond (org-rt-mode
         (unless org-link-make-description-function
           (setq org-link-make-description-function #'org-rt-link-make-description))

         (add-hook 'org-property-changed-functions #'org-rt--org-property-changed-hook)
         (add-hook 'org-after-todo-state-change-hook #'org-rt--org-after-todo-state-change-hook)


         (mapc (lambda (timer)
                 (org-rt--idle-timer-once (cdr timer) t (car timer)))
               org-rt-timer-list)
         (when org-rt-need-id-refresh
           (org-rt-refresh-cache)
           (setq org-rt-need-id-refresh nil)
           )
         )
        (t
         (when (eq org-link-make-description-function #'org-rt-link-make-description)
           (setq org-link-make-description-function nil))

         (remove-hook 'org-property-changed-functions #'org-rt--org-property-changed-hook)
         (remove-hook 'org-after-todo-state-change-hook #'org-rt--org-after-todo-state-change-hook)

         (mapc (lambda (timer)
                 (cancel-function-timers (car timer)))
               org-rt-timer-list)
         ))

  )

;;;###autoload
(add-hook 'org-mode-hook 'org-rt-mode)

(provide 'org-rt)


;;; org-rt.el ends here.
