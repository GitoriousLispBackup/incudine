(in-package :incudine-tests)

(enable-sharp-square-bracket-syntax)

(dsp! reinit-test-1 (f0 f1 amp dur)
  (out (* (line 0 amp (1+ dur) #'free)
          (sine (x-line f0 f1 dur #'reinit) amp 0))))

(dsp! reinit-test-2 (f0 f1 amp dur)
  (out (* (line 0 amp (1+ dur) #'free)
          (sine (x-line f0 f1 dur
                        (reduce-warnings
                          (lambda (node) (reinit node f0 f1 amp dur))))
                amp 0))))

(dsp! reinit-test-3 (amp dur)
  (stereo (* (envgen (make-local-perc .5 .5) 1 dur
                     (reduce-warnings
                       (lambda (node) (reinit node amp dur))))
             (oscr 1000 amp))))

(with-dsp-test (reinit.1
      :md5 #(111 65 233 19 87 24 110 145 222 109 13 187 206 192 236 177))
  (reinit-test-1 50 4000 .7 2 :id 123)
  (at #[2.1 sec] #'set-control 123 :dur .4))

(with-dsp-test (reinit.2
      :md5 #(111 30 231 83 18 12 181 227 18 28 82 65 208 10 224 115))
  (reinit-test-2 50 4000 .7 2 :id 123)
  (at #[2.1 sec] #'set-control 123 :dur .4))

(with-dsp-test (reinit.3 :channels 2
      :md5 #(236 6 236 54 51 199 179 205 70 41 211 178 131 87 22 88))
  (reinit-test-3 .75 1 :id 123)
  (at #[1/2 sec] #'set-control 123 :dur .1)
  (at #[2 sec] #'set-control 123 :dur .3)
  (at #[3 sec] #'set-control 123 :dur .5))
