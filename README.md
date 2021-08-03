# org-rt
 An orgmode interface to the RT ticketing system, this is currently working but
 very roughly, plenty of work to do, and bugs to squash.

 Personally I use it at work, so it should be fine, but your millage may vary.

## Usage

Load the `org-rt.el` file into emacs

```elisp
;; Load org-rt
(require 'org-rt)

;; Set username
(setq org-rt-username "YourRtUser")

;; Set password (can also use auth-source)
(setq org-rt-username "PASSWORD")

;; Set RT API endpoint
(set org-rt-rest-endpoint "https://rthost.com/rt/REST/1.0")

;; Create a capture template for incoming tasks
(setq org-rt-capture-templates `(("W" "RT" entry
                                        (file+headline "~/inbox.org" "Tasks")
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
%:description" :immediate-finish t)))

;; Set org-rt-link endpoint
(set org-rt-link-endpoint "https://rthost.com/rt")

;; Enable org-rt-mode
(org-rt-mode)
```
Once enabled new tickets assigned to your user should be created automatically
during periods of idle.

## Default keymap
| Keys    | Spacemacs Keys | Function                    |
| ------- | -------------- | --------------------------- |
| C-c y   | , R y          | org-rt-task-yank-id         |
| C-c Y   | , R Y          | org-rt-task-yank-url        |
| C-c o   | , R o          | org-rt-task-open-url        |
| C-c O   | , R O          | org-rt-task-open            |
| C-c c   | , R c          | org-rt-create-ticket        |
| C-c C   | , R C          | org-rt-task-comment         |
| C-c d   | , R d          | org-rt-task-complete        |
| C-c f   | , R f          | org-rt-task-find-or-create  |
| C-c F   | , R F          | org-rt-assigned-fetch       |
| C-c G   | , R G          | org-rt-task-goto            |
| C-c T   | , R T          | org-rt-ticket-take          |
| C-c g p | , R g p        | org-rt-goto-parent          |
| C-c g c | , R g c        | org-rt-goto-child           |
| C-c g b | , R g b        | org-rt-goto-blocker         |
| C-c g B | , R g B        | org-rt-goto-blocking        |
| C-c l r | , R l r        | org-rt-add-reference        |
| C-c l R | , R l R        | org-rt-add-referenced-by    |
| C-c l p | , R l p        | org-rt-add-parent           |
| C-c l c | , R l c        | org-rt-add-child            |
| C-c l b | , R l b        | org-rt-add-blocker          |
| C-c l B | , R l B        | org-rt-add-blocking         |
| C-c L r | , R L r        | org-rt-remove-reference     |
| C-c L R | , R L R        | org-rt-remove-referenced-by |
| C-c L p | , R L p        | org-rt-remove-parent        |
| C-c L c | , R L c        | org-rt-remove-child         |
| C-c L b | , R L b        | org-rt-remove-blocker       |
| C-c L B | , R L B        | org-rt-remove-blocking      |

## Caveats

Some specific exceptions

### The description of a ticket is always plaintext

I could not find a way to submit an HTML ticket description upon creation for
RT, thus all tickets will be created with a plaintext description even when
`org-rt-note-export-html` is non-nil

### No bi-directional or automatic syncing

Changes made in orgmode are synced to RT but the same is not true in reverse
currently. Changes made in orgmode are also only synced when done through a
command or they trigger a hook.
