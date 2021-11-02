;;; code-review-github.el --- Github API functions -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Wanderson Ferreira
;;
;; Author: Wanderson Ferreira <https://github.com/wandersoncferreira>
;; Maintainer: Wanderson Ferreira <wand@hey.com>
;; Version: 0.0.1
;; Homepage: https://github.com/wandersoncferreira/code-review
;; Package-Requires: ((emacs "25.1"))
;;
;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;;  This library is an interface with Github REST API and GraphQL API.
;;
;;; Code:

(require 'ghub)
(require 'deferred)
(require 'code-review-core)
(require 'code-review-utils)
(require 'a)

(defclass code-review-github-repo (code-review-db-pullreq)
  ((callback            :initform nil)))

(defgroup code-review-github nil
  "Interact with GitHub REST and GraphQL APIs."
  :group 'tools)

(defcustom code-review-github-host "api.github.com"
  "Host for the GitHub api if you use the hosted version of GitHub."
  :group 'code-review-github
  :type 'string)

(defconst code-review-github-diffheader '(("Accept" . "application/vnd.github.v3.diff"))
  "Header for requesting diffs from GitHub.")

(defconst code-review-github-token-scopes '(repo)
  "Only repo scope needed to read PRs and submit reviews.")

(defun code-review-github-errback (&rest m)
  "Error callback, displays the error message M."
  (let-alist m
    (let* ((status (-second-item .error)))
      (code-review-utils--log
       "code-review-github-errback"
       (prin1-to-string m))
      (cond
       ((= status 422)
        (let ((errors (string-join
                       (a-get (-third-item .error) 'errors)
                       " AND "))
              (msg (string-trim (a-get (-third-item .error) 'message))))
          (message "Errors: %S" (if (string-empty-p errors) msg errors))))
       ((= status 404)
        (message "Provided URL Not Found"))
       ((= status 401)
        (message "Bad credentials. Documentation to how to setup credentials
https://github.com/wandersoncferreira/code-review#configuration"))
       (t
        (message "Unknown error talking to Github: %s" m))))))

(cl-defmethod code-review-core-pullreq-diff ((github code-review-github-repo) callback)
  "Get PR diff from GITHUB, run CALLBACK after answer."
  (let ((owner (oref github owner))
        (repo (oref github repo))
        (num (oref github number)))
    (ghub-get (format "/repos/%s/%s/pulls/%s" owner repo num)
              nil
              :unpaginate t
              :headers code-review-github-diffheader
              :auth 'code-review
              :host code-review-github-host
              :callback callback
              :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-diff-deferred ((github code-review-github-repo))
  "Get PR diff from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-pullreq-diff
     github
     (apply-partially
      (lambda (d v &rest _)
        (deferred:callback-post d v))
      d))
    d))

(cl-defmethod code-review-core-commit-diff ((github code-review-github-repo) callback)
  "Get PR diff from GITHUB, run CALLBACK after answer."
  (let ((owner (oref github owner))
        (repo (oref github repo))
        (sha (oref github sha)))
    (ghub-get (format "/repos/%s/%s/commits/%s" owner repo sha)
              nil
              :unpaginate t
              :headers code-review-github-diffheader
              :auth 'code-review
              :host code-review-github-host
              :callback callback
              :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-commit-diff-deferred ((github code-review-github-repo))
  "Get PR diff from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-commit-diff
     github
     (apply-partially
      (lambda (d v &rest _)
        (deferred:callback-post d v))
      d))
    d))

(cl-defmethod code-review-core-pullreq-infos ((github code-review-github-repo) callback)
  "Get PR details from GITHUB and dispatch to CALLBACK."
  (let* ((repo (oref github repo))
         (owner (oref github owner))
         (num (oref github number))
         (query (format "query {
  repository(name: \"%s\", owner: \"%s\") {
    pullRequest(number: %s){
      headRef { target{ oid } }
      baseRefName
      headRefName
      isDraft
      number
      milestone {
        title
        progressPercentage
      }
      labels(first: 10) {
        nodes {
          name
          color
        }
      }
      assignees(first: 15) {
        nodes {
          name
          login
        }
      }
      projectCards(first: 10) {
        nodes {
          project {
            name
          }
        }
      }
      suggestedReviewers {
        reviewer {
          name
        }
      }
      commits(first: 100) {
        totalCount
        nodes {
          commit {
            abbreviatedOid
            message
          }
        }
      }
      title
      state
      bodyText
      comments(first:50) {
        nodes { author { login } bodyText }
      }
      reviews(first: 50) {
        nodes { author { login } bodyText state
          comments(first: 50) {
            nodes {
              bodyText
              originalPosition
              diffHunk
              position
              outdated
              path
              databaseId
            }
          }
        }
      }
    }
  }
}" repo owner num)))
    (ghub-graphql query
                  '()
                  :auth 'code-review
                  :host code-review-github-host
                  :callback callback
                  :errorback #'code-review-github-errback)))

(cl-defmethod code-review-core-infos-deferred ((github code-review-github-repo))
  "Get PR infos from GITHUB using deferred lib."
  (let ((d (deferred:new #'identity)))
    (code-review-core-pullreq-infos
     github
     (apply-partially (lambda (d v &rest _)
                        (deferred:callback-post d v))
                      d))
    d))

(cl-defmethod code-review-core-send-review ((github code-review-github-repo) callback)
  "Submit review comments given GITHUB repo and a CALLBACK fn."
  (let* ((payload (a-alist 'body (oref github feedback)
                           'event (oref github state)
                           'commit_id (oref github sha)))
         (payload (if (oref github review)
                      (a-assoc payload 'comments (oref github review))
                    payload)))
    (ghub-post (format "/repos/%s/%s/pulls/%s/reviews"
                       (oref github owner)
                       (oref github repo)
                       (oref github number))
               nil
               :auth 'code-review
               :payload payload
               :host code-review-github-host
               :errorback #'code-review-github-errback
               :callback callback)))

(cl-defmethod code-review-core-send-replies ((github code-review-github-repo) callback)
  "Submit replies to review comments inline given GITHUB repo and a CALLBACK fn."
  (deferred:$
    (deferred:parallel
      (-map
       (lambda (reply)
         (lambda ()
           (let* ((database-id (a-get reply 'comment-id))
                  (body (a-get reply 'body)))
             (ghub-post (format "/repos/%s/%s/pulls/%s/comments/%s/replies"
                                (oref github owner)
                                (oref github repo)
                                (oref github number)
                                database-id)
                        nil
                        :payload (a-alist 'body body)
                        :headers code-review-github-diffheader
                        :auth 'code-review
                        :host code-review-github-host
                        :callback (lambda (&rest _))
                        :errorback #'code-review-github-errback))))
       (oref github replies)))

    (deferred:nextc it
      (lambda (_x)
        (funcall callback)))

    (deferred:error it
      (lambda (err)
        (message "Got an error from the Github Reply API %S!" err)))))

(cl-defmethod code-review-core-get-labels ((github code-review-github-repo))
  "Get labels from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/labels"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       (a-get l 'name))
     resp)))

(cl-defmethod code-review-core-set-labels ((github code-review-github-repo))
  "Set labels for your pr at GITHUB."
  (let ((url (format "/repos/%s/%s/issues/%s/labels"
                     (oref github owner)
                     (oref github repo)
                     (oref github number)))
        (req-fn (if (oref github labels)
                    #'ghub-post
                  #'ghub-put)))
    (funcall req-fn url
             nil
             :payload (a-alist 'labels (or (-map (lambda (x)
                                                   (a-get x 'name))
                                                 (oref github labels))
                                           []))
             :auth 'code-review)))

(cl-defmethod code-review-core-get-assignees ((github code-review-github-repo))
  "Get labels from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/assignees"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       (a-get l 'login))
     resp)))

(cl-defmethod code-review-core-set-assignee ((github code-review-github-repo))
  "Set assignee to your PR in GITHUB."
  (ghub-post (format "/repos/%s/%s/issues/%s/assignees"
                     (oref github owner)
                     (oref github repo)
                     (oref github number))
             nil
             :auth 'code-review
             :payload (a-alist 'assignees (oref github assignees))))

(cl-defmethod code-review-core-get-milestones ((github code-review-github-repo))
  "Get milestones from GITHUB."
  (let ((resp
         (ghub-get (format "/repos/%s/%s/milestones"
                           (oref github owner)
                           (oref github repo))
                   nil
                   :auth 'code-review)))
    (-map
     (lambda (l)
       `(,(a-get l 'title) . ,(a-get l 'number)))
     resp)))

(cl-defmethod code-review-core-set-milestone ((github code-review-github-repo))
  "Set milestone for a pullreq in GITHUB."
  (ghub-patch (format "/repos/%s/%s/issues/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'milestone (oref github milestones))))

(cl-defmethod code-review-core-set-title ((github code-review-github-repo))
  "Set title for a pullreq in GITHUB."
  (ghub-patch (format "/repos/%s/%s/pulls/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'title (oref github title))))

(cl-defmethod code-review-core-set-description ((github code-review-github-repo))
  "Set description for a pullreq in GITHUB."
  (ghub-patch (format "/repos/%s/%s/pulls/%s"
                      (oref github owner)
                      (oref github repo)
                      (oref github number))
              nil
              :auth 'code-review
              :payload (a-alist 'body (oref github description))))

(cl-defmethod code-review-core-merge ((github code-review-github-repo) strategy)
  "Merge a PR in GITHUB using a STRATEGY."
  (ghub-put (format "/repos/%s/%s/pulls/%s/merge"
                    (oref github owner)
                    (oref github repo)
                    (oref github number))
            nil
            :auth 'code-review
            :payload (a-alist 'commit_title (oref github title)
                              'commit_message (oref github description)
                              'sha (oref github sha)
                              'merge_method strategy)
            :errorback (lambda (e &rest _)
                         (message "ERROR!! %S" (a-get (-fourth-item e) 'message)))))

(provide 'code-review-github)
;;; code-review-github.el ends here
