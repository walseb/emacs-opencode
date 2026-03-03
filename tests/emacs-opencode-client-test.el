;;; emacs-opencode-client-test.el --- Tests for HTTP client  -*- lexical-binding: t; -*-

(require 'ert)
(require 'emacs-opencode-client)

;;; vectorize-answers

(ert-deftest test-opencode-client/vectorize-answers-list-of-lists ()
  "Convert list of lists to vector of vectors."
  (let ((result (opencode--vectorize-answers '(("a" "b") ("c")))))
    (should (vectorp result))
    (should (= (length result) 2))
    (should (vectorp (aref result 0)))
    (should (equal (aref result 0) ["a" "b"]))
    (should (equal (aref result 1) ["c"]))))

(ert-deftest test-opencode-client/vectorize-answers-vector-input ()
  "Handle vector input."
  (let ((result (opencode--vectorize-answers [("a") ("b")])))
    (should (vectorp result))
    (should (= (length result) 2))))

(ert-deftest test-opencode-client/vectorize-answers-strings ()
  "Wrap plain strings in vectors."
  (let ((result (opencode--vectorize-answers '("hello" "world"))))
    (should (vectorp result))
    (should (equal (aref result 0) ["hello"]))
    (should (equal (aref result 1) ["world"]))))

(ert-deftest test-opencode-client/vectorize-answers-mixed ()
  "Handle mixed input types."
  (let ((result (opencode--vectorize-answers '(["a"] ("b") "c"))))
    (should (vectorp result))
    (should (equal (aref result 0) ["a"]))
    (should (equal (aref result 1) ["b"]))
    (should (equal (aref result 2) ["c"]))))

(ert-deftest test-opencode-client/vectorize-answers-nil ()
  "Handle nil input."
  (let ((result (opencode--vectorize-answers nil)))
    (should (vectorp result))
    (should (= (length result) 0))))

(provide 'emacs-opencode-client-test)

;;; emacs-opencode-client-test.el ends here
