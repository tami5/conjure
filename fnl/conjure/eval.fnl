(module conjure.eval
  {require {a conjure.aniseed.core
            nvim conjure.aniseed.nvim
            extract conjure.extract
            client conjure.client
            text conjure.text
            fs conjure.fs
            config conjure.config
            promise conjure.promise
            editor conjure.editor
            buffer conjure.buffer
            uuid conjure.uuid
            log conjure.log
            event conjure.event}})

(defn- preview [opts]
  (let [sample-limit (editor.percent-width
                       (config.get-in [:preview :sample_limit]))]
    (.. (client.get :comment-prefix)
        opts.action " (" opts.origin "): "
        (if (or (= :file opts.origin) (= :buf opts.origin))
          (text.right-sample opts.file-path sample-limit)
          (text.left-sample opts.code sample-limit)))))

(defn- display-request [opts]
  (log.append
    [opts.preview]
    (a.merge opts {:break? true})))

(defn- with-last-result-hook [opts]
  (a.update
    opts :on-result
    (fn [f]
      (fn [result]
        (nvim.fn.setreg (config.get-in [:eval :result_register]) result)
        (when f (f result))))))

(defn file []
  (event.emit :eval :file)
  (let [opts {:file-path (fs.resolve-relative (extract.file-path))
              :origin :file
              :action :eval}]
    (set opts.preview (preview opts))
    (display-request opts)
    (client.call
      :eval-file
      (with-last-result-hook opts))))

(defn- assoc-context [opts]
  (set opts.context
       (or nvim.b.conjure#context
           (extract.context)))
  opts)

(defn- client-exec-fn [action f-name base-opts]
  (fn [opts]
    (let [opts (a.merge opts base-opts
                        {:action action
                         :file-path (extract.file-path)})]
      (assoc-context opts)
      (set opts.preview (preview opts))
      (when (not opts.passive?)
        (display-request opts))
      (client.call f-name opts))))

(defn eval-str [opts]
  (event.emit :eval :str)
  ((client-exec-fn :eval :eval-str)
   (if opts.passive?
     opts
     (with-last-result-hook opts)))
  nil)

(defn wrap-emit [name f]
  (fn [...]
    (event.emit name)
    (f ...)))

(def- doc-str (wrap-emit :doc (client-exec-fn :doc :doc-str)))
(def- def-str (wrap-emit :def (client-exec-fn :def :def-str {:suppress-hud? true})))

(defn current-form [extra-opts]
  (let [form (extract.form {})]
    (when form
      (let [{: content : range} form]
        (eval-str
          (a.merge
            {:code content
             :range range
             :origin :current-form}
            extra-opts))
        form))))

(defn replace-form []
  (let [buf (nvim.win_get_buf 0)
        win (nvim.tabpage_get_win 0)
        form (extract.form {})]
    (when form
      (let [{: content : range} form]
        (eval-str
          {:code content
           :range range
           :origin :replace-form
           :suppress-hud? true
           :on-result
           (fn [result]
             (buffer.replace-range
               buf
               range result)
             (editor.go-to
               win
               (a.get-in range [:start 1])
               (a.inc (a.get-in range [:start 2]))))})
        form))))

(defn root-form []
  (let [form (extract.form {:root? true})]
    (when form
      (let [{: content : range} form]
        (eval-str
          {:code content
           :range range
           :origin :root-form})))))

(defn marked-form []
  (let [mark (extract.prompt-char)
        comment-prefix (client.get :comment-prefix)
        (ok? err) (pcall #(editor.go-to-mark mark))]
    (if ok?
      (do
        (current-form {:origin (..  "marked-form [" mark "]")})
        (editor.go-back))
      (log.append [(.. comment-prefix "Couldn't eval form at mark: " mark)
                   (.. comment-prefix err)]
                  {:break? true}))))

(defn word []
  (let [{: content : range} (extract.word)]
    (when (not (a.empty? content))
      (eval-str
        {:code content
         :range range
         :origin :word}))))

(defn doc-word []
  (let [{: content : range} (extract.word)]
    (when (not (a.empty? content))
      (doc-str
        {:code content
         :range range
         :origin :word}))))

(defn def-word []
  (let [{: content : range} (extract.word)]
    (when (not (a.empty? content))
      (def-str
        {:code content
         :range range
         :origin :word}))))

(defn buf []
  (let [{: content : range} (extract.buf)]
    (eval-str
      {:code content
       :range range
       :origin :buf})))

(defn command [code]
  (eval-str
    {:code code
     :origin :command}))

(defn range [start end]
  (let [{: content : range} (extract.range start end)]
    (eval-str
      {:code content
       :range range
       :origin :range})))

(defn selection [kind]
  (let [{: content : range}
        (extract.selection
          {:kind (or kind (nvim.fn.visualmode))
           :visual? (not kind)})]
    (eval-str
      {:code content
       :range range
       :origin :selection})))

(defn- wrap-completion-result [result]
  (if (a.string? result)
    {:word result}
    result))

(defn completions [prefix cb]
  (fn cb-wrap [results]
    (cb (a.map
          wrap-completion-result
          (or results
              (-?> (config.get-in [:completion :fallback])
                   (nvim.call_function [0 prefix]))))))
  (if (= :function (type (client.get :completions)))
    (client.call
      :completions
      (-> {:prefix prefix
           :cb cb-wrap}
          (assoc-context)))
    (cb-wrap)))

(defn completions-promise [prefix]
  (let [p (promise.new)]
    (completions prefix (promise.deliver-fn p))
    p))

(defn completions-sync [prefix]
  (let [p (completions-promise prefix)]
    (promise.await p)
    (promise.close p)))
